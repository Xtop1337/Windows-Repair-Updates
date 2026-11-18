# =====================================================================
#  WURepair — диагностика
#  Каждая функция Test-* возвращает список «находок» (New-Finding).
# =====================================================================

function Get-VersionName {
    param([int]$Build)
    if ($Build -ge 22000) { return 'Windows 11' }
    if ($script:BuildNames.ContainsKey($Build)) { return [string]$script:BuildNames[$Build] }
    return ('сборка ' + $Build)
}

function Get-StartTypeName {
    param([int]$Start, [bool]$Delayed)
    switch ($Start) {
        0 { 'загрузка' }
        1 { 'система' }
        2 { if ($Delayed) { 'автоматически (отложенный запуск)' } else { 'автоматически' } }
        3 { 'вручную' }
        4 { 'отключена' }
        default { 'неизвестно' }
    }
}

function ConvertTo-AccountKey {
    param([string]$Account)
    $a = ([string]$Account).Trim().ToLowerInvariant()
    $a = $a -replace '^nt authority\\', '' -replace '^\.\\', ''
    return $a
}

function Get-AntivirusProducts {
    $list = @()
    try {
        $items = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop
        foreach ($i in $items) {
            $state = [int64]$i.productState
            $enabled = ((($state -shr 12) -band 0xF) -eq 1)
            $list += [pscustomobject]@{
                Name       = [string]$i.displayName
                Enabled    = $enabled
                IsDefender = ([string]$i.displayName -match '(?i)defender|Защитник')
            }
        }
    } catch { }
    return $list
}

function Get-SystemInfo {
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = 0
    try { $build = [int](Get-RegValue $cv 'CurrentBuildNumber') } catch { }
    if (-not $build) { $build = [Environment]::OSVersion.Version.Build }
    $ubr = Get-RegValue $cv 'UBR'
    $edition = [string](Get-RegValue $cv 'EditionID')
    $product = [string](Get-RegValue $cv 'ProductName')
    if ($build -ge 22000) { $product = $product -replace 'Windows 10', 'Windows 11' }
    $langHex = [string](Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' 'InstallLanguage')
    $lang = $langHex
    try { $lang = ([Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($langHex, 16))).Name } catch { }
    $ramGB = $null
    try { $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1) } catch { }
    $sMode = ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' 'SkuPolicyRequired') -eq 1)
    $installType = [string](Get-RegValue $cv 'InstallationType')
    return [pscustomobject]@{
        ProductName  = $product
        EditionID    = $edition
        Build        = $build
        UBR          = $ubr
        Version      = (Get-VersionName $build)
        Arch         = (Get-ArchName)
        Language     = $lang
        FreeGB       = (Get-FreeSpaceGB)
        RamGB        = $ramGB
        IsAdmin      = (Test-IsAdmin)
        SMode        = $sMode
        IsLTSC       = ($edition -match '(?i)EnterpriseS|IoTEnterpriseS')
        IsEnterprise = ($edition -match '(?i)^Enterprise')
        IsServer     = ($installType -match '(?i)server')
        Antivirus    = @(Get-AntivirusProducts)
        ComputerName = $env:COMPUTERNAME
    }
}

function Format-SystemInfo {
    param($Info)
    if (-not $Info) { return '' }
    $av = @($Info.Antivirus | ForEach-Object { $_.Name + $(if ($_.Enabled) { ' (вкл.)' } else { ' (выкл.)' }) }) -join ', '
    if (-not $av) { $av = 'не обнаружен' }
    $ubr = ''
    if ($null -ne $Info.UBR) { $ubr = '.' + $Info.UBR }
    return ('{0} ({1}), версия {2}, сборка {3}{4}, {5}, язык {6}  •  Диск {7} свободно {8} ГБ  •  ОЗУ {9} ГБ  •  Антивирус: {10}' -f `
            $Info.ProductName, $Info.EditionID, $Info.Version, $Info.Build, $ubr, $Info.Arch, $Info.Language, $env:SystemDrive, $Info.FreeGB, $Info.RamGB, $av)
}

# ---------------------------------------------------------------------
function Test-SystemBasics {
    param($Info)
    $f = @()
    if (-not $Info.IsAdmin) {
        $f += New-Finding 'admin' 'ERROR' 'Система' 'Программа запущена без прав администратора' 'Закройте программу и запустите снова — она сама попросит права администратора.'
    }
    $ubr = ''
    if ($null -ne $Info.UBR) { $ubr = '.' + $Info.UBR }
    $verText = ('{0} {1} (сборка {2}{3})' -f $Info.ProductName, $Info.Version, $Info.Build, $ubr)
    if ($Info.Build -ge 22000) {
        $f += New-Finding 'os-win11' 'INFO' 'Система' ('Это Windows 11: ' + $verText) 'Программа рассчитана на Windows 10, но большинство проверок и исправлений работают и здесь.'
    } elseif ($Info.Build -lt $script:ClaudeMinBuild) {
        $f += New-Finding 'os-old' 'ERROR' 'Система' ('Версия Windows слишком старая: ' + $verText) ('Claude Desktop и многие современные программы требуют Windows 10 версии 2004 (сборка 19041) или новее. ' +
            'Надёжнее всего нажать «Обновить Windows поверх» и обновиться до 22H2 — файлы и программы сохранятся.') @('InPlace')
    } elseif ($Info.Build -lt $script:LatestWin10Build) {
        $f += New-Finding 'os-outdated' 'WARN' 'Система' ('Версия Windows устарела: ' + $verText) ('Claude Desktop на ней уже работает (нужна 19041+), но последняя версия Windows 10 — 22H2 (19045). ' +
            'После ремонта её можно получить через Центр обновления или кнопкой «Обновить Windows поверх».') @('InPlace')
    } else {
        $f += New-Finding 'os-ok' 'OK' 'Система' ('Версия Windows актуальная: ' + $verText) ''
    }
    if ($Info.Build -lt 22000) {
        $f += New-Finding 'os-eos' 'INFO' 'Система' 'Поддержка Windows 10 закончилась 14 октября 2025 г.' ('Новые исправления безопасности приходят только по программе расширенной поддержки (ESU). ' +
            'Если компьютер подходит для Windows 11, со временем лучше перейти на неё.')
    }
    if ($Info.IsLTSC) {
        $f += New-Finding 'os-ltsc' 'INFO' 'Система' ('Выпуск LTSC/LTSB (' + $Info.EditionID + ')') ('В LTSC изначально нет Microsoft Store. Для обновления поверх подойдёт только образ LTSC того же языка — обычный образ с сайта Microsoft сохранить программы не даст.')
    } elseif ($Info.IsEnterprise) {
        $f += New-Finding 'os-ent' 'INFO' 'Система' ('Выпуск Enterprise (' + $Info.EditionID + ')') 'Для обновления поверх нужен образ с выпуском Enterprise.'
    }
    if ($Info.IsServer) {
        $f += New-Finding 'os-server' 'WARN' 'Система' 'Это серверная версия Windows' 'Программа рассчитана на Windows 10; часть проверок может быть неточной.'
    }
    if ($Info.SMode) {
        $f += New-Finding 'os-smode' 'ERROR' 'Система' 'Windows в режиме S' 'В режиме S можно ставить программы только из Магазина — Claude Desktop не установится. Выйти из режима S можно бесплатно через Microsoft Store («Выход из режима S»).'
    }
    if ($Info.Arch -eq 'x86') {
        $f += New-Finding 'os-x86' 'WARN' 'Система' '32-разрядная Windows' 'Claude Desktop работает только на 64-разрядной Windows (x64 или ARM64). Обновить 32-битную систему до 64-битной можно только чистой установкой.'
    }
    if ($null -ne $Info.FreeGB) {
        if ($Info.FreeGB -lt 10) {
            $f += New-Finding 'disk-low' 'ERROR' 'Диск' ('Мало места на диске ' + $env:SystemDrive + ' — свободно ' + $Info.FreeGB + ' ГБ') 'Для обновлений нужно минимум 10 ГБ, для обновления поверх — около 20 ГБ.' @('Disk')
        } elseif ($Info.FreeGB -lt 20) {
            $f += New-Finding 'disk-mid' 'WARN' 'Диск' ('Свободно ' + $Info.FreeGB + ' ГБ на ' + $env:SystemDrive) 'Обычным обновлениям хватит, но для обновления поверх нужно около 20 ГБ.' @('Disk')
        } else {
            $f += New-Finding 'disk-ok' 'OK' 'Диск' ('Свободно ' + $Info.FreeGB + ' ГБ на ' + $env:SystemDrive) ''
        }
    }
    return $f
}

function Test-PendingReboot {
    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if ($cbs -or $wu) {
        return (New-Finding 'reboot' 'WARN' 'Система' 'Windows ждёт перезагрузки' 'После прошлой установки нужна перезагрузка. Пока её нет, новые обновления часто не ставятся.' @('Reboot'))
    }
    return (New-Finding 'reboot-ok' 'OK' 'Система' 'Перезагрузка не требуется' '')
}

function Test-Services {
    param($Info)
    $f = @()
    $thirdAV = @($Info.Antivirus | Where-Object { -not $_.IsDefender }).Count -gt 0
    $bad = 0
    foreach ($s in $script:ServiceTable) {
        if ($s.MinBuild -and $Info.Build -lt $s.MinBuild) { continue }
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.N
        $isDef = ($s.G -eq 'Defender')
        if (-not (Test-Path -LiteralPath $key)) {
            if ($isDef -and $thirdAV) {
                $f += New-Finding ('svc-missing-' + $s.N) 'INFO' 'Защитник' ('Служба Защитника удалена: ' + $s.R) 'Сейчас работает сторонний антивирус, поэтому на обновления это не влияет.' @('Defender')
                continue
            }
            $sev = 'WARN'
            if ($s.Crit) { $sev = 'ERROR' }
            $fix = @('InPlace')
            if ($isDef) { $fix = @('Defender', 'InPlace') }
            $f += New-Finding ('svc-missing-' + $s.N) $sev 'Службы' ('Служба удалена: ' + $s.R + ' (' + $s.N + ')') 'Её удалила программа-«чистильщик» или её нет в урезанной сборке. Надёжно вернуть службу можно обновлением Windows поверх.' $fix
            $bad++
            continue
        }
        $problems = @()
        $start = Get-RegValue $key 'Start'
        if ($start -eq 4) { $problems += 'отключена' }
        $obj = [string](Get-RegValue $key 'ObjectName')
        if ($s.A -and $obj -and ((ConvertTo-AccountKey $obj) -ne (ConvertTo-AccountKey $s.A))) {
            $problems += ('запускается от чужой учётной записи (' + $obj + ')')
        }
        $img = [string](Get-RegValue $key 'ImagePath')
        if (-not $img) { $problems += 'не указан файл службы' }
        elseif ($s.Exe -and $img -notmatch [regex]::Escape($s.Exe)) { $problems += ('подменён файл службы (' + $img + ')') }
        $missingFile = $false
        if ($s.Dll) {
            $dll = [string](Get-RegValue ($key + '\Parameters') 'ServiceDll')
            if ($dll) {
                $exp = [Environment]::ExpandEnvironmentVariables($dll)
                if (-not (Test-Path -LiteralPath $exp)) { $problems += ('нет файла ' + [IO.Path]::GetFileName($exp)); $missingFile = $true }
            }
        }
        if ($problems.Count -eq 0) { continue }
        if ($isDef -and $thirdAV -and $problems.Count -eq 1 -and $start -eq 4) {
            $f += New-Finding ('svc-' + $s.N) 'INFO' 'Защитник' ($s.R + ': отключена') 'При стороннем антивирусе Защитник и должен быть выключен — это нормально.' @('Defender')
            continue
        }
        $sev = 'WARN'
        if ($s.Crit -or $s.G -eq 'WU') { $sev = 'ERROR' }
        $fix = @('Services')
        if ($isDef) { $fix = @('Defender') }
        if ($missingFile) { $fix += @('DISM', 'InPlace') }
        $f += New-Finding ('svc-' + $s.N) $sev 'Службы' ($s.R + ': ' + ($problems -join '; ')) ('Служба ' + $s.N + '. Обычный тип запуска: ' + (Get-StartTypeName $s.S $s.D) + '.') $fix
        $bad++
    }
    foreach ($n in @('wuauserv', 'BITS', 'UsoSvc')) {
        if (-not (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $n))) { continue }
        $r = Invoke-Proc 'sc.exe' ('sdshow ' + $n) -TimeoutSec 20 -Quiet
        if ($r.Output -match '\(D;') {
            $f += New-Finding ('svc-sd-' + $n) 'ERROR' 'Службы' ('Права службы ' + $n + ' изменены «блокировщиком» обновлений') 'В разрешениях службы есть запрет на запуск или изменение настроек.' @('Services')
            $bad++
        }
    }
    if ($bad -eq 0) {
        $f += New-Finding 'svc-ok' 'OK' 'Службы' 'Все нужные службы на месте и не отключены' ''
    }
    return $f
}

function Test-CriticalFiles {
    param($Info)
    $missing = @()
    foreach ($c in $script:CriticalFiles) {
        if ($c.MinBuild -and $Info.Build -lt $c.MinBuild) { continue }
        $p = Join-Path $env:windir $c.P
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $p = $p -replace '\\System32\\', '\Sysnative\' }
        if (-not (Test-Path -LiteralPath $p)) { $missing += ($c.P + ' — ' + $c.R) }
    }
    if ($missing.Count -gt 0) {
        return (New-Finding 'files-missing' 'ERROR' 'Файлы' ('Отсутствуют системные файлы (' + $missing.Count + ')') (($missing -join "`r`n") + "`r`nПопробуйте «Глубокое восстановление»; если не поможет — «Обновить Windows поверх».") @('DISM', 'InPlace'))
    }
    return (New-Finding 'files-ok' 'OK' 'Файлы' 'Ключевые файлы Центра обновления на месте' '')
}

function Test-TrimmedBuild {
    $f = @()
    $sxs = Join-Path $env:windir 'WinSxS'
    if (-not (Test-Path -LiteralPath $sxs)) {
        $f += New-Finding 'build-nosxs' 'ERROR' 'Сборка' 'Нет папки WinSxS (хранилища компонентов)' 'Без неё обновления не устанавливаются. Поможет только обновление Windows поверх.' @('InPlace')
        return $f
    }
    $pk = Join-Path $env:windir 'servicing\Packages'
    $cnt = -1
    try { $cnt = @([IO.Directory]::GetFiles($pk, '*.mum')).Count } catch { }
    if ($cnt -ge 0 -and $cnt -lt 500) {
        $f += New-Finding 'build-trimmed' 'WARN' 'Сборка' 'Похоже на урезанную «сборку» Windows' ('В хранилище компонентов всего ' + $cnt + ' пакетов (в обычной Windows 10 их обычно тысячи). ' +
            'В урезанных сборках часть компонентов вырезана навсегда, и обновления на них часто не ставятся. Если ремонт не поможет — «Обновить Windows поверх» с официального образа.') @('InPlace')
    } elseif ($cnt -ge 0) {
        $f += New-Finding 'build-ok' 'OK' 'Сборка' ('Хранилище компонентов выглядит полным (' + $cnt + ' пакетов)') ''
    }
    return $f
}

function Test-Policies {
    $f = @()
    $i = 0
    foreach ($c in $script:PolicyChecks) {
        $i++
        if (-not (Test-RegValue $c.P $c.N)) { continue }
        $v = Get-RegValue $c.P $c.N
        $isBad = $false
        try { $isBad = [bool](& $c.Bad $v) } catch { }
        if (-not $isBad) { continue }
        $title = $c.T
        try { $title = $c.T -f $v } catch { }
        $fix = @('Policies')
        if ($c.Area -eq 'Defender') { $fix = @('Defender') }
        if ($c.N -eq 'AllowAllTrustedApps') { $fix = @('Policies', 'Sideload') }
        $cat = 'Политики'
        if ($c.Area -eq 'Store') { $cat = 'Магазин/MSIX' }
        if ($c.Area -eq 'Defender') { $cat = 'Защитник' }
        $f += New-Finding ('pol-' + $i) $c.Sev $cat $title ('Параметр реестра: ' + (ConvertTo-NativeRegPath $c.P) + '\' + $c.N + ' = ' + $v) $fix
    }
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $exp = Get-RegValue $ux 'PauseUpdatesExpiryTime'
    if ($exp) {
        try {
            $d = [datetime]::Parse([string]$exp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal')
            if ($d -gt [datetime]::UtcNow) {
                $f += New-Finding 'pol-pause' 'WARN' 'Политики' ('Обновления приостановлены до ' + $d.ToLocalTime().ToString('dd.MM.yyyy')) 'Пауза включена в параметрах или «блокировщиком» (часто на годы вперёд).' @('Policies')
            }
        } catch { }
    }
    $maxp = Get-RegValue $ux 'FlightSettingsMaxPauseDays'
    if ($maxp -and [int]$maxp -gt 35) {
        $f += New-Finding 'pol-maxpause' 'INFO' 'Политики' ('Срок паузы обновлений увеличен до ' + $maxp + ' дней') 'Так делают «блокировщики», чтобы ставить обновления на паузу на годы.' @('Policies')
    }
    if (@($f | Where-Object { $_.Severity -in 'ERROR', 'WARN' -and $_.Category -eq 'Политики' }).Count -eq 0) {
        $f += New-Finding 'pol-ok' 'OK' 'Политики' 'Запрещающих политик Центра обновления нет' ''
    }
    return $f
}

function Test-Ifeo {
    $f = @()
    $bases = @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options')
    if ([Environment]::Is64BitOperatingSystem) { $bases += 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' }
    $found = @()
    foreach ($b in $bases) {
        foreach ($exe in $script:IfeoTargets) {
            $dbg = Get-RegValue (Join-Path $b $exe) 'Debugger'
            if ($dbg) { $found += ($exe + ' → ' + $dbg) }
        }
    }
    if ($found.Count -gt 0) {
        $f += New-Finding 'ifeo' 'ERROR' 'Блокировки' ('Запуск компонентов Windows заблокирован (' + $found.Count + ')') ('Через «Image File Execution Options» запуск программ подменён:' + "`r`n" + ($found -join "`r`n")) @('IFEO')
    } else {
        $f += New-Finding 'ifeo-ok' 'OK' 'Блокировки' 'Запуск программ обновления не заблокирован' ''
    }
    return $f
}

function Get-ScheduledTaskSafe {
    param([string]$FullName)
    $idx = $FullName.LastIndexOf('\')
    $path = $FullName.Substring(0, $idx + 1)
    $name = $FullName.Substring($idx + 1)
    try { return (Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop) } catch { return $null }
}

function Test-UpdateTasks {
    $disabled = @()
    foreach ($t in $script:UpdateTasks) {
        $task = Get-ScheduledTaskSafe $t
        if ($task -and [string]$task.State -eq 'Disabled') { $disabled += $t }
    }
    if ($disabled.Count -gt 0) {
        return (New-Finding 'tasks' 'WARN' 'Планировщик' ('Отключены задания автоматического обновления (' + $disabled.Count + ')') ($disabled -join "`r`n") @('Tasks'))
    }
    return (New-Finding 'tasks-ok' 'OK' 'Планировщик' 'Задания обновления в планировщике включены' '')
}

# ---------------------------------------------------------------------
#  hosts
# ---------------------------------------------------------------------
function Test-IsProtectedHost {
    param([string]$HostName)
    $h = ([string]$HostName).Trim().TrimEnd('.').ToLowerInvariant()
    if (-not $h -or $h -eq 'localhost') { return $false }
    if ($h -match $script:TelemetryHostPattern) { return $false }
    foreach ($s in $script:ProtectedDomainSuffixes) {
        if ($h -eq $s -or $h.EndsWith('.' + $s)) { return $true }
    }
    return $false
}

function Get-HostsBlockEntries {
    param([string[]]$Lines)
    $res = @()
    if (-not $Lines) { return $res }
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $raw = [string]$Lines[$i]
        $content = ($raw -split '#', 2)[0].Trim()
        if (-not $content) { continue }
        $tokens = @($content -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -lt 2) { continue }
        $names = @($tokens[1..($tokens.Count - 1)])
        $hit = @($names | Where-Object { Test-IsProtectedHost $_ })
        if ($hit.Count -gt 0) {
            $res += [pscustomobject]@{
                Index     = $i
                Line      = $raw
                Ip        = $tokens[0]
                Hosts     = $names
                Protected = $hit
                Keep      = @($names | Where-Object { -not (Test-IsProtectedHost $_) })
            }
        }
    }
    return $res
}

function Read-TextFileSmart {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $enc = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = New-Object Text.UTF8Encoding $true }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode }
    else {
        try {
            $strict = New-Object Text.UTF8Encoding($false, $true)
            [void]$strict.GetString($bytes)
            $enc = New-Object Text.UTF8Encoding $false
        } catch { $enc = [Text.Encoding]::Default }
    }
    $text = $enc.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = $text -split "\r?\n"
    return [pscustomobject]@{ Lines = $lines; Encoding = $enc }
}

function Get-HostsPath { return (Join-Path $env:windir 'System32\drivers\etc\hosts') }

function Test-HostsFile {
    $path = Get-HostsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return (New-Finding 'hosts-none' 'OK' 'Сеть' 'Файл hosts отсутствует (это не мешает)' '')
    }
    try { $data = Read-TextFileSmart $path } catch {
        return (New-Finding 'hosts-read' 'WARN' 'Сеть' 'Не удалось прочитать файл hosts' $_.Exception.Message @('Hosts'))
    }
    $bad = @(Get-HostsBlockEntries -Lines $data.Lines)
    if ($bad.Count -gt 0) {
        $sample = @($bad | Select-Object -First 15 | ForEach-Object { $_.Line.Trim() })
        $more = ''
        if ($bad.Count -gt 15) { $more = "`r`n… и ещё " + ($bad.Count - 15) }
        return (New-Finding 'hosts' 'ERROR' 'Сеть' ('В файле hosts заблокированы серверы Microsoft (' + $bad.Count + ' строк)') (($sample -join "`r`n") + $more + "`r`nЧисто «шпионские» адреса (телеметрия) останутся заблокированными.") @('Hosts'))
    }
    return (New-Finding 'hosts-ok' 'OK' 'Сеть' 'Файл hosts не блокирует серверы Microsoft' '')
}

# ---------------------------------------------------------------------
#  Маршруты, брандмауэр, прокси
# ---------------------------------------------------------------------
function Get-BlackholeRoutes {
    param([string[]]$RouteNames)
    $res = @()
    foreach ($n in $RouteNames) {
        $p = @(([string]$n).Split(','))
        if ($p.Count -lt 3) { continue }
        $gw = $p[2].Trim()
        if ($gw -in @('0.0.0.0', '127.0.0.1')) {
            $res += [pscustomobject]@{ Name = $n; Destination = $p[0].Trim(); Mask = $p[1].Trim(); Gateway = $gw }
        }
    }
    return $res
}

function Get-PersistentRouteNames {
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\PersistentRoutes'
    try { return @((Get-Item -LiteralPath $k -ErrorAction Stop).GetValueNames()) } catch { return @() }
}

function Test-PersistentRoutes {
    $bh = @(Get-BlackholeRoutes (Get-PersistentRouteNames))
    if ($bh.Count -gt 0) {
        $sample = @($bh | Select-Object -First 10 | ForEach-Object { $_.Destination + ' → ' + $_.Gateway })
        return (New-Finding 'routes' 'ERROR' 'Сеть' ('Найдены «мёртвые» постоянные маршруты (' + $bh.Count + ')') ('Такие маршруты добавляют программы «против слежки» (например, DWS): трафик к серверам Microsoft уходит в никуда.' + "`r`n" + ($sample -join "`r`n")) @('Routes'))
    }
    return (New-Finding 'routes-ok' 'OK' 'Сеть' 'Блокирующих маршрутов нет' '')
}

function Get-SuspectFirewallRules {
    $sus = @()
    $fwErr = $null
    $rules = @(Get-NetFirewallRule -Direction Outbound -Action Block -Enabled True -ErrorAction SilentlyContinue -ErrorVariable fwErr)
    # «правил не найдено» — это не ошибка
    $real = @($fwErr | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' })
    if ($rules.Count -eq 0 -and $real.Count -gt 0) { throw $real[0] }
    foreach ($r in $rules) {
        $why = $null
        $text = ([string]$r.DisplayName + ' ' + [string]$r.Description + ' ' + [string]$r.Group + ' ' + [string]$r.Name)
        if ($text -match $script:FirewallSuspectPattern) { $why = 'название правила' }
        if (-not $why) {
            try {
                $svc = [string]($r | Get-NetFirewallServiceFilter -ErrorAction Stop).Service
                if ($svc -and ($script:FirewallSuspectServices -contains $svc.ToLowerInvariant())) { $why = 'служба ' + $svc }
            } catch { }
        }
        if (-not $why) {
            try {
                $prog = [string]($r | Get-NetFirewallApplicationFilter -ErrorAction Stop).Program
                if ($prog -match $script:FirewallSuspectPrograms) { $why = 'программа ' + $prog }
            } catch { }
        }
        if ($why) { $sus += [pscustomobject]@{ Name = $r.Name; DisplayName = $r.DisplayName; Why = $why } }
    }
    return $sus
}

function Test-FirewallRules {
    $f = @()
    try {
        $sus = @(Get-SuspectFirewallRules)
    } catch {
        return (New-Finding 'fw-read' 'INFO' 'Сеть' 'Не удалось прочитать правила брандмауэра Windows' $_.Exception.Message)
    }
    if ($sus.Count -gt 0) {
        $sample = @($sus | Select-Object -First 12 | ForEach-Object { $_.DisplayName + '  (' + $_.Why + ')' })
        $f += New-Finding 'fw' 'ERROR' 'Сеть' ('Брандмауэр блокирует компоненты обновления (' + $sus.Count + ' правил)') (($sample -join "`r`n") + "`r`nПравила будут не удалены, а выключены (с резервной копией).") @('Firewall')
    } else {
        $f += New-Finding 'fw-ok' 'OK' 'Сеть' 'Брандмауэр не блокирует обновления' ''
    }
    try {
        $prof = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.Enabled -and [string]$_.DefaultOutboundAction -eq 'Block' })
        if ($prof.Count -gt 0) {
            $f += New-Finding 'fw-outbound' 'WARN' 'Сеть' 'Брандмауэр по умолчанию запрещает все исходящие соединения' ('Профили: ' + (($prof | ForEach-Object { $_.Name }) -join ', ') + '. Так настраивают «приватные» программы; обновлениям нужен выход в интернет.')
        }
    } catch { }
    return $f
}

function ConvertFrom-WinHttpSettings {
    param([byte[]]$Bytes)
    $r = [pscustomobject]@{ Proxy = $null; Bypass = $null }
    if (-not $Bytes -or $Bytes.Length -lt 16) { return $r }
    $flags = [BitConverter]::ToInt32($Bytes, 8)
    $len = [BitConverter]::ToInt32($Bytes, 12)
    if ($len -gt 0 -and (16 + $len) -le $Bytes.Length) {
        $r.Proxy = [Text.Encoding]::ASCII.GetString($Bytes, 16, $len)
        $o = 16 + $len
        if (($o + 4) -le $Bytes.Length) {
            $bl = [BitConverter]::ToInt32($Bytes, $o)
            if ($bl -gt 0 -and ($o + 4 + $bl) -le $Bytes.Length) { $r.Bypass = [Text.Encoding]::ASCII.GetString($Bytes, $o + 4, $bl) }
        }
    }
    if (($flags -band 2) -eq 0) { $r.Proxy = $null }
    return $r
}

function Get-WinHttpProxy {
    $bin = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' 'WinHttpSettings'
    return (ConvertFrom-WinHttpSettings $bin)
}

function Test-Proxy {
    $f = @()
    $p = Get-WinHttpProxy
    if ($p.Proxy) {
        $f += New-Finding 'proxy-winhttp' 'WARN' 'Сеть' ('Задан системный прокси WinHTTP: ' + $p.Proxy) 'Через него Центр обновления выходит в интернет. Если прокси не работает — обновления не скачиваются. Сбросится, только если серверы Microsoft недоступны.' @('Proxy')
    }
    $is = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ((Get-RegValue $is 'ProxyEnable') -eq 1) {
        $f += New-Finding 'proxy-user' 'INFO' 'Сеть' ('Включён прокси пользователя: ' + (Get-RegValue $is 'ProxyServer')) 'Если вы не ставили прокси сами (VPN-программа и т.п.), его стоит выключить в «Параметры → Сеть → Прокси».'
    }
    if ($f.Count -eq 0) { $f += New-Finding 'proxy-ok' 'OK' 'Сеть' 'Прокси не задан' '' }
    return $f
}

# ---------------------------------------------------------------------
#  Время и доступность серверов
# ---------------------------------------------------------------------
function Get-InternetUtcTime {
    foreach ($u in @('http://www.msftconnecttest.com/connecttest.txt', 'http://www.msftncsi.com/ncsi.txt', 'http://www.google.com/generate_204')) {
        $resp = $null
        try {
            $req = [Net.HttpWebRequest]::Create($u)
            $req.Method = 'HEAD'
            $req.Timeout = 8000
            $req.UserAgent = 'WURepair'
            $resp = $req.GetResponse()
            $d = $resp.Headers['Date']
            if ($d) { return [datetime]::Parse($d, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal') }
        } catch {
            try {
                $er = $_.Exception.InnerException.Response
                if ($er -and $er.Headers['Date']) { return [datetime]::Parse($er.Headers['Date'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal') }
            } catch { }
        } finally { if ($resp) { $resp.Close() } }
    }
    return $null
}

function Test-SystemTime {
    $net = Get-InternetUtcTime
    if (-not $net) {
        return (New-Finding 'time-unknown' 'INFO' 'Время' 'Не удалось сверить время с интернетом' 'Проверьте вручную, что дата, время и часовой пояс на компьютере верные.')
    }
    $skew = [math]::Abs(([datetime]::UtcNow - $net).TotalSeconds)
    $script:LastInternetTime = $net
    if ($skew -gt 600) {
        $h = [math]::Round($skew / 3600, 1)
        return (New-Finding 'time' 'ERROR' 'Время' ('Часы компьютера сбиты (разница ~' + $h + ' ч)') 'Из-за неверного времени не проходят защищённые соединения (ошибки 0x80072F8F, 0x80131500 и т.п.).' @('Time'))
    }
    return (New-Finding 'time-ok' 'OK' 'Время' 'Время на компьютере верное' '')
}

function Test-TcpEndpoint {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 3500)
    $r = [pscustomobject]@{ Host = $HostName; Port = $Port; Resolved = ''; Ok = $false; Error = $null; Blocked = $false }
    $ips = $null
    try { $ips = [Net.Dns]::GetHostAddresses($HostName) } catch {
        $r.Error = 'имя не найдено (DNS)'
        return $r
    }
    $r.Resolved = (@($ips | ForEach-Object { $_.IPAddressToString }) -join ', ')
    $sink = @($ips | Where-Object { $_.IPAddressToString -in @('0.0.0.0', '127.0.0.1', '::1', '::') })
    if ($sink.Count -gt 0) {
        $r.Error = 'адрес подменён на ' + $sink[0].IPAddressToString + ' (блокировка через hosts/DNS)'
        $r.Blocked = $true
        return $r
    }
    $target = @($ips | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork })[0]
    if ($target) { $c = New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetwork) }
    else { $target = $ips[0]; $c = New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetworkV6) }
    try {
        $ar = $c.BeginConnect($target, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $c.EndConnect($ar)
            $r.Ok = $true
        } else { $r.Error = 'нет ответа (таймаут)' }
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        $r.Error = $msg
    } finally { try { $c.Close() } catch { } }
    return $r
}

function Test-Connectivity {
    $f = @()
    $results = @()
    foreach ($t in $script:ConnectivityTargets) {
        $res = Test-TcpEndpoint $t.H $t.P
        $res | Add-Member -NotePropertyName Need -NotePropertyValue $t.Need
        $res | Add-Member -NotePropertyName Role -NotePropertyValue $t.R
        $results += $res
        if ($res.Ok) { Write-Log ('   ' + $t.H + ':' + $t.P + ' — доступен') 'DEBUG' }
        else { Write-Log ('   ' + $t.H + ':' + $t.P + ' — ' + $res.Error) 'WARN' }
    }
    $script:LastConnectivity = $results
    $wuFail = @($results | Where-Object { -not $_.Ok -and $_.Need -ne 'Claude' })
    $wuTotal = @($results | Where-Object { $_.Need -ne 'Claude' }).Count
    if ($wuFail.Count -eq 0) {
        $f += New-Finding 'net-ok' 'OK' 'Сеть' 'Серверы Microsoft доступны' ''
    } else {
        $internet = $false
        foreach ($h in @('www.cloudflare.com', 'ya.ru', 'www.google.com')) {
            if ((Test-TcpEndpoint $h 443 3000).Ok) { $internet = $true; break }
        }
        $list = @($wuFail | ForEach-Object { $_.Host + ' — ' + $_.Error }) -join "`r`n"
        if (-not $internet -and $wuFail.Count -eq $wuTotal) {
            $f += New-Finding 'net-none' 'ERROR' 'Сеть' 'Нет подключения к интернету' ('Не отвечает ни один сервер, в том числе обычные сайты. Проверьте интернет.' + "`r`n" + $list) @('Network', 'Proxy')
        } else {
            $sev = 'ERROR'
            if ($wuFail.Count -le 1) { $sev = 'WARN' }
            $f += New-Finding 'net-blocked' $sev 'Сеть' ('Серверы Microsoft недоступны (' + $wuFail.Count + ' из ' + $wuTotal + '), а остальной интернет работает') ('Скорее всего, они заблокированы (hosts, маршруты, брандмауэр, прокси).' + "`r`n" + $list) @('Hosts', 'Routes', 'Firewall', 'Proxy', 'Network')
        }
    }
    $cl = @($results | Where-Object { $_.Need -eq 'Claude' -and -not $_.Ok })
    if ($cl.Count -gt 0) {
        $f += New-Finding 'net-claude' 'WARN' 'Сеть' 'Сайт claude.ai недоступен' ('Без него не скачать Claude Desktop. ' + $cl[0].Error)
    }
    return $f
}

# ---------------------------------------------------------------------
#  Журналы событий
# ---------------------------------------------------------------------
function Get-EventErrorSummary {
    param([object[]]$Events, [string]$CodeFilter = '')
    $map = @{}
    foreach ($e in $Events) {
        $msg = [string]$e.Message
        $codes = @(Get-ErrorMessages $msg)
        if ($codes.Count -eq 0) {
            foreach ($p in $e.Properties) {
                $v = $p.Value
                if ($v -is [int] -or $v -is [uint32] -or $v -is [long]) {
                    $h = Format-HResult $v
                    if ($h -match '^0x8|^0xC') { $codes += $h }
                }
            }
        }
        foreach ($c in $codes) {
            if ($CodeFilter -and $c -notmatch $CodeFilter) { continue }
            if (-not $map.ContainsKey($c)) { $map[$c] = [pscustomobject]@{ Code = $c; Count = 0; Last = $e.TimeCreated; Kbs = @(); Claude = $false } }
            $entry = $map[$c]
            $entry.Count++
            if ($e.TimeCreated -gt $entry.Last) { $entry.Last = $e.TimeCreated }
            foreach ($m in [regex]::Matches($msg, 'KB\d{6,7}')) { if ($entry.Kbs -notcontains $m.Value) { $entry.Kbs += $m.Value } }
            if ($msg -match '(?i)claude') { $entry.Claude = $true }
        }
    }
    return @($map.Values | Sort-Object Last -Descending)
}

function Get-WinEventSafe {
    param([hashtable]$Filter, [int]$Max = 300)
    try { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { return @() }
        throw
    }
}

function Test-UpdateEventLog {
    $f = @()
    try {
        $ev = Get-WinEventSafe @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = @(20, 25, 31); StartTime = (Get-Date).AddDays(-60) } 400
    } catch {
        return (New-Finding 'evt-wu-read' 'INFO' 'Журналы' 'Журнал Центра обновления недоступен' ('Возможно, отключена служба журнала событий. ' + $_.Exception.Message))
    }
    $sum = @(Get-EventErrorSummary -Events $ev)
    $script:LastWUCodes = $sum
    if ($sum.Count -eq 0) {
        return (New-Finding 'evt-wu-ok' 'OK' 'Журналы' 'За 60 дней ошибок Центра обновления в журнале нет' '')
    }
    foreach ($s in ($sum | Select-Object -First 8)) {
        $info = Get-ErrorInfo $s.Code
        $kb = ''
        if ($s.Kbs.Count -gt 0) { $kb = ' Обновления: ' + (($s.Kbs | Select-Object -First 6) -join ', ') + '.' }
        $sev = 'WARN'
        if ($s.Last -gt (Get-Date).AddDays(-14)) { $sev = 'ERROR' }
        $fix = $info.Fix
        if ($s.Code -eq '0x80070643' -and ($s.Kbs -contains 'KB5034441')) {
            $sev = 'INFO'
            $fix = @('KB5034441')
        }
        $f += New-Finding ('evt-wu-' + $s.Code) $sev 'Ошибки обновления' ('Ошибка ' + $s.Code + ' (' + $s.Count + ' раз, последний — ' + $s.Last.ToString('dd.MM.yyyy') + ')') ($info.Text + $kb + ' Что поможет: ' + (Format-FixList $fix) + '.') $fix
    }
    return $f
}

function Test-AppxEventLog {
    $f = @()
    try {
        $ev = Get-WinEventSafe @{ LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'; Level = 2; StartTime = (Get-Date).AddDays(-30) } 300
    } catch { return $f }
    $sum = @(Get-EventErrorSummary -Events $ev -CodeFilter '^0x80073[CD]')
    foreach ($s in ($sum | Where-Object { $_.Code -notin @('0x80073D02', '0x80073CFB', '0x80073D06') } | Select-Object -First 5)) {
        $info = Get-ErrorInfo $s.Code
        $who = 'приложения'
        if ($s.Claude) { $who = 'Claude Desktop' }
        $f += New-Finding ('evt-appx-' + $s.Code) 'WARN' 'Магазин/MSIX' ('Ошибка установки ' + $who + ': ' + $s.Code + ' (' + $s.Count + ' раз)') ($info.Text + ' Что поможет: ' + (Format-FixList $info.Fix) + '.') $info.Fix
    }
    return $f
}

# ---------------------------------------------------------------------
#  Хранилище компонентов, приложения, Защитник, прошлые обновления поверх
# ---------------------------------------------------------------------
function Test-ComponentStore {
    $state = $null
    try {
        $r = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
        $state = [string]$r.ImageHealthState
    } catch {
        return (New-Finding 'cbs-unknown' 'INFO' 'Компоненты' 'Не удалось проверить хранилище компонентов' $_.Exception.Message)
    }
    switch ($state) {
        'Healthy' { return (New-Finding 'cbs-ok' 'OK' 'Компоненты' 'Хранилище компонентов не повреждено' '') }
        'Repairable' { return (New-Finding 'cbs-bad' 'ERROR' 'Компоненты' 'Хранилище компонентов повреждено (можно восстановить)' 'Поможет «Глубокое восстановление (DISM + SFC)».' @('DISM')) }
        'NonRepairable' { return (New-Finding 'cbs-dead' 'ERROR' 'Компоненты' 'Хранилище компонентов повреждено необратимо' 'Поможет только «Обновить Windows поверх».' @('InPlace')) }
        default { return (New-Finding 'cbs-unknown' 'INFO' 'Компоненты' ('Состояние хранилища компонентов: ' + $state) '') }
    }
}

function Test-AppxPlatform {
    param($Info)
    $f = @()
    $pk = $null
    try {
        $pk = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
    } catch {
        $f += New-Finding 'appx-broken' 'ERROR' 'Магазин/MSIX' 'Система установки приложений (AppX/MSIX) не работает' ('Из-за этого не ставятся Claude Desktop и приложения из Магазина. ' + $_.Exception.Message) @('Services', 'DISM')
        return $f
    }
    $script:LastAppxNames = @($pk | ForEach-Object { $_.Name } | Select-Object -Unique)
    foreach ($sp in $script:StorePackages) {
        $has = @($pk | Where-Object { $_.Name -eq $sp.N }).Count -gt 0
        if ($has) { continue }
        switch ($sp.N) {
            'Microsoft.WindowsStore' {
                $sev = 'WARN'
                if ($Info.IsLTSC) { $sev = 'INFO' }
                $f += New-Finding 'store-missing' $sev 'Магазин/MSIX' 'Microsoft Store удалён' 'Claude Desktop ставится и без Магазина (официальным пакетом MSIX), но Магазин нужен для многих других программ.' @('Store')
            }
            'Microsoft.Windows.SecHealthUI' {
                $f += New-Finding 'sechealth-missing' 'WARN' 'Защитник' 'Приложение «Безопасность Windows» удалено' 'Его можно вернуть кнопкой «Вернуть Защитник».' @('Defender')
            }
            'Microsoft.DesktopAppInstaller' {
                $f += New-Finding 'appinst-missing' 'INFO' 'Магазин/MSIX' 'Нет «Установщика приложений» (winget)' 'Он ставится вместе с восстановлением Магазина.' @('Store')
            }
            default {
                $f += New-Finding ('pkg-missing-' + $sp.N) 'INFO' 'Магазин/MSIX' ('Нет пакета: ' + $sp.R) '' @('Store')
            }
        }
    }
    $unlock = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowAllTrustedApps'
    if ($Info.Build -lt 19041 -and $unlock -ne 1) {
        $f += New-Finding 'sideload' 'WARN' 'Магазин/MSIX' 'Установка приложений не из Магазина выключена' 'В Windows до версии 2004 её нужно разрешать отдельно (иначе ошибка 0x80073CFF).' @('Sideload')
    } elseif ($unlock -eq 0 -and (Test-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowAllTrustedApps')) {
        $f += New-Finding 'sideload' 'WARN' 'Магазин/MSIX' 'Установка доверенных приложений не из Магазина выключена' 'Может давать ошибку 0x80073CFF при установке Claude Desktop.' @('Sideload')
    }
    $claude = @($pk | Where-Object { $_.Name -eq 'Claude' -or $_.PackageFamilyName -like 'Claude_*' })
    if ($claude.Count -gt 0) {
        $f += New-Finding 'claude-installed' 'OK' 'Claude' ('Claude Desktop установлен (версия ' + $claude[0].Version + ')') ''
    }
    if (@($f | Where-Object { $_.Severity -in 'ERROR', 'WARN' }).Count -eq 0) {
        $f += New-Finding 'appx-ok' 'OK' 'Магазин/MSIX' 'Установка приложений MSIX работает' ''
    }
    return $f
}

function Test-Defender {
    param($Info)
    $third = @($Info.Antivirus | Where-Object { -not $_.IsDefender -and $_.Enabled })
    $anyThird = @($Info.Antivirus | Where-Object { -not $_.IsDefender })
    $defOn = @($Info.Antivirus | Where-Object { $_.IsDefender -and $_.Enabled })
    $msmp = Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Windows Defender\MsMpEng.exe')
    $plat = $false
    try { $plat = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform') -Filter 'MsMpEng.exe' -Recurse -ErrorAction Stop).Count -gt 0 } catch { }
    if ($third.Count -gt 0) {
        return (New-Finding 'av-third' 'OK' 'Защитник' ('Работает антивирус: ' + (($third | ForEach-Object { $_.Name }) -join ', ')) ('Защитник Windows при этом и должен быть выключен — это нормально. Если антивирус мешает ремонту (блокирует изменения hosts, служб), временно отключите его самозащиту.'))
    }
    if ($defOn.Count -gt 0) {
        return (New-Finding 'av-def' 'OK' 'Защитник' 'Защитник Windows работает' '')
    }
    if (-not $msmp -and -not $plat) {
        $extra = ''
        if ($anyThird.Count -gt 0) { $extra = ' Установлен, но выключен: ' + (($anyThird | ForEach-Object { $_.Name }) -join ', ') + '.' }
        return (New-Finding 'av-none' 'ERROR' 'Защитник' 'Защитник Windows удалён, а другой антивирус не работает' ('Компьютер без защиты.' + $extra + ' Полностью вернуть Защитник можно обновлением Windows поверх; можно также включить сторонний антивирус.') @('Defender', 'InPlace'))
    }
    return (New-Finding 'av-off' 'WARN' 'Защитник' 'Антивирус не работает' 'Файлы Защитника на месте, но он выключен. Кнопка «Вернуть Защитник» снимет запреты и включит его службы.' @('Defender'))
}

function Test-PreviousUpgrade {
    $f = @()
    $panther = Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Panther'
    if (-not (Test-Path -LiteralPath $panther)) { return $f }
    $err = Join-Path $panther 'setuperr.log'
    if (Test-Path -LiteralPath $err) {
        try {
            $tail = @(Get-Content -LiteralPath $err -Tail 400 -ErrorAction Stop)
            $codes = @(Get-ErrorMessages ($tail -join "`n") | Where-Object { $_ -match '^0xC19|^0x8007' } | Select-Object -First 6)
            if ($codes.Count -gt 0) {
                $txt = @($codes | ForEach-Object { $_ + ' — ' + (Get-ErrorInfo $_).Text }) -join "`r`n"
                $f += New-Finding 'setup-prev' 'WARN' 'Обновление поверх' 'Прошлая попытка обновления поверх завершилась с ошибками' ($txt + "`r`nЖурнал: " + $err) @('InPlace')
            }
        } catch { }
    }
    try {
        $blocks = @()
        foreach ($x in @(Get-ChildItem -LiteralPath $panther -Filter 'CompatData*.xml' -ErrorAction Stop)) {
            $xml = New-Object xml
            $xml.Load($x.FullName)
            foreach ($n in $xml.SelectNodes("//*[local-name()='CompatibilityInfo'][@BlockingType='Hard']")) {
                $name = $n.ParentNode.GetAttribute('Name')
                if (-not $name) { $name = $n.ParentNode.GetAttribute('Inf') }
                if ($name -and $blocks -notcontains $name) { $blocks += $name }
            }
        }
        if ($blocks.Count -gt 0) {
            $f += New-Finding 'setup-blocks' 'WARN' 'Обновление поверх' ('Обновлению поверх мешают программы/драйверы (' + $blocks.Count + ')') (($blocks -join "`r`n") + "`r`nУдалите или обновите их перед новой попыткой.") @('InPlace')
        }
    } catch { }
    return $f
}

# ---------------------------------------------------------------------
#  Пробный поиск обновлений (в отдельном процессе — его можно прервать)
# ---------------------------------------------------------------------
function Invoke-WUSearchProbe {
    param([int]$TimeoutSec = 240)
    $sb = {
        $ErrorActionPreference = 'Stop'
        try {
            $s = New-Object -ComObject Microsoft.Update.Session
            $s.ClientApplicationID = 'WURepair'
            $q = $s.CreateUpdateSearcher()
            $r = $q.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            'RESULT:OK:' + $r.Updates.Count
            foreach ($u in $r.Updates) { 'UPD:' + $u.Title }
        } catch {
            $h = $_.Exception.HResult
            if ($_.Exception.InnerException) { $h = $_.Exception.InnerException.HResult }
            'RESULT:ERR:' + ('0x{0:X8}' -f $h) + ':' + $_.Exception.Message
        }
    }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sb.ToString()))
    $r = Invoke-Proc 'powershell.exe' ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $enc) -TimeoutSec $TimeoutSec -Quiet
    $res = [pscustomobject]@{ Ok = $false; Count = 0; Code = $null; Message = ''; Updates = @(); TimedOut = $r.TimedOut }
    foreach ($line in ($r.Output -split "\r?\n")) {
        if ($line -match '^RESULT:OK:(\d+)') { $res.Ok = $true; $res.Count = [int]$Matches[1] }
        elseif ($line -match '^RESULT:ERR:(0x[0-9A-Fa-f]{8}):(.*)$') { $res.Code = $Matches[1].ToUpper() -replace '^0X', '0x'; $res.Message = $Matches[2] }
        elseif ($line -match '^UPD:(.*)$') { $res.Updates += $Matches[1] }
    }
    return $res
}

function Test-WUSearch {
    Write-Log 'Пробный поиск обновлений (до 4 минут)…' 'INFO'
    $p = Invoke-WUSearchProbe -TimeoutSec 240
    $script:LastScan = $p
    if ($p.Ok) {
        $list = ''
        if ($p.Updates.Count -gt 0) { $list = ($p.Updates | Select-Object -First 15) -join "`r`n" }
        $t = 'Поиск обновлений работает'
        if ($p.Count -gt 0) { $t += (' — найдено обновлений: ' + $p.Count) } else { $t += ' — новых обновлений нет' }
        return (New-Finding 'scan-ok' 'OK' 'Центр обновления' $t $list)
    }
    if ($p.TimedOut) {
        return (New-Finding 'scan-timeout' 'ERROR' 'Центр обновления' 'Поиск обновлений зависает (не ответил за 4 минуты)' 'Обычно помогает сброс компонентов Центра обновления.' @('ResetWU', 'Services'))
    }
    if ($p.Code) {
        $info = Get-ErrorInfo $p.Code
        return (New-Finding 'scan-fail' 'ERROR' 'Центр обновления' ('Поиск обновлений не работает: ошибка ' + $p.Code) ($info.Text + ' Что поможет: ' + (Format-FixList $info.Fix) + '.') $info.Fix)
    }
    return (New-Finding 'scan-fail' 'ERROR' 'Центр обновления' 'Поиск обновлений не работает' 'Не удалось запустить проверку обновлений.' @('ResetWU', 'Services'))
}

# ---------------------------------------------------------------------
#  Полная диагностика
# ---------------------------------------------------------------------
function Get-RecommendedFixes {
    param([object[]]$Findings)
    $fixes = @()
    foreach ($f in $Findings) {
        if ($f.Severity -notin @('ERROR', 'WARN')) { continue }
        foreach ($x in $f.Fix) { if ($fixes -notcontains $x) { $fixes += $x } }
    }
    return $fixes
}

function Invoke-Diagnostics {
    param([switch]$SkipScan, [switch]$Quiet)
    Initialize-AppDirs
    Send-UiEvent 'clearfindings' $null
    Write-Log '=============== ДИАГНОСТИКА ===============' 'STEP'
    $info = Get-SystemInfo
    $script:LastSysInfo = $info
    Send-UiEvent 'sysinfo' $info
    Write-Log (Format-SystemInfo $info) 'INFO'

    $steps = @(
        @{ N = 'версия Windows, диск';           S = { Test-SystemBasics $info } }
        @{ N = 'ожидание перезагрузки';          S = { Test-PendingReboot } }
        @{ N = 'службы';                         S = { Test-Services $info } }
        @{ N = 'системные файлы';                S = { Test-CriticalFiles $info } }
        @{ N = 'урезанная сборка';               S = { Test-TrimmedBuild } }
        @{ N = 'политики';                       S = { Test-Policies } }
        @{ N = 'блокировка запуска программ';    S = { Test-Ifeo } }
        @{ N = 'задания планировщика';           S = { Test-UpdateTasks } }
        @{ N = 'файл hosts';                     S = { Test-HostsFile } }
        @{ N = 'сетевые маршруты';               S = { Test-PersistentRoutes } }
        @{ N = 'брандмауэр';                     S = { Test-FirewallRules } }
        @{ N = 'прокси';                         S = { Test-Proxy } }
        @{ N = 'дата и время';                   S = { Test-SystemTime } }
        @{ N = 'доступность серверов Microsoft'; S = { Test-Connectivity } }
        @{ N = 'журнал Центра обновления';       S = { Test-UpdateEventLog } }
        @{ N = 'хранилище компонентов';          S = { Test-ComponentStore } }
        @{ N = 'Магазин и приложения MSIX';      S = { Test-AppxPlatform $info } }
        @{ N = 'журнал установки приложений';    S = { Test-AppxEventLog } }
        @{ N = 'антивирус и Защитник';           S = { Test-Defender $info } }
        @{ N = 'прошлые обновления поверх';      S = { Test-PreviousUpgrade } }
    )
    if (-not $SkipScan) { $steps += @{ N = 'пробный поиск обновлений'; S = { Test-WUSearch } } }

    $all = New-Object Collections.ArrayList
    $i = 0
    foreach ($st in $steps) {
        $i++
        Set-UiStatus ('Диагностика (' + $i + ' из ' + $steps.Count + '): ' + $st.N)
        Set-UiProgress ([int](100 * ($i - 1) / $steps.Count))
        if (-not $Quiet) { Write-Log ('Проверка: ' + $st.N) 'INFO' }
        try {
            $res = @(& $st.S) | Where-Object { $_ -and $_.PSObject.Properties['Severity'] -and $_.PSObject.Properties['Fix'] }
            foreach ($x in $res) { [void]$all.Add($x) }
        } catch {
            Write-Log ('Проверка «' + $st.N + '» не выполнена: ' + $_.Exception.Message) 'WARN'
        }
    }
    Set-UiProgress 100
    $script:LastFindings = @($all)
    if ($Sync) { $Sync.Findings = $script:LastFindings }
    $err = @($all | Where-Object { $_.Severity -eq 'ERROR' }).Count
    $warn = @($all | Where-Object { $_.Severity -eq 'WARN' }).Count
    $fixes = @(Get-RecommendedFixes $all)
    Write-Log ('Итог диагностики: ошибок — ' + $err + ', предупреждений — ' + $warn) 'STEP'
    if ($fixes.Count -gt 0) { Write-Log ('Рекомендуется: ' + (Format-FixList $fixes)) 'INFO' }
    Set-UiStatus ('Диагностика завершена: ошибок — ' + $err + ', предупреждений — ' + $warn)
    return [pscustomobject]@{ Errors = $err; Warnings = $warn; Fixes = $fixes; Findings = @($all); Info = $info }
}
