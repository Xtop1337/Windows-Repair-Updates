# =====================================================================
#  WURepair — обновление поверх, отчёт, откат, диспетчер задач
# =====================================================================

$script:UpdateAssistantUrl = 'https://go.microsoft.com/fwlink/?LinkID=799445'
$script:Win10DownloadPage = 'https://www.microsoft.com/ru-ru/software-download/windows10'

function Get-UpgradeReadiness {
    $info = Get-SystemInfo
    $script:LastSysInfo = $info
    Send-UiEvent 'sysinfo' $info
    $r = [pscustomobject]@{ Info = $info; Blockers = @(); Notes = @() }
    if ($info.Build -ge 22000) { $r.Blockers += 'Это уже Windows 11 — обновление поверх до Windows 10 не нужно.' }
    if ($null -ne $info.FreeGB -and $info.FreeGB -lt 20) {
        $r.Blockers += ('На диске ' + $env:SystemDrive + ' свободно ' + $info.FreeGB + ' ГБ, а нужно около 20 ГБ. Освободите место (кнопка «Освободить место на диске»).')
    }
    if ($info.IsLTSC) {
        $r.Notes += ('У вас выпуск LTSC (' + $info.EditionID + '). «Помощник по обновлению» и обычный образ с сайта Microsoft не сохранят программы — нужен образ именно LTSC того же языка.')
    } elseif ($info.IsEnterprise) {
        $r.Notes += 'У вас выпуск Enterprise — нужен образ с выпуском Enterprise.'
    }
    if ($info.Arch -eq 'x86') { $r.Notes += 'Система 32-разрядная — образ тоже должен быть 32-разрядным (x86).' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $r.Notes += 'Windows ждёт перезагрузки — лучше перезагрузить компьютер перед обновлением.'
    }
    $third = @($info.Antivirus | Where-Object { -not $_.IsDefender })
    if ($third.Count -gt 0) {
        $r.Notes += ('Установлен антивирус ' + (($third | ForEach-Object { $_.Name }) -join ', ') + '. Он может прервать обновление — на время обновления отключите его (а лучше удалите и поставьте заново после).')
    }
    $r.Notes += ('Язык системы: ' + $info.Language + '. Образ должен быть на том же языке, иначе программы не сохранятся.')
    $r.Notes += 'Обновление поверх вернёт удалённые встроенные компоненты (Магазин, Защитник, службы) и обновит Windows до 22H2. Личные файлы и программы сохраняются. Займёт 30–90 минут и несколько перезагрузок.'
    $r.Notes += 'Активация Windows при этом не меняется.'
    return $r
}

function Start-UpdateAssistant {
    Write-Log '=============== ПОМОЩНИК ПО ОБНОВЛЕНИЮ WINDOWS 10 ===============' 'STEP'
    Initialize-AppDirs
    $file = Join-Path $script:DownloadDir 'Windows10Upgrade.exe'
    if (-not (Invoke-Download $script:UpdateAssistantUrl $file 'Помощник по обновлению Windows 10')) {
        Write-Log ('Если загрузка не работает, откройте страницу ' + $script:Win10DownloadPage + ' вручную (в некоторых странах Microsoft ограничивает загрузки — помогает другая сеть).') 'WARN'
        return $false
    }
    $sig = $null
    try { $sig = Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop } catch { }
    if (-not $sig -or $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
        Write-Log 'Подпись скачанного файла не подтверждена как Microsoft — запускать не буду.' 'ERROR'
        return $false
    }
    Write-Log ('Подпись Microsoft подтверждена: ' + $sig.SignerCertificate.Subject) 'OK'
    try {
        Start-Process -FilePath $file -ErrorAction Stop
        Write-Log 'Помощник по обновлению открыт. Нажмите в нём «Обновить сейчас» и следуйте подсказкам. Компьютер несколько раз перезагрузится.' 'OK'
        Show-UiMessage ('Открылся «Помощник по обновлению Windows 10».' + "`r`n`r`n" + 'Нажмите в нём «Обновить сейчас». Обновление займёт 30–90 минут, компьютер несколько раз перезагрузится. Файлы и программы сохранятся.' + "`r`n`r`n" + 'Если помощник выдаст ошибку — попробуйте вариант с ISO-образом.') 'Обновление поверх' 'info'
        return $true
    } catch {
        Write-Log ('Не удалось запустить помощник: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Get-ImageBuild {
    param([string]$Version)
    try { return ([version]$Version).Build } catch { return 0 }
}

function Start-UpgradeFromMedia {
    param([string]$Path)
    Write-Log '=============== ОБНОВЛЕНИЕ ПОВЕРХ С ОБРАЗА ===============' 'STEP'
    $info = Get-SystemInfo
    $script:LastSysInfo = $info
    $m = Mount-WindowsMedia $Path
    if ($m.Error) { Write-Log $m.Error 'ERROR'; Show-UiMessage $m.Error 'Обновление поверх' 'error'; return $false }
    if (-not $m.Setup) { Write-Log 'Не найден setup.exe в образе.' 'ERROR'; return $false }
    $problems = @()
    if ($m.Image) {
        Write-Log 'Читаю содержимое образа…' 'INFO'
        $imgs = @(Get-MediaImageInfo $m.Image)
        foreach ($i in $imgs) { Write-Log ('   [' + $i.Index + '] ' + $i.Name + ' — ' + $i.EditionId + ', ' + $i.Version + ', ' + ($i.Languages -join '/')) 'INFO' }
        if ($imgs.Count -gt 0) {
            $ed = @($imgs | Where-Object { $_.EditionId -eq $info.EditionID })
            if ($ed.Count -eq 0) {
                $problems += ('В образе нет вашего выпуска Windows (' + $info.EditionID + '). Программы и файлы сохранить не получится.')
            } else {
                $img = $ed[0]
                $b = Get-ImageBuild $img.Version
                if ($b -gt 0 -and $b -lt $info.Build) { $problems += ('Образ старее установленной системы (' + $img.Version + ' < ' + $info.Build + ').') }
                if ($img.Languages.Count -gt 0 -and $info.Language -and (@($img.Languages | Where-Object { $_ -ieq $info.Language }).Count -eq 0)) {
                    $problems += ('Язык образа (' + ($img.Languages -join ', ') + ') не совпадает с языком системы (' + $info.Language + '). Программы сохранить не получится.')
                }
                if ($img.Arch) {
                    $a = $img.Arch.Trim().ToLowerInvariant()
                    $want = $info.Arch
                    $mismatch = (($want -eq 'x64' -and $a -match '^(x86|0|arm64|12)$') -or
                                 ($want -eq 'x86' -and $a -match '^(x64|amd64|9|arm64|12)$') -or
                                 ($want -eq 'arm64' -and $a -match '^(x86|0|x64|amd64|9)$'))
                    if ($mismatch) {
                        $problems += ('Разрядность образа (' + $img.Arch + ') не совпадает с системой (' + $want + ').')
                    }
                }
            }
        }
    }
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Log $p 'ERROR' }
        Show-UiMessage ("Этот образ не подходит для обновления с сохранением программ:`r`n`r`n• " + ($problems -join "`r`n• ")) 'Обновление поверх' 'warn'
        return $false
    }
    $q = 'Начать обновление Windows поверх?' + "`r`n`r`n" +
         '• Файлы и программы сохранятся, удалённые компоненты вернутся.' + "`r`n" +
         '• Займёт 30–90 минут, компьютер несколько раз перезагрузится.' + "`r`n" +
         '• Не выключайте компьютер; ноутбук подключите к зарядке.' + "`r`n" +
         '• Сохраните открытые документы и закройте программы.' + "`r`n" +
         '• Сторонний антивирус лучше временно отключить.'
    if (-not (Request-UserConfirm $q 'Обновление поверх')) { return $false }
    [void](New-SafetyRestorePoint)
    try {
        Start-Process -FilePath $m.Setup -ArgumentList '/auto upgrade /dynamicupdate disable /eula accept /compat ignorewarning /showoobe none' -ErrorAction Stop
        Write-Log 'Программа установки Windows запущена. Дальше она работает сама.' 'OK'
        Write-Log ('Если обновление откатится, снова откройте WURepair и запустите диагностику — она покажет причину (журналы: ' + $env:SystemDrive + '\$WINDOWS.~BT\Sources\Panther).') 'INFO'
        return $true
    } catch {
        Write-Log ('Не удалось запустить setup.exe: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------
#  Отчёт
# ---------------------------------------------------------------------
function Export-Report {
    Initialize-AppDirs
    $info = $script:LastSysInfo
    if (-not $info) { $info = Get-SystemInfo }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('ОТЧЁТ WURepair ' + $script:AppVersion + ' — ' + (Get-Date -Format 'dd.MM.yyyy HH:mm'))
    [void]$sb.AppendLine('==========================================================')
    [void]$sb.AppendLine((Format-SystemInfo $info))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('НАЙДЕННЫЕ ПРОБЛЕМЫ')
    [void]$sb.AppendLine('----------------------------------------------------------')
    $order = @{ ERROR = 0; WARN = 1; INFO = 2; OK = 3 }
    $fs = @($script:LastFindings | Sort-Object @{ Expression = { $order[$_.Severity] } }, Category)
    if ($fs.Count -eq 0) { [void]$sb.AppendLine('(диагностика ещё не запускалась)') }
    foreach ($f in $fs) {
        [void]$sb.AppendLine(('[{0}] {1}: {2}' -f $f.Severity, $f.Category, $f.Title))
        if ($f.Detail) { foreach ($l in ($f.Detail -split "\r?\n")) { [void]$sb.AppendLine('      ' + $l) } }
        if ($f.Fix.Count -gt 0) { [void]$sb.AppendLine('      → ' + (Format-FixList $f.Fix)) }
    }
    if ($script:LastConnectivity) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('ДОСТУПНОСТЬ СЕРВЕРОВ')
        [void]$sb.AppendLine('----------------------------------------------------------')
        foreach ($c in $script:LastConnectivity) {
            $st = 'OK'
            if (-not $c.Ok) { $st = 'НЕТ: ' + $c.Error }
            [void]$sb.AppendLine(('{0}:{1} [{2}] — {3}' -f $c.Host, $c.Port, $c.Resolved, $st))
        }
    }
    if ($script:RepairSummary) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('ПОСЛЕДНИЙ РЕМОНТ')
        [void]$sb.AppendLine('----------------------------------------------------------')
        [void]$sb.AppendLine('Исправлено: ' + ($script:RepairSummary.Done -join ', '))
        [void]$sb.AppendLine('Не получилось: ' + ($script:RepairSummary.Failed -join ', '))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('ЖУРНАЛ (последние строки)')
    [void]$sb.AppendLine('----------------------------------------------------------')
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        foreach ($l in @(Get-Content -LiteralPath $script:LogFile -Encoding UTF8 -Tail 400)) { [void]$sb.AppendLine($l) }
    }
    $name = 'WURepair-отчёт-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm') + '.txt'
    $file = Join-Path $script:RootDir $name
    [IO.File]::WriteAllText($file, $sb.ToString(), (New-Object Text.UTF8Encoding $true))
    $desk = [Environment]::GetFolderPath('Desktop')
    if ($desk -and (Test-Path -LiteralPath $desk)) {
        try { Copy-Item -LiteralPath $file -Destination (Join-Path $desk $name) -Force; Write-Log ('Отчёт сохранён на Рабочий стол: ' + $name) 'OK' } catch { }
    }
    Write-Log ('Отчёт: ' + $file) 'OK'
    if (-not $env:WUREPAIR_NO_OPEN) {
        try { Start-Process -FilePath (Resolve-SystemExe 'notepad.exe') -ArgumentList ('"' + $file + '"') } catch { }
    }
    return $file
}

# ---------------------------------------------------------------------
#  Откат изменений
# ---------------------------------------------------------------------
function Get-BackupSessions {
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue).Count -gt 0 } |
        Sort-Object Name -Descending)
}

function Restore-FromBackup {
    param([string]$Dir)
    Write-Log '=============== ОТКАТ ИЗМЕНЕНИЙ ===============' 'STEP'
    if (-not $Dir) {
        $last = @(Get-BackupSessions)[0]
        if (-not $last) { Write-Log 'Резервных копий нет — откатывать нечего.' 'WARN'; return $false }
        $Dir = $last.FullName
    }
    if (-not (Test-Path -LiteralPath $Dir)) { Write-Log ('Папка не найдена: ' + $Dir) 'ERROR'; return $false }
    $files = @(Get-ChildItem -LiteralPath $Dir -File)
    $q = 'Вернуть настройки к состоянию до ремонта из копии «' + (Split-Path $Dir -Leaf) + '»?' + "`r`n`r`n" +
         'Будут восстановлены: ключи реестра (' + @($files | Where-Object { $_.Name -like 'reg_*.reg' }).Count + '), ' +
         'файлы (hosts и др.), правила брандмауэра, права служб.' + "`r`n`r`n" +
         'Внимание: вместе с этим вернутся и блокировки обновлений.' + "`r`n" +
         'Для полного отката системы можно также использовать точку восстановления Windows (rstrui).'
    if (-not (Request-UserConfirm $q 'Откат')) { return $false }
    $ok = $true
    foreach ($f in @($files | Where-Object { $_.Name -like 'reg_*.reg' })) {
        $r = Invoke-Proc 'reg.exe' ('import "' + $f.FullName + '"') -TimeoutSec 60 -Quiet
        if ($r.ExitCode -eq 0) { Write-Log ('Восстановлено: ' + $f.Name) 'OK' }
        else {
            $res = Invoke-AsSystem ('reg import "' + $f.FullName + '"')
            if ($res -eq 0) { Write-Log ('Восстановлено (SYSTEM): ' + $f.Name) 'OK' } else { $ok = $false; Write-Log ('Не удалось восстановить ' + $f.Name) 'WARN' }
        }
    }
    foreach ($meta in @($files | Where-Object { $_.Name -like 'file_*.path' })) {
        $target = ([IO.File]::ReadAllText($meta.FullName, [Text.Encoding]::UTF8)).Trim()
        $src = $meta.FullName.Substring(0, $meta.FullName.Length - 5)
        if (-not (Test-Path -LiteralPath $src) -or -not $target) { continue }
        try {
            if (Test-Path -LiteralPath $target) {
                $it = Get-Item -LiteralPath $target -Force
                $it.Attributes = $it.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
            }
            Copy-Item -LiteralPath $src -Destination $target -Force -ErrorAction Stop
            Write-Log ('Восстановлен файл: ' + $target) 'OK'
        } catch { $ok = $false; Write-Log ('Не удалось восстановить ' + $target + ': ' + $_.Exception.Message) 'WARN' }
    }
    $wfw = Join-Path $Dir 'firewall.wfw'
    if (Test-Path -LiteralPath $wfw) {
        $r = Invoke-Proc 'netsh.exe' ('advfirewall import "' + $wfw + '"') -TimeoutSec 60 -Quiet
        if ($r.ExitCode -eq 0) { Write-Log 'Правила брандмауэра восстановлены.' 'OK' } else { $ok = $false; Write-Log 'Не удалось восстановить правила брандмауэра.' 'WARN' }
    }
    foreach ($sd in @($files | Where-Object { $_.Name -like 'sd_*.txt' })) {
        $svc = $sd.BaseName.Substring(3)
        $val = ([IO.File]::ReadAllText($sd.FullName, [Text.Encoding]::UTF8)).Trim()
        if ($val) {
            $r = Invoke-Proc 'sc.exe' ('sdset ' + $svc + ' ' + $val) -TimeoutSec 30 -Quiet
            if ($r.ExitCode -eq 0) { Write-Log ('Права службы ' + $svc + ' восстановлены.') 'OK' }
        }
    }
    [void](Invoke-Proc 'ipconfig.exe' '/flushdns' -TimeoutSec 30 -Quiet)
    Write-Log 'Откат завершён. Перезагрузите компьютер, чтобы все изменения вступили в силу.' 'STEP'
    return $ok
}

# ---------------------------------------------------------------------
#  Диспетчер фоновых задач (вызывается из окна программы)
# ---------------------------------------------------------------------
function Invoke-EngineTask {
    $name = [string]$Sync.TaskName
    $a = $Sync.TaskArgs
    Initialize-AppDirs
    $Sync.Result = $null
    try {
        switch ($name) {
            'Diagnose'         { $Sync.Result = Invoke-Diagnostics -SkipScan:([bool]$a.SkipScan) }
            'Repair'           { $Sync.Result = Invoke-AutoRepair }
            'Install'          { $Sync.Result = Invoke-WindowsUpdateInstall }
            'DeepRepair'       { [void](New-SafetyRestorePoint); $Sync.Result = Repair-ComponentStore }
            'Store'            { [void](New-SafetyRestorePoint); $Sync.Result = Restore-MicrosoftStore }
            'Defender'         { [void](New-SafetyRestorePoint); $Sync.Result = Repair-Defender }
            'Claude'           { $Sync.Result = Install-ClaudeDesktop }
            'UpgradeCheck'     { $Sync.Result = Get-UpgradeReadiness }
            'UpgradeAssistant' { $Sync.Result = Start-UpdateAssistant }
            'UpgradeMedia'     { $Sync.Result = Start-UpgradeFromMedia -Path ([string]$a.Path) }
            'Report'           { $Sync.Result = Export-Report }
            'Rollback'         { $Sync.Result = Restore-FromBackup -Dir ([string]$a.Path) }
            'Disk'             { $Sync.Result = Repair-DiskSpace }
            'SysInfo'          { $i = Get-SystemInfo; $script:LastSysInfo = $i; Send-UiEvent 'sysinfo' $i; $Sync.Result = $i }
            default            { Write-Log ('Неизвестная задача: ' + $name) 'ERROR' }
        }
    } catch {
        Write-Log ('Непредвиденная ошибка: ' + $_.Exception.Message) 'ERROR'
        try { Write-Log ($_.InvocationInfo.PositionMessage) 'DEBUG' } catch { }
    } finally {
        Send-UiEvent 'done' $name
    }
}
