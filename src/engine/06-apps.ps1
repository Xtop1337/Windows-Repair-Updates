# =====================================================================
#  WURepair — установка обновлений, Microsoft Store, Защитник, Claude
# =====================================================================

# ---------------------------------------------------------------------
#  Поиск и установка обновлений через Windows Update Agent (COM)
# ---------------------------------------------------------------------
function Get-UpdateKbs {
    param($Update)
    return @(@($Update.KBArticleIDs) | ForEach-Object { 'KB' + $_ })
}

function Invoke-WindowsUpdateInstall {
    Write-Log '=============== ПОИСК И УСТАНОВКА ОБНОВЛЕНИЙ ===============' 'STEP'
    $summary = [pscustomobject]@{ Ok = $false; Code = $null; Found = 0; Installed = 0; Failed = 0; Reboot = $false }
    foreach ($s in @('CryptSvc', 'BITS', 'wuauserv')) { [void](Start-ServiceSafe $s) }
    Set-UiStatus 'Поиск обновлений… (обычно 1–10 минут)'
    Set-UiProgress -1
    Write-Log 'Ищу обновления на серверах Microsoft…' 'INFO'
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'WURepair'
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    } catch {
        $code = Get-HResultFromError $_
        $info = Get-ErrorInfo $code
        $summary.Code = $code
        Write-Log ('Поиск обновлений не удался: ' + $code + ' — ' + $info.Text) 'ERROR'
        Write-Log ('Что поможет: ' + (Format-FixList $info.Fix) + '. Нажмите «Исправить всё автоматически».') 'WARN'
        return $summary
    }
    $all = @()
    foreach ($u in $result.Updates) { $all += $u }
    $optional = @()
    try {
        $opt = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software' and DeploymentAction='OptionalInstallation'")
        foreach ($u in $opt.Updates) {
            if ([string]$u.Title -match '(?i)22H2|Feature update|Обновление функций') { $optional += $u }
        }
    } catch { }
    $summary.Ok = $true
    $todo = @()
    foreach ($u in $all) {
        if ((Get-UpdateKbs $u) -contains 'KB5034441') {
            Write-Log 'Обновление KB5034441 пропускаю: оно известно ошибкой 0x80070643 и не нужно для работы программ. Скрываю его.' 'INFO'
            try { $u.IsHidden = $true } catch { }
            continue
        }
        $todo += $u
    }
    if ($optional.Count -gt 0) {
        $t = $optional[0].Title
        if (Request-UserConfirm ('Доступно обновление версии Windows:' + "`r`n" + $t + "`r`n`r`nДобавить его к установке? (Рекомендуется — после него Claude Desktop и новые программы будут работать без проблем.)") 'Обновление Windows') {
            $todo += $optional[0]
        }
    }
    $summary.Found = $todo.Count
    if ($todo.Count -eq 0) {
        Write-Log 'Новых обновлений нет — всё установлено.' 'OK'
        return $summary
    }
    $totalMB = 0
    $titles = @()
    foreach ($u in $todo) {
        $mb = [math]::Round([double]$u.MaxDownloadSize / 1MB, 0)
        $totalMB += $mb
        $titles += ('• ' + $u.Title + ' (~' + $mb + ' МБ)')
        Write-Log ('Найдено: ' + $u.Title + ' (~' + $mb + ' МБ)') 'INFO'
    }
    $list = ($titles | Select-Object -First 12) -join "`r`n"
    if ($titles.Count -gt 12) { $list += "`r`n… и ещё " + ($titles.Count - 12) }
    if (-not (Request-UserConfirm ('Найдено обновлений: ' + $todo.Count + ' (до ' + $totalMB + ' МБ).' + "`r`n`r`n" + $list + "`r`n`r`nСкачать и установить их сейчас?") 'Обновления Windows')) {
        Write-Log 'Установка отменена.' 'INFO'
        return $summary
    }
    foreach ($u in $todo) { if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } } }

    $downloaded = @()
    $i = 0
    foreach ($u in $todo) {
        $i++
        if ($u.IsDownloaded) { $downloaded += $u; continue }
        Set-UiStatus ('Загрузка (' + $i + ' из ' + $todo.Count + '): ' + $u.Title)
        Set-UiProgress ([int](100 * ($i - 1) / $todo.Count))
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$coll.Add($u)
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $coll
        try {
            $dr = $dl.Download()
            if ($dr.ResultCode -eq 2 -or $dr.ResultCode -eq 3) { $downloaded += $u; Write-Log ('Скачано: ' + $u.Title) 'OK' }
            else {
                $h = Format-HResult $dr.HResult
                Write-Log ('Не скачалось: ' + $u.Title + ' (' + $h + ' — ' + (Get-ErrorInfo $h).Text + ')') 'ERROR'
                $summary.Failed++
            }
        } catch {
            $h = Get-HResultFromError $_
            Write-Log ('Не скачалось: ' + $u.Title + ' (' + $h + ' — ' + (Get-ErrorInfo $h).Text + ')') 'ERROR'
            $summary.Failed++
        }
    }
    if ($downloaded.Count -eq 0) {
        Write-Log 'Ничего не скачалось. Запустите «Исправить всё автоматически» и попробуйте снова.' 'ERROR'
        return $summary
    }
    Set-UiStatus ('Установка обновлений (' + $downloaded.Count + ')… Не выключайте компьютер.')
    Set-UiProgress -1
    Write-Log 'Устанавливаю скачанные обновления — это может занять от нескольких минут до часа…' 'STEP'
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $downloaded) { [void]$coll.Add($u) }
    $inst = $session.CreateUpdateInstaller()
    $inst.Updates = $coll
    try { $ir = $inst.Install() } catch {
        $h = Get-HResultFromError $_
        Write-Log ('Установка не удалась: ' + $h + ' — ' + (Get-ErrorInfo $h).Text) 'ERROR'
        $summary.Code = $h
        return $summary
    }
    for ($k = 0; $k -lt $coll.Count; $k++) {
        $ur = $ir.GetUpdateResult($k)
        $u = $coll.Item($k)
        if ($ur.ResultCode -eq 2 -or $ur.ResultCode -eq 3) {
            $summary.Installed++
            Write-Log ('Установлено: ' + $u.Title) 'OK'
        } else {
            $summary.Failed++
            $h = Format-HResult $ur.HResult
            Write-Log ('Не установилось: ' + $u.Title + ' (' + $h + ' — ' + (Get-ErrorInfo $h).Text + ')') 'ERROR'
        }
    }
    $summary.Reboot = [bool]$ir.RebootRequired
    Write-Log ('Итог: установлено ' + $summary.Installed + ', с ошибкой ' + $summary.Failed + '.') 'STEP'
    if ($summary.Reboot) {
        Write-Log 'Для завершения установки нужна перезагрузка.' 'WARN'
        if (Request-UserConfirm 'Для завершения установки обновлений нужна перезагрузка. Перезагрузить компьютер через 1 минуту? (Сохраните открытые документы.)' 'Перезагрузка') {
            [void](Invoke-Proc 'shutdown.exe' '/r /t 60 /c "WURepair: перезагрузка для завершения установки обновлений"' -TimeoutSec 15 -Quiet)
            Write-Log 'Компьютер перезагрузится через 1 минуту. После перезагрузки снова нажмите «Найти и установить обновления» — часть обновлений ставится по очереди.' 'INFO'
        }
    } elseif ($summary.Installed -gt 0) {
        Write-Log 'Готово. Нажмите «Найти и установить обновления» ещё раз — иногда новые обновления появляются только после предыдущих.' 'INFO'
    }
    return $summary
}

# ---------------------------------------------------------------------
#  Пакеты AppX/MSIX
# ---------------------------------------------------------------------
function Test-AppxInstalled {
    param([string]$Name, [switch]$AllUsers)
    try {
        if ($AllUsers) { return (@(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Stop).Count -gt 0) }
        return (@(Get-AppxPackage -Name $Name -ErrorAction Stop).Count -gt 0)
    } catch { return $false }
}

function Register-AppxManifest {
    param([string]$Manifest)
    try {
        Add-AppxPackage -DisableDevelopmentMode -Register $Manifest -ErrorAction Stop
        return $true
    } catch {
        $h = Get-HResultFromError $_
        Write-Log ('   не удалось зарегистрировать ' + (Split-Path (Split-Path $Manifest -Parent) -Leaf) + ': ' + $h + ' — ' + (Get-ErrorInfo $h).Text) 'DEBUG'
        Write-Log ('   подробно: ' + (Get-ErrorText $_)) 'DEBUG'
        return $false
    }
}

function Get-WindowsAppsCandidates {
    param([string]$Prefix)
    $wa = Join-Path $env:ProgramFiles 'WindowsApps'
    $arch = Get-ArchName
    try {
        return @(Get-ChildItem -LiteralPath $wa -Directory -Filter ($Prefix + '_*') -ErrorAction Stop |
            Where-Object { $_.Name -notmatch '~' -and ($_.Name -match ('_' + $arch + '__') -or $_.Name -match '_neutral__') } |
            Sort-Object Name -Descending)
    } catch { return @() }
}

function Register-AppxFromDisk {
    param([string]$Name)
    # 1) пакет установлен у другого пользователя / «подготовлен»
    try {
        foreach ($p in @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Stop)) {
            $man = Join-Path $p.InstallLocation 'AppxManifest.xml'
            if ((Test-Path -LiteralPath $man) -and (Register-AppxManifest $man)) { return $true }
        }
    } catch { }
    try {
        foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $Name })) {
            $man = [Environment]::ExpandEnvironmentVariables([string]$p.InstallLocation)
            if ($man -notlike '*.xml') { $man = Join-Path $man 'AppxManifest.xml' }
            if ((Test-Path -LiteralPath $man) -and (Register-AppxManifest $man)) { return $true }
        }
    } catch { }
    # 2) файлы остались в WindowsApps
    foreach ($d in (Get-WindowsAppsCandidates $Name)) {
        $man = Join-Path $d.FullName 'AppxManifest.xml'
        if ((Test-Path -LiteralPath $man) -and (Register-AppxManifest $man)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------
#  Microsoft Store
# ---------------------------------------------------------------------
function Remove-StorePolicies {
    foreach ($c in @($script:PolicyChecks | Where-Object { $_.Area -eq 'Store' -and $_.N -ne 'AllowAllTrustedApps' })) {
        if (-not (Test-RegValue $c.P $c.N)) { continue }
        $isBad = $false
        try { $isBad = [bool](& $c.Bad (Get-RegValue $c.P $c.N)) } catch { }
        if ($isBad) {
            [void](Backup-RegKey $c.P)
            if (Remove-RegValueForce $c.P $c.N) { Write-Log ('Снят запрет: ' + $c.T) 'OK' }
        }
    }
}

function Get-WingetPath {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    try {
        $p = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop | Sort-Object Version -Descending)[0]
        if ($p) {
            $exe = Join-Path $p.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    } catch { }
    return $null
}

function Install-AppInstallerFromGitHub {
    Write-Log 'Скачиваю «Установщик приложений» (winget) с официальной страницы Microsoft на GitHub…' 'STEP'
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'WURepair' } -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    } catch {
        Write-Log ('Не удалось получить сведения о выпуске winget: ' + $_.Exception.Message) 'ERROR'
        return $false
    }
    $bundle = @($rel.assets | Where-Object { $_.name -like '*.msixbundle' })[0]
    $deps = @($rel.assets | Where-Object { $_.name -like '*Dependencies*.zip' })[0]
    if (-not $bundle) { Write-Log 'В выпуске winget нет пакета .msixbundle.' 'ERROR'; return $false }
    Write-Log ('Версия winget: ' + $rel.tag_name) 'INFO'
    $dir = Join-Path $script:DownloadDir 'winget'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $arch = Get-ArchName
    if ($deps) {
        $zip = Join-Path $dir $deps.name
        if (Invoke-Download $deps.browser_download_url $zip 'зависимости winget') {
            $ex = Join-Path $dir 'deps'
            try {
                Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force -ErrorAction Stop
                $files = @(Get-ChildItem -LiteralPath $ex -Recurse -File -ErrorAction Stop |
                    Where-Object { $_.Extension -in @('.appx', '.msix') } |
                    Where-Object { $_.FullName -match ('\\' + $arch + '\\') -or $_.Name -match ('_' + $arch + '\.') })
                foreach ($f in $files) {
                    try {
                        Add-AppxPackage -Path $f.FullName -ErrorAction Stop
                        Write-Log ('Установлен компонент: ' + $f.Name) 'OK'
                    } catch {
                        $h = Get-HResultFromError $_
                        if ($h -in @('0x80073D06', '0x80073CFB')) { Write-Log ('Компонент уже есть: ' + $f.Name) 'INFO' }
                        else {
                            Write-Log ('Компонент ' + $f.Name + ': ' + $h + ' — ' + (Get-ErrorInfo $h).Text) 'WARN'
                            Write-Log ('   подробно: ' + (Get-ErrorText $_)) 'DEBUG'
                        }
                    }
                }
            } catch { Write-Log ('Не удалось распаковать зависимости: ' + $_.Exception.Message) 'WARN' }
        }
    }
    $bf = Join-Path $dir $bundle.name
    if (-not (Invoke-Download $bundle.browser_download_url $bf 'Установщик приложений')) { return $false }
    try {
        Add-AppxPackage -Path $bf -ErrorAction Stop
        Write-Log '«Установщик приложений» (winget) установлен.' 'OK'
    } catch {
        $h = Get-HResultFromError $_
        if ($h -notin @('0x80073D06', '0x80073CFB')) {
            Write-Log ('Не удалось установить «Установщик приложений»: ' + $h + ' — ' + (Get-ErrorInfo $h).Text) 'ERROR'
            Write-Log ('   подробно: ' + (Get-ErrorText $_)) 'INFO'
            return $false
        }
        Write-Log '«Установщик приложений» уже установлен.' 'OK'
    }
    return $true
}

function Restore-MicrosoftStore {
    Write-Log '=============== ВОССТАНОВЛЕНИЕ MICROSOFT STORE ===============' 'STEP'
    $info = $script:LastSysInfo
    if (-not $info) { $info = Get-SystemInfo }
    if ($info.IsLTSC) { Write-Log 'В выпуске LTSC Магазина изначально нет — попробую добавить его официальным способом (winget).' 'INFO' }
    Set-UiStatus 'Microsoft Store: подготовка…'
    [void](Repair-Services -Groups @('Store'))
    Remove-StorePolicies
    if ((Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx' 'AllowAllTrustedApps') -eq 0 -or ($info.Build -lt 19041)) { [void](Repair-Sideload) }

    if (Test-AppxInstalled 'Microsoft.WindowsStore') {
        Write-Log 'Microsoft Store установлен. Перерегистрирую его и сбрасываю кэш…' 'INFO'
        [void](Register-AppxFromDisk 'Microsoft.WindowsStore')
        [void](Invoke-Proc 'wsreset.exe' '' -TimeoutSec 60 -Quiet)
        Get-Process -Name WinStore.App -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Log 'Магазин перерегистрирован. Если он открылся пустым — просто закройте окно.' 'OK'
        return $true
    }

    Write-Log 'Шаг 1 из 3: ищу файлы Магазина, оставшиеся на диске…' 'STEP'
    foreach ($dep in @('Microsoft.VCLibs.140.00', 'Microsoft.VCLibs.140.00.UWPDesktop', 'Microsoft.NET.Native.Framework.2.2', 'Microsoft.NET.Native.Runtime.2.2', 'Microsoft.UI.Xaml.2.7', 'Microsoft.UI.Xaml.2.8')) {
        if (-not (Test-AppxInstalled $dep)) { [void](Register-AppxFromDisk $dep) }
    }
    foreach ($n in @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller')) {
        if (-not (Test-AppxInstalled $n)) {
            if (Register-AppxFromDisk $n) { Write-Log ('Восстановлено из файлов на диске: ' + $n) 'OK' }
        }
    }
    if (Test-AppxInstalled 'Microsoft.WindowsStore') {
        Write-Log 'Microsoft Store восстановлен из файлов на диске.' 'OK'
        return $true
    }

    Write-Log 'Шаг 2 из 3: встроенная переустановка Магазина (wsreset -i)…' 'STEP'
    [void](Invoke-Proc 'wsreset.exe' '-i' -TimeoutSec 60 -Quiet)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 150) {
        if (Test-AppxInstalled 'Microsoft.WindowsStore') { break }
        Set-UiStatus ('Ожидание установки Магазина… ' + [int]$sw.Elapsed.TotalSeconds + ' с')
        Start-Sleep -Seconds 5
    }
    if (Test-AppxInstalled 'Microsoft.WindowsStore') {
        Write-Log 'Microsoft Store установлен (wsreset -i).' 'OK'
        return $true
    }
    Write-Log 'Встроенная переустановка в этой версии Windows не сработала.' 'INFO'

    Write-Log 'Шаг 3 из 3: установка через официальный «Установщик приложений» (winget)…' 'STEP'
    $wg = Get-WingetPath
    if (-not $wg) {
        if (-not (Install-AppInstallerFromGitHub)) {
            Write-Log 'Не удалось установить winget — Магазин этим способом не восстановить.' 'ERROR'
            Write-Log 'Надёжный способ вернуть Магазин — «Обновить Windows поверх» (возвращает все встроенные приложения).' 'WARN'
            return $false
        }
        Start-Sleep -Seconds 5
        $wg = Get-WingetPath
    }
    if (-not $wg) {
        Write-Log 'winget установлен, но пока недоступен. Выйдите из Windows, войдите снова и повторите «Вернуть Microsoft Store».' 'WARN'
        return $false
    }
    Set-UiStatus 'Установка Microsoft Store через winget… (до 15 минут)'
    $r = Invoke-Proc $wg 'install --id 9WZDNCRFJBMP --source msstore --accept-package-agreements --accept-source-agreements --silent' -TimeoutSec 900 -LiveLog -Encoding utf8
    Start-Sleep -Seconds 3
    if (Test-AppxInstalled 'Microsoft.WindowsStore') {
        Write-Log 'Microsoft Store установлен!' 'OK'
        return $true
    }
    Write-Log ('winget не смог установить Магазин (код ' + (Format-HResult $r.ExitCode) + ').') 'ERROR'
    Write-Log 'Надёжный способ вернуть Магазин — «Обновить Windows поверх» (возвращает все встроенные приложения). Claude Desktop можно установить и без Магазина.' 'WARN'
    return $false
}

# ---------------------------------------------------------------------
#  Защитник Windows
# ---------------------------------------------------------------------
function Repair-Defender {
    param([switch]$Light)
    Write-Log 'Восстанавливаю Защитник Windows…' 'STEP'
    $info = $script:LastSysInfo
    if (-not $info) { $info = Get-SystemInfo }
    $third = @($info.Antivirus | Where-Object { -not $_.IsDefender -and $_.Enabled })
    $ok = $true
    foreach ($c in @($script:PolicyChecks | Where-Object { $_.Area -eq 'Defender' })) {
        if (-not (Test-RegValue $c.P $c.N)) { continue }
        $isBad = $false
        try { $isBad = [bool](& $c.Bad (Get-RegValue $c.P $c.N)) } catch { }
        if (-not $isBad) { continue }
        [void](Backup-RegKey $c.P)
        if (Remove-RegValueForce $c.P $c.N) { Write-Log ('Снят запрет: ' + $c.T) 'OK' } else { $ok = $false }
    }
    $files = (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Windows Defender\MsMpEng.exe'))
    if ($files) {
        foreach ($s in @($script:ServiceTable | Where-Object { $_.G -eq 'Defender' })) {
            if ($s.MinBuild -and $info.Build -lt $s.MinBuild) { continue }
            if (-not (Repair-ServiceEntry $s)) { $ok = $false }
        }
    } else {
        Write-Log 'Файлы Защитника удалены — полностью вернуть его можно только обновлением Windows поверх.' 'WARN'
        $ok = $false
    }
    if (-not (Test-AppxInstalled 'Microsoft.Windows.SecHealthUI') -and -not (Test-AppxInstalled 'Microsoft.SecHealthUI')) {
        $mans = @()
        try { $mans += @(Get-ChildItem -LiteralPath (Join-Path $env:windir 'SystemApps') -Directory -Filter '*SecHealthUI*' -ErrorAction Stop | ForEach-Object { Join-Path $_.FullName 'AppxManifest.xml' }) } catch { }
        foreach ($d in (Get-WindowsAppsCandidates 'Microsoft.SecHealthUI')) { $mans += (Join-Path $d.FullName 'AppxManifest.xml') }
        $reg = $false
        foreach ($m in $mans) {
            if ((Test-Path -LiteralPath $m) -and (Register-AppxManifest $m)) { $reg = $true; break }
        }
        if ($reg) { Write-Log 'Приложение «Безопасность Windows» восстановлено.' 'OK' }
        else { Write-Log 'Файлы приложения «Безопасность Windows» удалены — вернёт обновление Windows поверх.' 'WARN' }
    }
    if ($third.Count -gt 0) {
        Write-Log ('Работает ' + (($third | ForEach-Object { $_.Name }) -join ', ') + ' — Защитник останется выключенным, пока он установлен. Это нормально.') 'INFO'
    } elseif ($files -and -not $Light) {
        [void](Start-ServiceSafe 'WinDefend')
        $mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
        if (Test-Path -LiteralPath $mp) {
            Write-Log 'Обновляю антивирусные базы Защитника…' 'INFO'
            [void](Invoke-Proc $mp '-SignatureUpdate' -TimeoutSec 600 -Quiet)
        }
    }
    if ($ok) { Write-Log 'Защитник: запреты сняты, службы восстановлены. Может понадобиться перезагрузка.' 'OK' }
    return $ok
}

# ---------------------------------------------------------------------
#  Claude Desktop
#  Требования (официальная документация Anthropic): Windows 10 2004
#  (сборка 19041) или новее, x64/ARM64, не в режиме S. Формат — MSIX.
# ---------------------------------------------------------------------
$script:ClaudeMsixUrl = 'https://claude.ai/api/desktop/win32/{0}/msix/latest/redirect'

function Get-ClaudeReadiness {
    $info = Get-SystemInfo
    $script:LastSysInfo = $info
    Send-UiEvent 'sysinfo' $info
    $r = [pscustomobject]@{ Info = $info; Blockers = @(); Fixes = @(); Installed = $null; VmpEnabled = $null }
    if ($info.Build -lt $script:ClaudeMinBuild) {
        $r.Blockers += ('Версия Windows слишком старая: ' + $info.Version + ' (сборка ' + $info.Build + '). Claude Desktop требует Windows 10 версии 2004 (сборка 19041) или новее. Сначала нажмите «Обновить Windows поверх» (до 22H2).')
        [void](New-Finding 'cl-build' 'ERROR' 'Claude' ('Нужна Windows 10 2004+ (сейчас ' + $info.Version + ', сборка ' + $info.Build + ')') 'Обновите Windows кнопкой «Обновить Windows поверх» — файлы и программы сохранятся.' @('InPlace'))
    } else {
        [void](New-Finding 'cl-build' 'OK' 'Claude' ('Версия Windows подходит: ' + $info.Version + ' (сборка ' + $info.Build + ')') '')
    }
    if ($info.Arch -eq 'x86') {
        $r.Blockers += 'Claude Desktop работает только на 64-разрядной Windows (x64 или ARM64).'
        [void](New-Finding 'cl-arch' 'ERROR' 'Claude' '32-разрядная Windows не поддерживается' 'Нужна 64-разрядная Windows.')
    }
    if ($info.SMode) {
        $r.Blockers += 'Windows в режиме S: сначала выйдите из режима S (бесплатно, через Microsoft Store).'
        [void](New-Finding 'cl-smode' 'ERROR' 'Claude' 'Windows в режиме S' 'В режиме S нельзя ставить программы не из Магазина.')
    }
    try {
        $pk = @(Get-AppxPackage -AllUsers -Name 'Claude' -ErrorAction Stop)
        if ($pk.Count -gt 0) { $r.Installed = $pk[0] }
    } catch {
        $r.Fixes += 'Services'
        [void](New-Finding 'cl-appx' 'ERROR' 'Claude' 'Не работает система установки приложений MSIX' $_.Exception.Message @('Services'))
    }
    foreach ($s in @($script:ServiceTable | Where-Object { $_.G -eq 'Store' -and $_.Crit })) {
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.N
        if (-not (Test-Path -LiteralPath $k)) {
            $r.Blockers += ('Удалена служба «' + $s.R + '» — без неё приложения MSIX не ставятся. Поможет «Обновить Windows поверх».')
            [void](New-Finding ('cl-svc-' + $s.N) 'ERROR' 'Claude' ('Удалена служба: ' + $s.R) 'Поможет «Обновить Windows поверх».' @('InPlace'))
        } elseif ((Get-RegValue $k 'Start') -eq 4) {
            if ($r.Fixes -notcontains 'Services') { $r.Fixes += 'Services' }
            [void](New-Finding ('cl-svc-' + $s.N) 'WARN' 'Claude' ('Отключена служба: ' + $s.R) 'Будет включена автоматически.' @('Services'))
        }
    }
    $unlock = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowAllTrustedApps'
    $pol = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx' 'AllowAllTrustedApps'
    if ($pol -eq 0 -or $unlock -eq 0 -or ($info.Build -lt 19041 -and $unlock -ne 1)) {
        $r.Fixes += 'Sideload'
        [void](New-Finding 'cl-sideload' 'WARN' 'Claude' 'Установка доверенных приложений не из Магазина запрещена' 'Будет разрешена автоматически (иначе ошибка 0x80073CFF).' @('Sideload'))
    } else {
        [void](New-Finding 'cl-sideload' 'OK' 'Claude' 'Установка доверенных приложений разрешена' '')
    }
    $free = Get-FreeSpaceGB ($env:LOCALAPPDATA.Substring(0, 2))
    if ($null -ne $free -and $free -lt 5) {
        $r.Blockers += ('Мало места: свободно ' + $free + ' ГБ. Нужно хотя бы 5 ГБ (для режима Cowork — около 20 ГБ).')
        [void](New-Finding 'cl-disk' 'ERROR' 'Claude' ('Мало места: ' + $free + ' ГБ') 'Освободите место на диске.' @('Disk'))
    } elseif ($null -ne $free -and $free -lt 20) {
        [void](New-Finding 'cl-disk' 'INFO' 'Claude' ('Свободно ' + $free + ' ГБ') 'Для обычного чата хватит; для режима Cowork нужно около 20 ГБ.')
    }
    if ($info.RamGB -and $info.RamGB -lt 8) {
        [void](New-Finding 'cl-ram' 'INFO' 'Claude' ('Оперативной памяти ' + $info.RamGB + ' ГБ') 'Чат будет работать; для режима Cowork рекомендуется 8 ГБ и больше.')
    }
    try {
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
        $r.VmpEnabled = ([string]$vmp.State -eq 'Enabled')
        if (-not $r.VmpEnabled) {
            [void](New-Finding 'cl-vmp' 'INFO' 'Claude' 'Компонент «Платформа виртуальной машины» выключен' 'Он нужен только для режима Cowork. Программа предложит включить его после установки.')
        }
    } catch { }
    $net = Test-TcpEndpoint 'claude.ai' 443
    if (-not $net.Ok) {
        $r.Blockers += ('Сайт claude.ai недоступен: ' + $net.Error)
        [void](New-Finding 'cl-net' 'ERROR' 'Claude' 'Сайт claude.ai недоступен' $net.Error @('Hosts', 'Network'))
    }
    if ($r.Installed) {
        [void](New-Finding 'cl-installed' 'OK' 'Claude' ('Claude Desktop уже установлен (версия ' + $r.Installed.Version + ')') '')
    }
    return $r
}

function Start-ClaudeApp {
    try {
        $pkg = @(Get-AppxPackage -Name 'Claude' -ErrorAction Stop)[0]
        if (-not $pkg) { return $false }
        $appId = 'Claude'
        try {
            $man = Get-AppxPackageManifest -Package $pkg.PackageFullName -ErrorAction Stop
            $ids = @($man.Package.Applications.Application | ForEach-Object { $_.Id })
            if ($ids.Count -gt 0 -and $ids[0]) { $appId = $ids[0] }
        } catch { }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $pkg.PackageFamilyName + '!' + $appId)
        Write-Log 'Claude Desktop запущен.' 'OK'
        return $true
    } catch { return $false }
}

# Остатки прошлой неудачной установки Claude (ошибка 0x80073CF6)
function Remove-ClaudeRemnants {
    $n = 0
    try {
        foreach ($p in @(Get-AppxPackage -AllUsers -Name 'Claude' -ErrorAction Stop)) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $n++ } catch {
                try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $n++ } catch { Write-Log ('   не удалось удалить ' + $p.PackageFullName + ': ' + (Get-ErrorText $_)) 'DEBUG' }
            }
        }
    } catch { }
    try {
        foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq 'Claude' })) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null; $n++ } catch { }
        }
    } catch { }
    if ($n -gt 0) { Write-Log ('Удалены остатки прошлой установки Claude (' + $n + ').') 'OK' }
    return $n
}

function Install-ClaudePackage {
    param([string]$File)
    $sideloadTried = $false
    $servicesTried = $false
    $cleanupTried = $false
    $provisioned = $false
    for ($attempt = 1; $attempt -le 3 -and -not $provisioned; $attempt++) {
        try {
            Write-Log 'Устанавливаю Claude для всех пользователей компьютера…' 'INFO'
            Add-AppxProvisionedPackage -Online -PackagePath $File -SkipLicense -ErrorAction Stop | Out-Null
            Write-Log 'Пакет Claude установлен в систему.' 'OK'
            $provisioned = $true
        } catch {
            $code = Get-HResultFromError $_
            $info = Get-ErrorInfo $code
            Write-Log ('Ошибка установки: ' + $code + ' — ' + $info.Text) 'ERROR'
            Write-Log ('   подробно: ' + (Get-ErrorText $_ 600)) 'INFO'
            if ($code -in @('0x80073CFF', '0x80073D00', '0x80073D01') -and -not $sideloadTried) { $sideloadTried = $true; [void](Repair-Sideload); continue }
            if ($code -in @('0x80073CF6', '0x80073CF3', '0x80073D05') -and -not $cleanupTried) {
                $cleanupTried = $true
                $q = 'Установке мешают остатки прошлой неудачной установки Claude.' + "`r`n`r`n" +
                     'Удалить их и попробовать ещё раз? (Если Claude раньше запускался, его настройки и вход в аккаунт сбросятся.)'
                if (Request-UserConfirm $q 'Claude Desktop') {
                    [void](Remove-ClaudeRemnants)
                    continue
                }
            }
            if ($code -in @('0x80073D0A', '0x80073CF9', '0x800706BA') -and -not $servicesTried) { $servicesTried = $true; [void](Repair-Services -Groups @('Store')); continue }
            if ($code -eq '0x80073CFB') { Write-Log 'Эта версия Claude уже установлена.' 'OK'; $provisioned = $true; break }
            if ($code -eq '0x80073CF6') { Write-Log 'Перезагрузите компьютер и снова нажмите «Установить Claude Desktop».' 'WARN'; return $false }
            if ($code -eq '0x80073D02') { Write-Log 'Закройте Claude (☰ → File → Exit) и повторите.' 'WARN'; return $false }
            break
        }
    }
    if (-not (Test-AppxInstalled 'Claude')) {
        try {
            Add-AppxPackage -Path $File -ErrorAction Stop
            Write-Log 'Claude зарегистрирован для вашей учётной записи.' 'OK'
        } catch {
            $code = Get-HResultFromError $_
            if ($code -notin @('0x80073CFB', '0x80073D06')) {
                Write-Log ('Регистрация для пользователя: ' + $code + ' — ' + (Get-ErrorInfo $code).Text) 'WARN'
            }
        }
    }
    if (Test-AppxInstalled 'Claude') { return $true }
    if ($provisioned) {
        Write-Log 'Claude установлен в систему и появится в меню «Пуск» после выхода из Windows и повторного входа.' 'WARN'
        return $true
    }
    Write-Log 'Установить Claude не удалось. Нажмите «Сохранить отчёт» — в нём будут все коды ошибок.' 'ERROR'
    return $false
}

function Install-ClaudeDesktop {
    Write-Log '=============== CLAUDE DESKTOP ===============' 'STEP'
    Send-UiEvent 'clearfindings' $null
    Set-UiStatus 'Claude Desktop: проверка готовности системы…'
    $r = Get-ClaudeReadiness
    if ($r.Blockers.Count -gt 0) {
        foreach ($b in $r.Blockers) { Write-Log $b 'ERROR' }
        Show-UiMessage ("Пока установить Claude Desktop нельзя:`r`n`r`n• " + ($r.Blockers -join "`r`n• ")) 'Claude Desktop' 'warn'
        return $false
    }
    if ($r.Fixes -contains 'Services') { [void](Repair-Services -Groups @('Store')) }
    if ($r.Fixes -contains 'Sideload') { [void](Repair-Sideload) }
    if ($r.Installed) {
        if (-not (Request-UserConfirm ('Claude Desktop уже установлен (версия ' + $r.Installed.Version + '). Скачать и установить последнюю версию поверх?' + "`r`n`r`n«Нет» — просто запустить Claude.") 'Claude Desktop')) {
            [void](Start-ClaudeApp)
            return $true
        }
    } elseif (-not (Request-UserConfirm 'Система готова. Скачать официальный пакет Claude Desktop с сайта claude.ai и установить его?' 'Claude Desktop')) {
        return $false
    }
    Initialize-AppDirs
    $arch = Get-ArchName
    $file = Join-Path $script:DownloadDir 'Claude.msix'
    if (-not (Invoke-Download ($script:ClaudeMsixUrl -f $arch) $file 'Claude Desktop')) { return $false }
    try {
        $fs = [IO.File]::OpenRead($file)
        $head = New-Object byte[] 2
        [void]$fs.Read($head, 0, 2)
        $fs.Dispose()
        if ($head[0] -ne 0x50 -or $head[1] -ne 0x4B) {
            Write-Log 'Скачанный файл — не пакет приложения (возможно, сайт вернул страницу с ошибкой). Попробуйте позже или из другой сети.' 'ERROR'
            return $false
        }
    } catch { }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Anthropic') {
            Write-Log ('Подпись пакета в порядке: ' + $sig.SignerCertificate.Subject) 'OK'
        } elseif ($sig.Status -in @('HashMismatch', 'NotSigned')) {
            Write-Log ('Подпись пакета недействительна (' + $sig.Status + ') — устанавливать не буду.') 'ERROR'
            return $false
        }
    } catch { }
    Set-UiStatus 'Установка Claude Desktop…'
    Set-UiProgress -1
    if (-not (Install-ClaudePackage $file)) { return $false }
    if ($r.VmpEnabled -eq $false) {
        if (Request-UserConfirm ('Claude установлен!' + "`r`n`r`n" + 'Для режима Cowork (Claude работает с файлами на компьютере) нужен компонент Windows «Платформа виртуальной машины». Включить его сейчас? Потребуется перезагрузка. Для обычного чата это не нужно.') 'Claude Desktop') {
            try {
                Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop | Out-Null
                Write-Log '«Платформа виртуальной машины» включена. Перезагрузите компьютер (именно «Перезагрузка», не «Завершение работы»).' 'OK'
                Write-Log 'Ещё для Cowork должна быть включена виртуализация процессора в BIOS/UEFI (Intel VT-x или AMD-V).' 'INFO'
            } catch { Write-Log ('Не удалось включить компонент: ' + $_.Exception.Message) 'WARN' }
        }
    }
    if (-not (Start-ClaudeApp)) { Write-Log 'Найдите Claude в меню «Пуск».' 'INFO' }
    Show-UiMessage 'Claude Desktop установлен. Найти его можно в меню «Пуск».' 'Claude Desktop' 'info'
    return $true
}
