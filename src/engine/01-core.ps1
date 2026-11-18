# =====================================================================
#  WURepair — ядро: журнал, запуск процессов, реестр, резервные копии
#  Этот файл — часть "движка". Он не создаёт окон и может работать
#  как в фоновом потоке (runspace) окна, так и в тестах.
#  ВАЖНО: в файлах движка нельзя использовать строку, начинающуюся
#  с символов '@ (одинарный here-string) — сборщик встраивает движок
#  в .exe именно таким here-string.
# =====================================================================

Set-StrictMode -Off

$script:AppName     = 'WURepair'
$script:AppVersion  = '1.0.0'
$script:SysDrive    = $env:SystemDrive
if (-not $script:SysDrive) { $script:SysDrive = [IO.Path]::GetTempPath() }   # не Windows (тесты)
$script:RootDir     = Join-Path $script:SysDrive 'WURepair'
$script:LogDir      = Join-Path $script:RootDir 'Logs'
$script:BackupRoot  = Join-Path $script:RootDir 'Backup'
$script:DownloadDir = Join-Path $script:RootDir 'Downloads'
$script:SessionBackupDir = $null
$script:RestorePointDone = $false
$script:LogFile = $null
$script:LastFindings = @()
$script:LastSysInfo = $null
$script:OkLogCount = 0      # сколько реальных изменений записано в журнал (уровень OK)

# TLS 1.2 нужен для загрузок с сайтов Microsoft/GitHub/claude.ai
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch { }

# ---------------------------------------------------------------------
#  Связь с окном программы
# ---------------------------------------------------------------------
function Send-UiEvent {
    param([string]$Type, $Data)
    if ($Sync -and $Sync.Queue) {
        $Sync.Queue.Enqueue([pscustomobject]@{ Type = $Type; Data = $Data })
    }
}

function Initialize-AppDirs {
    foreach ($d in @($script:RootDir, $script:LogDir, $script:BackupRoot, $script:DownloadDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch { }
        }
    }
    if (-not $script:LogFile) {
        $script:LogFile = Join-Path $script:LogDir ('log-' + (Get-Date -Format 'yyyy-MM-dd') + '.txt')
    }
}

function Write-Log {
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG')][string]$Level = 'INFO'
    )
    if ($Level -eq 'OK') { $script:OkLogCount++ }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try { [IO.File]::AppendAllText($script:LogFile, $line + "`r`n", [Text.Encoding]::UTF8) } catch { }
    }
    if ($Sync -and $Sync.Queue) {
        Send-UiEvent 'log' @{ Level = $Level; Text = $Message; Time = (Get-Date -Format 'HH:mm:ss') }
    } elseif ($env:WUREPAIR_VERBOSE) {
        [Console]::WriteLine($line)
    }
}

function Set-UiStatus { param([string]$Text) Send-UiEvent 'status' $Text }

# -1 = "бегущая" полоса, 0..100 = проценты
function Set-UiProgress { param([int]$Percent) Send-UiEvent 'progress' $Percent }

function Request-UserConfirm {
    param([string]$Text, [string]$Title = 'Вопрос')
    if (-not $Sync -or -not $Sync.UiAttached) { return $true }
    $Sync.Answer = $null
    Send-UiEvent 'ask' @{ Text = $Text; Title = $Title }
    [void]$Sync.AnswerEvent.WaitOne()
    return [bool]$Sync.Answer
}

function Request-UserFile {
    param([string]$Title = 'Выберите файл', [string]$Filter = 'Все файлы (*.*)|*.*')
    if (-not $Sync -or -not $Sync.UiAttached) { return $null }
    $Sync.Answer = $null
    Send-UiEvent 'askfile' @{ Title = $Title; Filter = $Filter }
    [void]$Sync.AnswerEvent.WaitOne()
    if ($Sync.Answer) { return [string]$Sync.Answer }
    return $null
}

function Show-UiMessage {
    param([string]$Text, [string]$Title = 'WURepair', [ValidateSet('info', 'warn', 'error')][string]$Icon = 'info')
    if (-not $Sync -or -not $Sync.UiAttached) { Write-Log $Text 'INFO'; return }
    Send-UiEvent 'message' @{ Text = $Text; Title = $Title; Icon = $Icon }
}

# ---------------------------------------------------------------------
#  Системные утилиты
# ---------------------------------------------------------------------
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Если 32-битный процесс работает на 64-битной Windows — обходим перенаправление System32.
function Resolve-SystemExe {
    param([string]$Name)
    if ([IO.Path]::IsPathRooted($Name)) { return $Name }
    $sys = Join-Path $env:windir 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $sys = Join-Path $env:windir 'Sysnative'
    }
    $candidate = Join-Path $sys $Name
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    if ($Name -ieq 'powershell.exe') {
        $ps = Join-Path $sys 'WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $ps) { return $ps }
    }
    return $Name
}

function Get-ConsoleEncoding {
    param([string]$Kind)
    switch ($Kind) {
        'unicode' { return [Text.Encoding]::Unicode }
        'utf8'    { return (New-Object Text.UTF8Encoding $false) }
        'ansi'    { return [Text.Encoding]::Default }
        default   {
            try { return [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
            catch { return [Text.Encoding]::Default }
        }
    }
}

# Запуск внешней программы без окна консоли, с таймаутом и (по желанию)
# выводом строк в журнал по мере работы (для DISM/SFC).
function Invoke-Proc {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutSec = 600,
        [ValidateSet('oem', 'unicode', 'utf8', 'ansi')][string]$Encoding = 'oem',
        [switch]$LiveLog,
        [switch]$Quiet
    )
    $exe = Resolve-SystemExe $FilePath
    $out = Join-Path $env:TEMP ('wur_' + [guid]::NewGuid().ToString('N') + '.txt')
    $cmd = Resolve-SystemExe 'cmd.exe'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd
    $psi.Arguments = '/d /s /c ""' + $exe + '" ' + $Arguments + ' > "' + $out + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    if (-not $Quiet) { Write-Log ('> ' + [IO.Path]::GetFileName($exe) + ' ' + $Arguments) 'DEBUG' }

    $enc = Get-ConsoleEncoding $Encoding
    $decoder = $enc.GetDecoder()
    $sb = New-Object Text.StringBuilder
    $pending = ''
    $pos = [long]0
    $timedOut = $false
    $lastPct = -1
    $p = $null
    try {
        $p = [Diagnostics.Process]::Start($psi)
    } catch {
        Write-Log ('Не удалось запустить ' + $exe + ': ' + $_.Exception.Message) 'ERROR'
        return [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $false }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $exited = $p.WaitForExit(700)
        if (Test-Path -LiteralPath $out) {
            try {
                $fs = New-Object IO.FileStream($out, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    if ($fs.Length -gt $pos) {
                        [void]$fs.Seek($pos, [IO.SeekOrigin]::Begin)
                        $len = [int]($fs.Length - $pos)
                        $buf = New-Object byte[] $len
                        $read = $fs.Read($buf, 0, $len)
                        $pos += $read
                        $chars = New-Object char[] ($enc.GetMaxCharCount($read))
                        $n = $decoder.GetChars($buf, 0, $read, $chars, 0)
                        $text = [string]::new($chars, 0, $n)
                        [void]$sb.Append($text)
                        if ($LiveLog) {
                            $pending += $text
                            $parts = [regex]::Split($pending, '[\r\n]')
                            $pending = $parts[$parts.Length - 1]
                            for ($i = 0; $i -lt $parts.Length - 1; $i++) {
                                $seg = $parts[$i].Trim()
                                if (-not $seg) { continue }
                                $m = [regex]::Match($seg, '(\d{1,3})(?:[.,]\d+)?\s*%')
                                if ($m.Success -and ($seg -match '^\[|=|%\s*$|\d+\s*%')) {
                                    $pct = [int]$m.Groups[1].Value
                                    if ($pct -ge 0 -and $pct -le 100 -and $pct -ne $lastPct) {
                                        $lastPct = $pct
                                        Set-UiProgress $pct
                                        if ($pct % 10 -eq 0) { Write-Log ('   ... ' + $pct + '%') 'INFO' }
                                    }
                                    continue
                                }
                                Write-Log ('   ' + $seg) 'INFO'
                            }
                        }
                    }
                } finally { $fs.Dispose() }
            } catch { }
        }
        if ($exited) { break }
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $timedOut = $true
            Write-Log ('Превышено время ожидания (' + $TimeoutSec + ' с), процесс остановлен.') 'WARN'
            try { [void](& (Resolve-SystemExe 'taskkill.exe') /T /F /PID $p.Id 2>&1) } catch { }
            break
        }
    }
    if ($LiveLog -and $pending.Trim()) { Write-Log ('   ' + $pending.Trim()) 'INFO' }
    $code = -1
    try { if (-not $timedOut) { $code = $p.ExitCode } } catch { }
    try { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } catch { }
    return [pscustomobject]@{ ExitCode = $code; Output = $sb.ToString(); TimedOut = $timedOut }
}

# ---------------------------------------------------------------------
#  Реестр
# ---------------------------------------------------------------------
function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

function Test-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        return ($k.GetValueNames() -contains $Name)
    } catch { return $false }
}

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [switch]$Quiet)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        if (-not $Quiet) { Write-Log ('Не удалось записать ' + $Path + '\' + $Name + ': ' + $_.Exception.Message) 'WARN' }
        return $false
    }
}

function Remove-RegValue {
    param([string]$Path, [string]$Name, [switch]$Quiet)
    if (-not (Test-RegValue $Path $Name)) { return $true }
    try {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop
        return $true
    } catch {
        if (-not $Quiet) { Write-Log ('Не удалось удалить ' + $Path + '\' + $Name + ': ' + $_.Exception.Message) 'WARN' }
        return $false
    }
}

# Запись/удаление с запасным вариантом «от имени SYSTEM» для защищённых ключей.
function Set-RegValueForce {
    param([string]$Path, [string]$Name, $Value, [ValidateSet('DWord', 'String', 'ExpandString')][string]$Type = 'DWord')
    if (Set-RegValue $Path $Name $Value $Type -Quiet) { return $true }
    $t = @{ DWord = 'REG_DWORD'; String = 'REG_SZ'; ExpandString = 'REG_EXPAND_SZ' }[$Type]
    $v = [string]$Value -replace '"', '\"'
    $cmd = 'reg add "' + (ConvertTo-NativeRegPath $Path) + '" /v "' + $Name + '" /t ' + $t + ' /d "' + $v + '" /f'
    $res = Invoke-AsSystem $cmd
    if ($res -ne 0) { Write-Log ('Не удалось изменить ' + (ConvertTo-NativeRegPath $Path) + '\' + $Name + ' даже от имени SYSTEM.') 'WARN' }
    return ($res -eq 0)
}

function Remove-RegValueForce {
    param([string]$Path, [string]$Name)
    if (Remove-RegValue $Path $Name -Quiet) { return $true }
    $cmd = 'reg delete "' + (ConvertTo-NativeRegPath $Path) + '" /v "' + $Name + '" /f'
    $res = Invoke-AsSystem $cmd
    if ($res -ne 0) { Write-Log ('Не удалось удалить ' + (ConvertTo-NativeRegPath $Path) + '\' + $Name + ' даже от имени SYSTEM.') 'WARN' }
    return ($res -eq 0)
}

# HKLM:\SOFTWARE\... -> HKLM\SOFTWARE\... (формат reg.exe)
function ConvertTo-NativeRegPath {
    param([string]$Path)
    $p = $Path -replace '^Registry::', ''
    $p = $p -replace '^HKLM:\\?', 'HKLM\' -replace '^HKCU:\\?', 'HKCU\' -replace '^HKCR:\\?', 'HKCR\' -replace '^HKU:\\?', 'HKU\'
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_CURRENT_USER', 'HKCU'
    return $p.TrimEnd('\')
}

# ---------------------------------------------------------------------
#  Резервные копии и точка восстановления
# ---------------------------------------------------------------------
function Get-SessionBackupDir {
    if (-not $script:SessionBackupDir) {
        Initialize-AppDirs
        $script:SessionBackupDir = Join-Path $script:BackupRoot (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
        New-Item -ItemType Directory -Path $script:SessionBackupDir -Force | Out-Null
        Write-Log ('Резервные копии этого сеанса: ' + $script:SessionBackupDir) 'INFO'
    }
    return $script:SessionBackupDir
}

function Backup-RegKey {
    param([string]$Path, [string]$Tag)
    $native = ConvertTo-NativeRegPath $Path
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $dir = Get-SessionBackupDir
    if (-not $Tag) { $Tag = ($native -replace '[\\/:*?"<>| ]', '_') }
    $file = Join-Path $dir ('reg_' + $Tag + '.reg')
    if (Test-Path -LiteralPath $file) { return $true }
    $r = Invoke-Proc 'reg.exe' ('export "' + $native + '" "' + $file + '" /y') -TimeoutSec 60 -Quiet
    if ($r.ExitCode -ne 0) {
        Write-Log ('Не удалось сохранить копию ключа ' + $native) 'WARN'
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------
#  Права на ключи реестра (их меняет, например, Windows Update Blocker:
#  после него служба не включается даже от имени SYSTEM)
# ---------------------------------------------------------------------
function Enable-Privilege {
    param([string[]]$Names)
    if (-not ('WURepair.TokenPriv' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace WURepair {
    public static class TokenPriv {
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct TokPriv { public int Count; public long Luid; public int Attr; }
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr h, int access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool LookupPrivilegeValue(string host, string name, out long luid);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokPriv newState, int len, IntPtr prev, IntPtr relen);
        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();
        public static bool Enable(string name) {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return false;
            TokPriv tp; tp.Count = 1; tp.Attr = 2;
            if (!LookupPrivilegeValue(null, name, out tp.Luid)) return false;
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return Marshal.GetLastWin32Error() == 0;
        }
    }
}
"@
    }
    $ok = $true
    foreach ($n in $Names) { if (-not [WURepair.TokenPriv]::Enable($n)) { $ok = $false } }
    return $ok
}

function Get-HklmKeySddl {
    param([string]$SubPath)
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::Default, [Security.AccessControl.RegistryRights]::ReadPermissions)
        if (-not $k) { return $null }
        try { return $k.GetAccessControl([Security.AccessControl.AccessControlSections]'Access,Owner').GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access,Owner') }
        finally { $k.Close() }
    } catch { return '' }
}

# Проверка по тексту SDDL: есть запрещающие записи или у SYSTEM нет права записи.
function Test-SddlLocked {
    param($Sddl)   # без [string]: $null («ключа нет») и '' («права не прочитать») — разные случаи
    if ($null -eq $Sddl) { return $false }
    $Sddl = [string]$Sddl
    if ($Sddl -eq '') { return $true }                  # даже прочитать права нельзя
    $dacl = $Sddl
    $i = $Sddl.IndexOf('D:')
    if ($i -ge 0) { $dacl = $Sddl.Substring($i) }
    $aces = @([regex]::Matches($dacl, '\(([^)]*)\)') | ForEach-Object { $_.Groups[1].Value })
    foreach ($a in $aces) {
        $f = $a.Split(';')
        if ($f.Count -lt 6) { continue }
        if ($f[0] -eq 'D' -and $f[2] -match 'KA|KW|GA|GW|WD|WO|0x' ) { return $true }
    }
    foreach ($a in $aces) {
        $f = $a.Split(';')
        if ($f.Count -lt 6) { continue }
        if ($f[0] -eq 'A' -and $f[5] -eq 'SY' -and $f[1] -notmatch 'IO' -and $f[2] -match 'KA|KW|GA|GW') { return $false }
    }
    return $true
}

function Test-HklmKeyLocked {
    param([string]$SubPath)
    return (Test-SddlLocked (Get-HklmKeySddl $SubPath))
}

# Стандартные права для ключа службы: SYSTEM и Администраторы — полный доступ,
# Пользователи — чтение (как у обычных служб Windows).
$script:ServiceKeySddl = 'D:(A;CI;KA;;;SY)(A;CI;KA;;;BA)(A;CI;KR;;;BU)(A;CI;KR;;;AC)'

function Reset-HklmKeyAcl {
    param([string]$SubPath, [string]$Sddl = $script:ServiceKeySddl)
    $rk = [Microsoft.Win32.Registry]::LocalMachine
    $perm = [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    # 1) забрать владение
    $k = $rk.OpenSubKey($SubPath, $perm, [Security.AccessControl.RegistryRights]::TakeOwnership)
    if (-not $k) { throw ('ключ не найден: ' + $SubPath) }
    $sec = New-Object Security.AccessControl.RegistrySecurity
    $sec.SetOwner($admins)
    $k.SetAccessControl($sec)
    $k.Close()
    # 2) записать стандартные права
    $k = $rk.OpenSubKey($SubPath, $perm, [Security.AccessControl.RegistryRights]'ChangePermissions, ReadKey, TakeOwnership')
    $sec = New-Object Security.AccessControl.RegistrySecurity
    $sec.SetSecurityDescriptorSddlForm($Sddl, [Security.AccessControl.AccessControlSections]::Access)
    $k.SetAccessControl($sec)
    $subs = @($k.GetSubKeyNames())
    $k.Close()
    # 3) подразделы
    foreach ($s in $subs) {
        try { Reset-HklmKeyAcl ($SubPath + '\' + $s) $Sddl } catch { }
    }
    # 4) вернуть владельца SYSTEM
    try {
        $k = $rk.OpenSubKey($SubPath, $perm, [Security.AccessControl.RegistryRights]::TakeOwnership)
        $sec = New-Object Security.AccessControl.RegistrySecurity
        $sec.SetOwner($system)
        $k.SetAccessControl($sec)
        $k.Close()
    } catch { }
}

function Unlock-ServiceKey {
    param([string]$Name)
    $sub = 'SYSTEM\CurrentControlSet\Services\' + $Name
    $orig = Get-HklmKeySddl $sub
    if ($null -eq $orig) { return $false }
    if (-not (Test-SddlLocked $orig)) { return $true }
    if ($orig) {
        try { [IO.File]::WriteAllText((Join-Path (Get-SessionBackupDir) ('sddl_' + $Name + '.txt')), ($sub + "`r`n" + $orig), [Text.Encoding]::UTF8) } catch { }
    }
    [void](Enable-Privilege @('SeTakeOwnershipPrivilege', 'SeRestorePrivilege', 'SeBackupPrivilege'))
    try {
        Reset-HklmKeyAcl $sub
    } catch {
        Write-Log ('Не удалось снять блокировку прав с ключа службы ' + $Name + ': ' + $_.Exception.Message) 'ERROR'
        return $false
    }
    if (Test-HklmKeyLocked $sub) {
        Write-Log ('Права ключа службы ' + $Name + ' всё ещё заблокированы.') 'ERROR'
        return $false
    }
    Write-Log ('С ключа реестра службы ' + $Name + ' снята блокировка прав (её ставит Windows Update Blocker).') 'OK'
    return $true
}

# Текст .reg-файла только с указанными значениями (без подразделов —
# защищённые подразделы не мешают потом импорту при откате).
function ConvertTo-RegFileText {
    param([string]$NativeKey, [object[]]$Values)
    $hive = $NativeKey -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'HKEY_CURRENT_USER\'
    $hex = { param([byte[]]$b) (@($b | ForEach-Object { '{0:x2}' -f $_ }) -join ',') }
    $lines = @('Windows Registry Editor Version 5.00', '', ('[' + $hive + ']'))
    foreach ($v in $Values) {
        $name = '"' + ($v.Name -replace '\\', '\\' -replace '"', '\"') + '"'
        switch ([string]$v.Kind) {
            'String'       { $lines += ($name + '="' + ([string]$v.Value -replace '\\', '\\' -replace '"', '\"') + '"') }
            'DWord'        { $lines += ($name + '=dword:' + ('{0:x8}' -f [uint32]([int64]$v.Value -band 0xFFFFFFFFL))) }
            'QWord'        { $lines += ($name + '=hex(b):' + (& $hex ([BitConverter]::GetBytes([int64]$v.Value)))) }
            'Binary'       { $lines += ($name + '=hex:' + (& $hex ([byte[]]$v.Value))) }
            'ExpandString' { $lines += ($name + '=hex(2):' + (& $hex ([Text.Encoding]::Unicode.GetBytes([string]$v.Value + [char]0)))) }
            'MultiString'  { $lines += ($name + '=hex(7):' + (& $hex ([Text.Encoding]::Unicode.GetBytes(((@($v.Value) -join [char]0) + [char]0 + [char]0))))) }
        }
    }
    return (($lines -join "`r`n") + "`r`n")
}

function Backup-RegValues {
    param([string]$Path, [string[]]$Names, [string]$Tag)
    try { $k = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $false }
    $vals = @()
    foreach ($n in $Names) {
        if ($k.GetValueNames() -notcontains $n) { continue }
        $vals += [pscustomobject]@{ Name = $n; Kind = $k.GetValueKind($n); Value = $k.GetValue($n, $null, 'DoNotExpandEnvironmentNames') }
    }
    if ($vals.Count -eq 0) { return $true }
    $file = Join-Path (Get-SessionBackupDir) ('reg_' + $Tag + '.reg')
    try {
        [IO.File]::WriteAllText($file, (ConvertTo-RegFileText (ConvertTo-NativeRegPath $Path) $vals), [Text.Encoding]::Unicode)
        return $true
    } catch {
        Write-Log ('Не удалось сохранить копию значений ' + (ConvertTo-NativeRegPath $Path) + ': ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Backup-File {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $dir = Get-SessionBackupDir
    if (-not $Name) { $Name = [IO.Path]::GetFileName($Path) }
    $dest = Join-Path $dir ('file_' + $Name)
    if (Test-Path -LiteralPath $dest) { return $true }
    try {
        Copy-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
        $meta = Join-Path $dir ('file_' + $Name + '.path')
        [IO.File]::WriteAllText($meta, $Path, [Text.Encoding]::UTF8)
        return $true
    } catch {
        Write-Log ('Не удалось сохранить копию файла ' + $Path + ': ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function New-SafetyRestorePoint {
    if ($script:RestorePointDone) { return $true }
    $script:RestorePointDone = $true
    Write-Log 'Создаю точку восстановления Windows (может занять 1–2 минуты)…' 'STEP'
    Set-UiStatus 'Создание точки восстановления…'
    try {
        # Службы теневого копирования могут быть отключены «чистильщиком»
        foreach ($s in 'VSS', 'swprv') {
            $start = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$s" 'Start'
            if ($start -eq 4) {
                [void](Invoke-Proc 'sc.exe' "config $s start= demand" -TimeoutSec 30 -Quiet)
                Write-Log "Служба $s была отключена — включил (ручной запуск)." 'INFO'
            }
        }
        # Снимаем ограничение «одна точка в сутки»
        [void](Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0)
        [void](Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' 'DisableSR')
        try { Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop } catch { }
        Checkpoint-Computer -Description ('WURepair ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'Точка восстановления создана.' 'OK'
        return $true
    } catch {
        Write-Log ('Точку восстановления создать не удалось: ' + $_.Exception.Message + '. Продолжаю — резервные копии настроек всё равно сохраняются.') 'WARN'
        return $false
    }
}

# ---------------------------------------------------------------------
#  Коды ошибок
# ---------------------------------------------------------------------
function Format-HResult {
    param($Code)
    if ($null -eq $Code -or "$Code" -eq '') { return $null }
    if ($Code -is [string]) {
        $s = $Code.Trim()
        if ($s -match '^(?i)0x([0-9a-f]{1,8})$') { return ('0x' + $Matches[1].ToUpper().PadLeft(8, '0')) }
        try { $Code = [int64]$s } catch { return $s }
    }
    try { $i = [int64]$Code } catch { return [string]$Code }
    if ($i -lt 0) { $i = $i + 4294967296 }
    if ($i -lt 0 -or $i -gt 4294967295) { return [string]$Code }
    return ('0x{0:X8}' -f [uint32]$i)
}

function Get-HResultFromError {
    param($ErrorRecord)
    $ex = $ErrorRecord
    if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    # Сначала — коды из текста сообщения (там настоящая причина, например
    # «Deployment failed with HRESULT: 0x80073CF3»), затем коды исключений.
    $msgCodes = @()
    $excCodes = @()
    $e = $ex
    while ($e) {
        foreach ($m in [regex]::Matches([string]$e.Message, '0x[0-9A-Fa-f]{8}')) { $msgCodes += $m.Value }
        if ($e -is [Runtime.InteropServices.COMException]) { $excCodes += $e.ErrorCode }
        if ($e.HResult) { $excCodes += $e.HResult }
        $e = $e.InnerException
    }
    foreach ($c in @($msgCodes + $excCodes)) {
        $h = Format-HResult $c
        if ($h -and $h -notin $script:GenericHResults) { return $h }
    }
    if ($excCodes.Count -gt 0) { return (Format-HResult $excCodes[0]) }
    return $null
}

# Обёрточные коды .NET/PowerShell — сами по себе ничего не говорят о причине.
$script:GenericHResults = @('0x80131500', '0x80131501', '0x80131509', '0x80131620', '0x80131600', '0x80131577', '0x80004005', '0x80131515', '0x80131502')

# Первая содержательная строка текста ошибки (для журнала).
function Get-ErrorText {
    param($ErrorRecord, [int]$Max = 400)
    $ex = $ErrorRecord
    if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    $t = ([string]$ex.Message -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '…' }
    return $t
}

function Get-ErrorMessages {
    param([string]$Text)
    if (-not $Text) { return @() }
    return @([regex]::Matches($Text, '0x[0-9A-Fa-f]{8}') | ForEach-Object { $_.Value.ToUpper() -replace '^0X', '0x' } | Select-Object -Unique)
}

# ---------------------------------------------------------------------
#  Находки диагностики
# ---------------------------------------------------------------------
function New-Finding {
    param(
        [string]$Id,
        [ValidateSet('OK', 'INFO', 'WARN', 'ERROR')][string]$Severity,
        [string]$Category,
        [string]$Title,
        [string]$Detail = '',
        [string[]]$Fix = @(),
        [switch]$NoUi
    )
    $f = [pscustomobject]@{
        Id       = $Id
        Severity = $Severity
        Category = $Category
        Title    = $Title
        Detail   = $Detail
        Fix      = @($Fix | Where-Object { $_ })
    }
    if (-not $NoUi) { Send-UiEvent 'finding' $f }
    return $f
}

# ---------------------------------------------------------------------
#  Загрузка файлов (свой загрузчик — BITS может быть сломан)
# ---------------------------------------------------------------------
function Invoke-Download {
    param([string]$Url, [string]$Destination, [string]$What = 'файл')
    Initialize-AppDirs
    $tmp = $Destination + '.part'
    Write-Log ('Скачиваю ' + $What + '…') 'STEP'
    Write-Log ('   ' + $Url) 'DEBUG'
    Set-UiProgress 0
    $resp = $null; $stream = $null; $fs = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WURepair/' + $script:AppVersion
        $req.AllowAutoRedirect = $true
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 120000
        $resp = $req.GetResponse()
        $total = $resp.ContentLength
        $stream = $resp.GetResponseStream()
        $fs = [IO.File]::Create($tmp)
        $buf = New-Object byte[] 262144
        $done = [long]0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastReport = 0
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n)
            $done += $n
            if ($sw.ElapsedMilliseconds - $lastReport -gt 1000) {
                $lastReport = $sw.ElapsedMilliseconds
                if ($total -gt 0) {
                    $pct = [int](100 * $done / $total)
                    Set-UiProgress $pct
                    Set-UiStatus ('Загрузка ' + $What + ': ' + [math]::Round($done / 1MB, 1) + ' из ' + [math]::Round($total / 1MB, 1) + ' МБ')
                } else {
                    Set-UiStatus ('Загрузка ' + $What + ': ' + [math]::Round($done / 1MB, 1) + ' МБ')
                }
            }
        }
        $fs.Dispose(); $fs = $null
        if ($total -gt 0 -and $done -lt $total) { throw ('Загрузка оборвалась: получено ' + $done + ' из ' + $total + ' байт') }
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
        Write-Log ('Скачано: ' + $Destination + ' (' + [math]::Round($done / 1MB, 1) + ' МБ)') 'OK'
        Set-UiProgress -1
        return $true
    } catch {
        $msg = $_.Exception.Message
        $status = $null
        try { if ($_.Exception.InnerException.Response) { $status = [int]$_.Exception.InnerException.Response.StatusCode } } catch { }
        try { if (-not $status -and $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        Write-Log ('Ошибка загрузки ' + $What + ': ' + $msg) 'ERROR'
        if ($status -eq 403 -or $status -eq 451) {
            if ($Url -match '(?i)claude\.ai|anthropic\.com') {
                Write-Log 'Сервер claude.ai отказал в загрузке. Claude доступен не во всех странах — список: https://www.anthropic.com/supported-countries' 'WARN'
            } else {
                Write-Log 'Сервер отказал в загрузке. Возможно, загрузка недоступна из вашей сети — попробуйте позже или из другой сети.' 'WARN'
            }
        } elseif ($msg -match '(?i)trust|SSL|TLS|сертификат|безопасн') {
            Write-Log 'Ошибка защищённого соединения. Частые причины: неверные дата/время на компьютере или антивирус, проверяющий HTTPS.' 'WARN'
        }
        Set-UiProgress -1
        return $false
    } finally {
        if ($fs) { $fs.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($resp) { $resp.Close() }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-FileSignature {
    param([string]$Path, [string]$ExpectedSigner)
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $subject = ''
        if ($sig.SignerCertificate) { $subject = $sig.SignerCertificate.Subject }
        if ($sig.Status -ne 'Valid') {
            Write-Log ('Подпись файла недействительна (' + $sig.Status + '): ' + $Path) 'ERROR'
            return $false
        }
        if ($ExpectedSigner -and $subject -notmatch [regex]::Escape($ExpectedSigner)) {
            Write-Log ('Файл подписан не тем издателем: ' + $subject) 'ERROR'
            return $false
        }
        Write-Log ('Цифровая подпись в порядке: ' + $subject) 'OK'
        return $true
    } catch {
        Write-Log ('Не удалось проверить подпись: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function Get-ArchName {
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($a) {
        'ARM64' { return 'arm64' }
        'AMD64' { return 'x64' }
        default { return 'x86' }
    }
}

# ---------------------------------------------------------------------
#  Службы
# ---------------------------------------------------------------------
function Stop-ServiceSafe {
    param([string]$Name, [int]$TimeoutSec = 30)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -eq 'Stopped') { return $true }
    try { Stop-Service -Name $Name -Force -NoWait -ErrorAction Stop } catch { }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $svc.Refresh()
        if ($svc.Status -eq 'Stopped') { return $true }
        Start-Sleep -Milliseconds 500
    }
    # служба зависла — завершаем её процесс, только если в нём нет других служб
    try {
        $w = Get-CimInstance Win32_Service -Filter ("Name='" + $Name + "'") -ErrorAction Stop
        if ($w.ProcessId -gt 0) {
            $shared = @(Get-CimInstance Win32_Service -Filter ('ProcessId=' + $w.ProcessId) -ErrorAction Stop)
            if ($shared.Count -le 1) {
                Stop-Process -Id $w.ProcessId -Force -ErrorAction Stop
                Start-Sleep -Seconds 1
                Write-Log "Служба $Name зависла — её процесс завершён принудительно." 'WARN'
                return $true
            }
        }
    } catch { }
    Write-Log "Не удалось остановить службу $Name." 'WARN'
    return $false
}

function Start-ServiceSafe {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    if ($svc.Status -eq 'Running') { return $true }
    try {
        Start-Service -Name $Name -ErrorAction Stop
        return $true
    } catch {
        $h = Get-HResultFromError $_
        Write-Log ("Служба $Name не запускается: " + $_.Exception.Message) 'WARN'
        return $false
    }
}

# Выполнить команду от имени SYSTEM (для защищённых ключей реестра служб)
function Invoke-AsSystem {
    param([string]$CommandLine, [int]$TimeoutSec = 90)
    $name = 'WURepair_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        $act = New-ScheduledTaskAction -Execute (Resolve-SystemExe 'cmd.exe') -Argument ('/d /c ' + $CommandLine)
        $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $name -Action $act -Principal $pr -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
        # 0x41301 = выполняется, 0x41303 = ещё не запускалась
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = [int64]-1
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            Start-Sleep -Milliseconds 500
            $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
            if (-not $t -or -not $info) { break }
            $res = [int64]$info.LastTaskResult
            if ([string]$t.State -ne 'Running' -and $res -ne 267009 -and $res -ne 267011) { break }
        }
        return $res
    } catch {
        Write-Log ('Не удалось выполнить действие от имени SYSTEM: ' + $_.Exception.Message) 'WARN'
        return -1
    } finally {
        try { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-FreeSpaceGB {
    param([string]$Drive = $env:SystemDrive)
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $Drive.TrimEnd('\') + "'") -ErrorAction Stop
        return [math]::Round($d.FreeSpace / 1GB, 1)
    } catch { return $null }
}
