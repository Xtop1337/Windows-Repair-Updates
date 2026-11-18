# =====================================================================
#  WURepair — исправления
#  Каждая функция Repair-* делает резервную копию того, что меняет,
#  пишет в журнал и возвращает $true/$false.
# =====================================================================

function Get-ScStartMode {
    param([int]$Start, [bool]$Delayed)
    switch ($Start) {
        2 { if ($Delayed) { return 'delayed-auto' } else { return 'auto' } }
        3 { return 'demand' }
        4 { return 'disabled' }
        default { return 'demand' }
    }
}

function Set-ServiceStartType {
    param([string]$Name, [int]$Start, [bool]$Delayed)
    $r = Invoke-Proc 'sc.exe' ('config ' + $Name + ' start= ' + (Get-ScStartMode $Start $Delayed)) -TimeoutSec 30 -Quiet
    if ($r.ExitCode -eq 0) { return $true }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    $ok = Set-RegValueForce $key 'Start' $Start 'DWord'
    if ($ok -and $Start -eq 2) { [void](Set-RegValueForce $key 'DelayedAutostart' ([int]$Delayed) 'DWord') }
    return $ok
}

function Repair-ServiceEntry {
    param($Entry)
    $name = $Entry.N
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $name
    if (-not (Test-Path -LiteralPath $key)) {
        Write-Log ('Служба ' + $name + ' удалена из системы — вернуть её можно только обновлением Windows поверх.') 'WARN'
        return $false
    }
    $ok = $true
    $touched = $false
    $start = Get-RegValue $key 'Start'
    $obj = [string](Get-RegValue $key 'ObjectName')
    $img = [string](Get-RegValue $key 'ImagePath')
    $needAcc = ($Entry.A -and $obj -and ((ConvertTo-AccountKey $obj) -ne (ConvertTo-AccountKey $Entry.A)))
    $needImg = ($Entry.Img -and $Entry.Exe -and ((-not $img) -or ($img -notmatch [regex]::Escape($Entry.Exe))))
    $locked = Test-HklmKeyLocked ('SYSTEM\CurrentControlSet\Services\' + $name)
    if ($start -ne 4 -and -not $needAcc -and -not $needImg -and -not $locked) { return $true }
    if ($locked) {
        # Сначала снимаем блокировку прав, иначе ключ не изменить даже от имени SYSTEM
        if (-not (Unlock-ServiceKey $name)) { $ok = $false }
    }
    [void](Backup-RegKey $key ('svc_' + $name))

    if ($start -eq 4) {
        $touched = $true
        if (Set-ServiceStartType $name $Entry.S $Entry.D) {
            Write-Log ('Служба «' + $Entry.R + '» включена (' + (Get-StartTypeName $Entry.S $Entry.D) + ').') 'OK'
        } else { $ok = $false; Write-Log ('Не удалось включить службу ' + $name + '.') 'ERROR' }
    }
    if ($needAcc) {
        $touched = $true
        $acc = $Entry.A
        $scArgs = 'config ' + $name + ' obj= "' + $acc + '"'
        if ((ConvertTo-AccountKey $acc) -ne 'localsystem') { $scArgs += ' password= ""' }
        $r = Invoke-Proc 'sc.exe' $scArgs -TimeoutSec 30 -Quiet
        if ($r.ExitCode -eq 0 -or (Set-RegValueForce $key 'ObjectName' $acc 'String')) {
            Write-Log ('Служба ' + $name + ': восстановлена учётная запись ' + $acc + '.') 'OK'
        } else { $ok = $false }
    }
    if ($needImg) {
        $touched = $true
        if (Set-RegValueForce $key 'ImagePath' $Entry.Img 'ExpandString') {
            Write-Log ('Служба ' + $name + ': восстановлен путь к файлу службы.') 'OK'
        } else { $ok = $false }
    }
    if ($touched -and $Entry.S -eq 2) { [void](Start-ServiceSafe $name) }
    return $ok
}

function Repair-ServiceSecurity {
    $ok = $true
    foreach ($n in @('wuauserv', 'BITS', 'UsoSvc')) {
        if (-not (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $n))) { continue }
        $r = Invoke-Proc 'sc.exe' ('sdshow ' + $n) -TimeoutSec 20 -Quiet
        if ($r.Output -notmatch '\(D;') { continue }
        try { [IO.File]::WriteAllText((Join-Path (Get-SessionBackupDir) ('sd_' + $n + '.txt')), $r.Output.Trim(), [Text.Encoding]::UTF8) } catch { }
        $set = Invoke-Proc 'sc.exe' ('sdset ' + $n + ' ' + $script:DefaultServiceSD) -TimeoutSec 20 -Quiet
        if ($set.ExitCode -ne 0) {
            $res = Invoke-AsSystem ('sc sdset ' + $n + ' ' + $script:DefaultServiceSD)
            if ($res -ne 0) { $ok = $false; Write-Log ('Не удалось сбросить права службы ' + $n + '.') 'ERROR'; continue }
        }
        Write-Log ('Права службы ' + $n + ' сброшены к стандартным.') 'OK'
    }
    return $ok
}

function Repair-Services {
    param([string[]]$Groups = @('WU', 'Core', 'Store'))
    Write-Log 'Восстанавливаю службы…' 'STEP'
    $info = $script:LastSysInfo
    if (-not $info) { $info = Get-SystemInfo }
    $ok = $true
    foreach ($s in $script:ServiceTable) {
        if ($Groups -notcontains $s.G) { continue }
        if ($s.MinBuild -and $info.Build -lt $s.MinBuild) { continue }
        if (-not (Repair-ServiceEntry $s)) { $ok = $false }
    }
    if (-not (Repair-ServiceSecurity)) { $ok = $false }
    foreach ($n in @('CryptSvc', 'BITS', 'wuauserv')) { [void](Start-ServiceSafe $n) }
    if ($ok) { Write-Log 'Службы в порядке.' 'INFO' }
    return $ok
}

# ---------------------------------------------------------------------
# Разбор файла локальной групповой политики Registry.pol
# Формат: 'PReg' + версия (8 байт), затем записи [ключ;значение;тип;размер;данные]
# (строки — UTF-16LE с нулём в конце, разделители — символы UTF-16LE).
function Get-RegistryPolEntries {
    param([byte[]]$Bytes)
    $entries = @()
    if (-not $Bytes -or $Bytes.Length -lt 8) { return $entries }
    if ([Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'PReg') { throw 'Файл не похож на Registry.pol' }
    $n = $Bytes.Length
    $i = 8
    $readStr = {
        $sb = New-Object Text.StringBuilder
        while ($script:polPos + 1 -lt $n) {
            $ch = [BitConverter]::ToChar($Bytes, $script:polPos)
            $script:polPos += 2
            if ($ch -eq [char]0) { break }
            [void]$sb.Append($ch)
        }
        $sb.ToString()
    }
    $expect = {
        param([char]$c)
        if ($script:polPos + 1 -ge $n -or [BitConverter]::ToChar($Bytes, $script:polPos) -ne $c) { throw ("Повреждён Registry.pol (позиция " + $script:polPos + ")") }
        $script:polPos += 2
    }
    $script:polPos = $i
    while ($script:polPos + 1 -lt $n) {
        $start = $script:polPos
        & $expect '['
        $key = & $readStr
        & $expect ';'
        $val = & $readStr
        & $expect ';'
        $type = [BitConverter]::ToUInt32($Bytes, $script:polPos); $script:polPos += 4
        & $expect ';'
        $size = [BitConverter]::ToUInt32($Bytes, $script:polPos); $script:polPos += 4
        & $expect ';'
        $script:polPos += [int]$size
        & $expect ']'
        $entries += [pscustomobject]@{ Key = $key; Value = $val; Type = $type; Size = $size; Start = $start; End = $script:polPos }
    }
    return $entries
}

# Убирает из Registry.pol записи с указанными парами «ключ|значение»
# (сравнение без учёта регистра). Возвращает новые байты и число удалённых.
function Remove-RegistryPolEntries {
    param([byte[]]$Bytes, [string[]]$Pairs)
    $set = @{}
    foreach ($p in $Pairs) { $set[$p.ToLowerInvariant()] = $true }
    $entries = @(Get-RegistryPolEntries $Bytes)
    $out = New-Object IO.MemoryStream
    $out.Write($Bytes, 0, 8)
    $removed = 0
    foreach ($e in $entries) {
        $k = ($e.Key.TrimStart('\') + '|' + $e.Value).ToLowerInvariant()
        if ($set.ContainsKey($k)) { $removed++; continue }
        $out.Write($Bytes, $e.Start, $e.End - $e.Start)
    }
    return [pscustomobject]@{ Bytes = $out.ToArray(); Removed = $removed }
}

function Get-PolicyRelativeKey {
    param([string]$Path)
    return ($Path -replace '^(HKLM|HKCU):\\', '')
}

function Repair-Policies {
    Write-Log 'Убираю политики, запрещающие обновления…' 'STEP'
    $removed = 0
    $failed = 0
    $polPairs = @{ Machine = @(); User = @() }
    foreach ($c in $script:PolicyChecks) {
        if ($c.Area -eq 'Defender') { continue }
        if (-not (Test-RegValue $c.P $c.N)) { continue }
        $v = Get-RegValue $c.P $c.N
        $isBad = $false
        try { $isBad = [bool](& $c.Bad $v) } catch { }
        if (-not $isBad) { continue }
        [void](Backup-RegKey $c.P)
        $list = @($c.N)
        if ($script:PolicyCompanions.ContainsKey($c.N)) { $list += $script:PolicyCompanions[$c.N] }
        $scope = 'Machine'
        if ($c.P -like 'HKCU:*') { $scope = 'User' }
        foreach ($n in $list) {
            $polPairs[$scope] += ((Get-PolicyRelativeKey $c.P) + '|' + $n)
            if (-not (Test-RegValue $c.P $n)) { continue }
            if (Remove-RegValueForce $c.P $n) { $removed++; Write-Log ('Удалено: ' + (ConvertTo-NativeRegPath $c.P) + '\' + $n) 'OK' }
            else { $failed++ }
        }
        if ($c.N -eq 'WUServer') {
            $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
            $polPairs.Machine += ((Get-PolicyRelativeKey $au) + '|UseWUServer')
            if (Test-RegValue $au 'UseWUServer') { [void](Backup-RegKey $au); if (Remove-RegValueForce $au 'UseWUServer') { $removed++ } }
        }
    }
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $pauseNames = @($script:PauseValues + 'FlightSettingsMaxPauseDays')
    if (@($pauseNames | Where-Object { Test-RegValue $ux $_ }).Count -gt 0) {
        [void](Backup-RegKey $ux 'wu_ux_settings')
        foreach ($n in $pauseNames) {
            if (Test-RegValue $ux $n) { if (Remove-RegValue $ux $n) { $removed++ } else { $failed++ } }
        }
        Write-Log 'Пауза обновлений снята.' 'OK'
    }
    # Если запреты записаны в локальную групповую политику (gpedit), они вернутся
    # при следующем обновлении политик — убираем из неё ТОЛЬКО эти записи.
    foreach ($scope in @('Machine', 'User')) {
        if ($polPairs[$scope].Count -eq 0) { continue }
        $pol = Join-Path $env:windir ('System32\GroupPolicy\' + $scope + '\Registry.pol')
        if (-not (Test-Path -LiteralPath $pol)) { continue }
        try {
            $r = Remove-RegistryPolEntries -Bytes ([IO.File]::ReadAllBytes($pol)) -Pairs $polPairs[$scope]
            if ($r.Removed -gt 0) {
                if (-not (Backup-File $pol ('gpo_' + $scope + '_Registry.pol'))) { throw 'не удалось сохранить резервную копию' }
                [IO.File]::WriteAllBytes($pol, $r.Bytes)
                Write-Log ('Из локальной групповой политики (' + $scope + ') убрано запретов: ' + $r.Removed + '. Остальные политики не тронуты.') 'OK'
            }
        } catch {
            $failed++
            Write-Log ('Не удалось изменить локальную групповую политику ' + $pol + ': ' + $_.Exception.Message) 'WARN'
        }
    }
    if ($removed -eq 0 -and $failed -eq 0) { Write-Log 'Запрещающих политик не найдено.' 'INFO' }
    return ($failed -eq 0)
}

function Repair-Ifeo {
    Write-Log 'Снимаю блокировку запуска компонентов Windows (IFEO)…' 'STEP'
    $bases = @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options')
    if ([Environment]::Is64BitOperatingSystem) { $bases += 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' }
    $ok = $true
    foreach ($b in $bases) {
        foreach ($exe in $script:IfeoTargets) {
            $k = Join-Path $b $exe
            if (-not (Get-RegValue $k 'Debugger')) { continue }
            $tag = 'x64'
            if ($b -match 'WOW6432Node') { $tag = 'x86' }
            [void](Backup-RegKey $k ('ifeo_' + $tag + '_' + $exe))
            if (Remove-RegValueForce $k 'Debugger') { Write-Log ('Запуск ' + $exe + ' разблокирован.') 'OK' } else { $ok = $false }
        }
    }
    return $ok
}

function Repair-UpdateTasks {
    Write-Log 'Включаю задания обновления в планировщике…' 'STEP'
    $ok = $true
    foreach ($t in $script:UpdateTasks) {
        $task = Get-ScheduledTaskSafe $t
        if (-not $task -or [string]$task.State -ne 'Disabled') { continue }
        $done = $false
        try { Enable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null; $done = $true } catch { }
        if (-not $done) {
            $r = Invoke-Proc 'schtasks.exe' ('/Change /TN "' + $t + '" /Enable') -TimeoutSec 30 -Quiet
            $done = ($r.ExitCode -eq 0)
        }
        if (-not $done) { $done = ((Invoke-AsSystem ('schtasks /Change /TN "' + $t + '" /Enable')) -eq 0) }
        if ($done) { Write-Log ('Задание включено: ' + $t) 'OK' } else { $ok = $false; Write-Log ('Не удалось включить задание: ' + $t) 'WARN' }
    }
    return $ok
}

# ---------------------------------------------------------------------
function Get-RepairedHostsLines {
    param([string[]]$Lines)
    $bad = @(Get-HostsBlockEntries -Lines $Lines)
    $byIndex = @{}
    foreach ($b in $bad) { $byIndex[$b.Index] = $b }
    $out = New-Object Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($byIndex.ContainsKey($i)) {
            $b = $byIndex[$i]
            if ($b.Keep.Count -gt 0) { $out.Add($b.Ip + "`t" + ($b.Keep -join ' ')) }
            continue
        }
        $out.Add([string]$Lines[$i])
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
    return [pscustomobject]@{ Lines = @($out); Removed = $bad.Count }
}

function Repair-Hosts {
    Write-Log 'Очищаю файл hosts от блокировок серверов Microsoft…' 'STEP'
    $path = Get-HostsPath
    if (-not (Test-Path -LiteralPath $path)) { Write-Log 'Файла hosts нет — чистить нечего.' 'INFO'; return $true }
    $data = Read-TextFileSmart $path
    $fixed = Get-RepairedHostsLines -Lines $data.Lines
    if ($fixed.Removed -eq 0) { Write-Log 'Блокировок в hosts нет.' 'INFO'; return $true }
    if (-not (Backup-File $path 'hosts')) {
        Write-Log 'Не удалось сделать копию hosts — изменять его не буду.' 'ERROR'
        return $false
    }
    $content = (($fixed.Lines -join "`r`n") + "`r`n")
    $written = $false
    try {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
            Write-Log 'С файла hosts снят атрибут «только чтение».' 'INFO'
        }
        [IO.File]::WriteAllText($path, $content, $data.Encoding)
        $written = $true
    } catch {
        Write-Log ('Обычная запись hosts не удалась (' + $_.Exception.Message + ') — пробую от имени SYSTEM…') 'INFO'
    }
    if (-not $written) {
        $tmp = Join-Path $script:RootDir 'hosts.new'
        try { [IO.File]::WriteAllText($tmp, $content, $data.Encoding) } catch { }
        if ((Test-Path -LiteralPath $tmp) -and ((Invoke-AsSystem ('attrib -r -s -h "' + $path + '" & copy /y "' + $tmp + '" "' + $path + '"')) -eq 0)) {
            $written = $true
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    if (-not $written) {
        Write-Log 'Не удалось записать файл hosts.' 'ERROR'
        Write-Log 'Его защищает антивирус: в Kaspersky откройте «Настройки → Безопасность → Самозащита» и временно выключите её, затем повторите.' 'WARN'
        return $false
    }
    $left = @(Get-HostsBlockEntries -Lines (Read-TextFileSmart $path).Lines).Count
    if ($left -gt 0) {
        Write-Log ('Часть блокировок осталась (' + $left + ') — файл, вероятно, восстанавливает антивирус или другая программа.') 'WARN'
        return $false
    }
    [void](Invoke-Proc 'ipconfig.exe' '/flushdns' -TimeoutSec 30 -Quiet)
    Write-Log ('Из hosts удалено блокировок: ' + $fixed.Removed + '. Кэш DNS очищен.') 'OK'
    return $true
}

function Repair-Routes {
    Write-Log 'Удаляю «мёртвые» сетевые маршруты…' 'STEP'
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\PersistentRoutes'
    $bh = @(Get-BlackholeRoutes (Get-PersistentRouteNames))
    if ($bh.Count -eq 0) { Write-Log 'Таких маршрутов нет.' 'INFO'; return $true }
    [void](Backup-RegKey $k 'persistent_routes')
    $n = 0
    foreach ($r in $bh) {
        [void](Invoke-Proc 'route.exe' ('delete ' + $r.Destination + ' mask ' + $r.Mask + ' ' + $r.Gateway) -TimeoutSec 15 -Quiet)
        [void](Remove-RegValue $k $r.Name -Quiet)
        $n++
    }
    $left = @(Get-BlackholeRoutes (Get-PersistentRouteNames)).Count
    Write-Log ('Удалено маршрутов: ' + ($n - $left) + '.') 'OK'
    return ($left -eq 0)
}

function Repair-Firewall {
    Write-Log 'Выключаю правила брандмауэра, блокирующие обновления…' 'STEP'
    try { $sus = @(Get-SuspectFirewallRules) } catch {
        Write-Log ('Не удалось прочитать правила брандмауэра: ' + $_.Exception.Message) 'WARN'
        return $false
    }
    $ok = $true
    if ($sus.Count -gt 0) {
        $wfw = Join-Path (Get-SessionBackupDir) 'firewall.wfw'
        $exp = Invoke-Proc 'netsh.exe' ('advfirewall export "' + $wfw + '"') -TimeoutSec 60 -Quiet
        if ($exp.ExitCode -ne 0) { Write-Log 'Не удалось сохранить копию правил брандмауэра — продолжаю (правила только выключаются, не удаляются).' 'WARN' }
        foreach ($r in $sus) {
            try {
                Disable-NetFirewallRule -Name $r.Name -ErrorAction Stop
                Write-Log ('Выключено правило: ' + $r.DisplayName) 'OK'
            } catch { $ok = $false; Write-Log ('Не удалось выключить правило ' + $r.DisplayName + ': ' + $_.Exception.Message) 'WARN' }
        }
    }
    try {
        $prof = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.Enabled -and [string]$_.DefaultOutboundAction -eq 'Block' })
        if ($prof.Count -gt 0) {
            $q = 'Брандмауэр настроен запрещать ВСЕ исходящие соединения по умолчанию (так делают «приватные» программы). ' +
                 'Из-за этого Центр обновления не может выйти в интернет.' + "`r`n`r`n" + 'Разрешить исходящие соединения по умолчанию (стандартная настройка Windows)?'
            if (Request-UserConfirm $q 'Брандмауэр') {
                foreach ($p in $prof) { Set-NetFirewallProfile -Name $p.Name -DefaultOutboundAction Allow -ErrorAction SilentlyContinue }
                Write-Log 'Исходящие соединения разрешены по умолчанию.' 'OK'
            }
        }
    } catch { }
    return $ok
}

function Repair-Proxy {
    param([switch]$Force)
    $st = Test-ProxyAlive
    if (-not $st) { Write-Log 'Прокси WinHTTP не задан.' 'INFO'; return $true }
    if ($st.Alive -and -not $Force) {
        Write-Log ('Прокси ' + $st.Proxy + ' работает — не трогаю (через него идут обновления).') 'INFO'
        return $true
    }
    if (-not $Force) {
        $q = 'Центр обновления настроен ходить в интернет через ' + $st.Proxy + ', но этот адрес не отвечает (скорее всего, выключен VPN).' + "`r`n`r`n" +
             '«Да» — сбросить прокси: обновления пойдут напрямую, без VPN.' + "`r`n" + '«Нет» — оставить как есть (тогда включите VPN и запустите ремонт снова).'
        if (-not (Request-UserConfirm $q 'Прокси / VPN')) { Write-Log 'Прокси оставлен как есть — включите VPN.' 'INFO'; return 'skip' }
    }
    Write-Log 'Сбрасываю системный прокси WinHTTP…' 'STEP'
    $p = Get-WinHttpProxy
    [void](Backup-RegKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' 'winhttp_proxy')
    $r = Invoke-Proc 'netsh.exe' 'winhttp reset proxy' -TimeoutSec 30 -Quiet
    if ($r.ExitCode -eq 0) { Write-Log ('Прокси ' + $p.Proxy + ' сброшен.') 'OK'; return $true }
    Write-Log 'Не удалось сбросить прокси WinHTTP.' 'ERROR'
    return $false
}

function Repair-Time {
    Write-Log 'Синхронизирую время…' 'STEP'
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time'
    if ((Get-RegValue $key 'Start') -eq 4) { [void](Set-ServiceStartType 'W32Time' 3 $false) }
    [void](Start-ServiceSafe 'W32Time')
    [void](Invoke-Proc 'w32tm.exe' '/config /manualpeerlist:"time.windows.com,0x9 pool.ntp.org,0x9" /syncfromflags:manual /update' -TimeoutSec 30 -Quiet)
    [void](Invoke-Proc 'w32tm.exe' '/resync /force' -TimeoutSec 60 -Quiet)
    Start-Sleep -Seconds 2
    $net = Get-InternetUtcTime
    if (-not $net) { Write-Log 'Не удалось сверить время с интернетом.' 'WARN'; return $false }
    $skew = [math]::Abs(([datetime]::UtcNow - $net).TotalSeconds)
    if ($skew -gt 120) {
        # Служба времени не исправляет слишком большие расхождения — ставим время напрямую.
        try {
            Set-Date -Date $net.ToLocalTime() -ErrorAction Stop | Out-Null
            Write-Log ('Время установлено по интернету: ' + $net.ToLocalTime().ToString('dd.MM.yyyy HH:mm')) 'OK'
        } catch { Write-Log ('Не удалось установить время: ' + $_.Exception.Message) 'ERROR'; return $false }
    } else { Write-Log 'Время синхронизировано.' 'OK' }
    Write-Log 'Если время снова сбивается после выключения ПК — проверьте часовой пояс и батарейку на материнской плате.' 'INFO'
    return $true
}

function Repair-Network {
    Write-Log 'Сбрасываю кэш DNS…' 'STEP'
    [void](Invoke-Proc 'ipconfig.exe' '/flushdns' -TimeoutSec 30 -Quiet)
    $wu = @($script:ConnectivityTargets | Where-Object { $_.Need -eq 'WU' } | Select-Object -First 3)
    $fail = @($wu | Where-Object { -not (Test-TcpEndpoint $_.H $_.P).Ok })
    if ($fail.Count -eq 0) { Write-Log 'Серверы Microsoft доступны.' 'INFO'; return $true }
    $q = 'Серверы Microsoft всё ещё недоступны. Можно сбросить сетевой стек Winsock (помогает при «сломанных» сетевых настройках, нужна перезагрузка).' + "`r`n`r`nСбросить Winsock?"
    if (Request-UserConfirm $q 'Сеть') {
        $r = Invoke-Proc 'netsh.exe' 'winsock reset' -TimeoutSec 60 -Quiet
        if ($r.ExitCode -eq 0) {
            Write-Log 'Winsock сброшен. Перезагрузите компьютер, чтобы изменения вступили в силу.' 'OK'
            $script:NeedReboot = $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------
function Reset-WUComponents {
    Write-Log 'Сбрасываю компоненты Центра обновления…' 'STEP'
    Set-UiStatus 'Сброс компонентов Центра обновления…'
    [void](Invoke-Proc 'bitsadmin.exe' '/reset /allusers' -TimeoutSec 60 -Quiet)
    $svcs = @('wuauserv', 'UsoSvc', 'BITS', 'DoSvc', 'CryptSvc', 'msiserver', 'appidsvc')
    foreach ($s in $svcs) { [void](Stop-ServiceSafe $s) }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ok = $true
    $sd = Join-Path $env:windir 'SoftwareDistribution'
    $cr = Join-Path $env:windir 'System32\catroot2'
    foreach ($dir in @($sd, $cr)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $newName = (Split-Path $dir -Leaf) + '.old-' + $ts
        $renamed = $false
        for ($try = 1; $try -le 3 -and -not $renamed; $try++) {
            try { Rename-Item -LiteralPath $dir -NewName $newName -ErrorAction Stop; $renamed = $true }
            catch {
                foreach ($s in $svcs) { [void](Stop-ServiceSafe $s 10) }
                Start-Sleep -Seconds 2
            }
        }
        if ($renamed) { Write-Log ('Папка ' + $dir + ' переименована в ' + $newName) 'OK' }
        else { $ok = $false; Write-Log ('Не удалось переименовать ' + $dir + ' (файлы заняты — помогает перезагрузка, затем повтор).') 'WARN' }
    }
    # старые копии прошлых сбросов больше не нужны
    foreach ($pattern in @('SoftwareDistribution.old-*', 'System32\catroot2.old-*')) {
        $parent = Split-Path (Join-Path $env:windir $pattern) -Parent
        $leaf = Split-Path $pattern -Leaf
        Get-ChildItem -LiteralPath $parent -Directory -Filter $leaf -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike ('*' + $ts) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -Path (Join-Path $env:ProgramData 'Microsoft\Network\Downloader\qmgr*.dat') -Force -ErrorAction SilentlyContinue
    $wuKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
    if (Test-Path -LiteralPath $wuKey) {
        $idNames = @('AccountDomainSid', 'PingID', 'SusClientId', 'SusClientIDValidation')
        [void](Backup-RegValues $wuKey $idNames 'wu_client_ids')
        foreach ($n in $idNames) { [void](Remove-RegValue $wuKey $n -Quiet) }
    }
    [void](Repair-ServiceSecurity)
    Write-Log 'Перерегистрирую библиотеки Центра обновления…' 'INFO'
    $dlls = @('atl.dll', 'urlmon.dll', 'mshtml.dll', 'shdocvw.dll', 'browseui.dll', 'jscript.dll', 'vbscript.dll', 'scrrun.dll',
        'msxml.dll', 'msxml3.dll', 'msxml6.dll', 'actxprxy.dll', 'softpub.dll', 'wintrust.dll', 'dssenh.dll', 'rsaenh.dll',
        'gpkcsp.dll', 'sccbase.dll', 'slbcsp.dll', 'cryptdlg.dll', 'oleaut32.dll', 'ole32.dll', 'shell32.dll', 'initpki.dll',
        'wuapi.dll', 'wuaueng.dll', 'wuaueng1.dll', 'wucltui.dll', 'wups.dll', 'wups2.dll', 'wuweb.dll', 'qmgr.dll',
        'qmgrprxy.dll', 'wucltux.dll', 'muweb.dll', 'wuwebv.dll')
    $sys = Split-Path (Resolve-SystemExe 'regsvr32.exe') -Parent
    $n = 0
    foreach ($d in $dlls) {
        $p = Join-Path $sys $d
        if (-not (Test-Path -LiteralPath $p)) { continue }
        [void](Invoke-Proc 'regsvr32.exe' ('/s "' + $p + '"') -TimeoutSec 30 -Quiet)
        $n++
    }
    Write-Log ('Перерегистрировано библиотек: ' + $n) 'INFO'
    foreach ($s in @('CryptSvc', 'BITS', 'wuauserv', 'UsoSvc')) { [void](Start-ServiceSafe $s) }
    $uso = Resolve-SystemExe 'UsoClient.exe'
    if (Test-Path -LiteralPath $uso) { [void](Invoke-Proc $uso 'StartScan' -TimeoutSec 30 -Quiet) }
    if ($ok) { Write-Log 'Компоненты Центра обновления сброшены.' 'OK' }
    return $ok
}

# ---------------------------------------------------------------------
#  Образ Windows (ISO) как источник файлов
# ---------------------------------------------------------------------
function Mount-WindowsMedia {
    param([string]$Path)
    $res = [pscustomobject]@{ Root = $null; IsoPath = $null; Setup = $null; Image = $null; Error = $null }
    if (-not $Path) { $res.Error = 'Файл не выбран'; return $res }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.iso') {
        try {
            $img = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
            if (-not $img -or -not $img.Attached) { $img = Mount-DiskImage -ImagePath $Path -PassThru -ErrorAction Stop }
            Start-Sleep -Seconds 2
            $vol = $img | Get-Volume -ErrorAction Stop | Select-Object -First 1
            if (-not $vol.DriveLetter) { throw 'Образ подключён, но не получил букву диска.' }
            $res.Root = ([string]$vol.DriveLetter) + ':\'
            $res.IsoPath = $Path
            Write-Log ('Образ подключён как диск ' + $res.Root) 'OK'
        } catch {
            $res.Error = 'Не удалось подключить ISO: ' + $_.Exception.Message + '. Откройте ISO двойным щелчком в Проводнике и выберите файл setup.exe на появившемся диске.'
            return $res
        }
    } elseif ($ext -eq '.exe') {
        $res.Root = Split-Path $Path -Parent
        $res.Setup = $Path
    } elseif ($ext -in @('.wim', '.esd')) {
        $res.Image = $Path
        $res.Root = Split-Path (Split-Path $Path -Parent) -Parent
    }
    if (-not $res.Setup -and $res.Root) {
        $s = Join-Path $res.Root 'setup.exe'
        if (Test-Path -LiteralPath $s) { $res.Setup = $s }
    }
    if (-not $res.Image -and $res.Root) {
        foreach ($n in @('sources\install.wim', 'sources\install.esd')) {
            $p = Join-Path $res.Root $n
            if (Test-Path -LiteralPath $p) { $res.Image = $p; break }
        }
    }
    if (-not $res.Setup -and -not $res.Image) { $res.Error = 'В выбранном месте нет файлов установки Windows (setup.exe, sources\install.wim/esd).' }
    return $res
}

function Get-MediaImageInfo {
    param([string]$ImagePath)
    $list = @()
    try {
        foreach ($i in @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)) {
            $d = $null
            try { $d = Get-WindowsImage -ImagePath $ImagePath -Index $i.ImageIndex -ErrorAction Stop } catch { }
            $list += [pscustomobject]@{
                Index     = $i.ImageIndex
                Name      = $i.ImageName
                EditionId = $(if ($d) { [string]$d.EditionId } else { '' })
                Version   = $(if ($d) { [string]$d.Version } else { '' })
                Languages = $(if ($d) { @($d.Languages) } else { @() })
                Arch      = $(if ($d) { [string]$d.Architecture } else { '' })
            }
        }
    } catch { Write-Log ('Не удалось прочитать образ ' + $ImagePath + ': ' + $_.Exception.Message) 'WARN' }
    return $list
}

function Repair-ComponentStore {
    param([string]$SourcePath)
    Write-Log 'Глубокое восстановление: DISM (10–40 минут) и SFC (10–20 минут)…' 'STEP'
    Set-UiStatus 'DISM: восстановление хранилища компонентов… (не выключайте компьютер)'
    Set-UiProgress 0
    $source = ''
    if ($SourcePath) {
        $m = Mount-WindowsMedia $SourcePath
        if ($m.Error) { Write-Log $m.Error 'WARN' }
        elseif ($m.Image) {
            $idx = 1
            $info = $script:LastSysInfo
            $imgs = @(Get-MediaImageInfo $m.Image)
            $match = @($imgs | Where-Object { $info -and $_.EditionId -eq $info.EditionID })
            if ($match.Count -gt 0) { $idx = $match[0].Index }
            $kind = 'wim'
            if ($m.Image -like '*.esd') { $kind = 'esd' }
            $source = ' /Source:' + $kind + ':"' + $m.Image + '":' + $idx + ' /LimitAccess'
            Write-Log ('Источник файлов: ' + $m.Image + ' (индекс ' + $idx + ')') 'INFO'
        }
    }
    $r = Invoke-Proc 'dism.exe' ('/Online /Cleanup-Image /RestoreHealth' + $source) -TimeoutSec 7200 -LiveLog -Encoding oem
    $code = Format-HResult $r.ExitCode
    $dismOk = ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010)
    if ($dismOk) {
        Write-Log 'DISM: хранилище компонентов восстановлено.' 'OK'
    } else {
        $info = Get-ErrorInfo $code
        Write-Log ('DISM завершился с ошибкой ' + $code + ': ' + $info.Text) 'ERROR'
        if (-not $SourcePath -and $code -in @('0x800F081F', '0x800F0906', '0x800F0950', '0x800F0907')) {
            $q = 'DISM не смог скачать исправные файлы. Можно указать образ Windows 10 (ISO) той же версии и языка, что и система — файлы возьмутся из него.' + "`r`n`r`nВыбрать ISO-образ?"
            if (Request-UserConfirm $q 'DISM') {
                $iso = Request-UserFile 'Выберите образ Windows 10 (ISO) или install.wim/install.esd' 'Образ Windows (*.iso;*.wim;*.esd)|*.iso;*.wim;*.esd'
                if ($iso) { return (Repair-ComponentStore -SourcePath $iso) }
            }
        }
    }
    if (-not (Test-Path -LiteralPath (Resolve-SystemExe 'sfc.exe'))) { [void](Repair-MissingFiles) }
    if (-not (Test-Path -LiteralPath (Resolve-SystemExe 'sfc.exe'))) {
        Write-Log 'Программы sfc.exe нет в системе — проверку SFC пропускаю (её вернёт обновление Windows поверх).' 'WARN'
        Set-UiProgress -1
        return $dismOk
    }
    Write-Log 'SFC: проверка системных файлов…' 'STEP'
    Set-UiStatus 'SFC: проверка системных файлов… (не выключайте компьютер)'
    Set-UiProgress 0
    $s = Invoke-Proc 'sfc.exe' '/scannow' -TimeoutSec 7200 -LiveLog -Encoding unicode
    if ($s.ExitCode -eq 0) { Write-Log 'SFC: проверка завершена.' 'OK' }
    else { Write-Log ('SFC завершился с кодом ' + $s.ExitCode + '. Подробности: C:\Windows\Logs\CBS\CBS.log') 'WARN' }
    Set-UiProgress -1
    return $dismOk
}

# ---------------------------------------------------------------------
#  Удалённые системные файлы: в WinSxS обычно остаётся их копия
# ---------------------------------------------------------------------
function Get-WinSxSArchPrefix {
    switch (Get-ArchName) { 'x64' { return 'amd64' } 'arm64' { return 'arm64' } default { return 'x86' } }
}

function Find-WinSxSFile {
    param([string]$FileName)
    $sxs = Join-Path $env:windir 'WinSxS'
    $best = $null
    $bestVer = [version]'0.0'
    try { $dirs = [IO.Directory]::GetDirectories($sxs, (Get-WinSxSArchPrefix) + '_*') } catch { return $null }
    foreach ($d in $dirs) {
        $f = Join-Path $d $FileName
        if (-not [IO.File]::Exists($f)) { continue }
        $v = [version]'0.0'
        $m = [regex]::Match([IO.Path]::GetFileName($d), '_(\d+\.\d+\.\d+\.\d+)_')
        if ($m.Success) { try { $v = [version]$m.Groups[1].Value } catch { } }
        if ($v -ge $bestVer) { $bestVer = $v; $best = $f }
    }
    return $best
}

function Repair-MissingFiles {
    Write-Log 'Возвращаю удалённые системные файлы из хранилища компонентов (WinSxS)…' 'STEP'
    $info = $script:LastSysInfo
    if (-not $info) { $info = Get-SystemInfo }
    $ok = $true
    foreach ($c in $script:CriticalFiles) {
        if ($c.MinBuild -and $info.Build -lt $c.MinBuild) { continue }
        $dst = Join-Path $env:windir $c.P
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $dst = $dst -replace '\\System32\\', '\Sysnative\' }
        if (Test-Path -LiteralPath $dst) { continue }
        $src = Find-WinSxSFile ([IO.Path]::GetFileName($c.P))
        if (-not $src) {
            Write-Log ('Файла ' + $c.P + ' нет и в хранилище компонентов — его вернёт обновление Windows поверх.') 'WARN'
            $ok = $false
            continue
        }
        $copied = $false
        try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; $copied = $true } catch { }
        if (-not $copied) { $copied = (((Invoke-AsSystem ('copy /y "' + $src + '" "' + $dst + '"')) -eq 0) -and (Test-Path -LiteralPath $dst)) }
        if ($copied) { Write-Log ('Восстановлен файл ' + $c.P + ' (из ' + (Split-Path (Split-Path $src -Parent) -Leaf) + ')') 'OK' }
        else { $ok = $false; Write-Log ('Не удалось вернуть файл ' + $c.P) 'WARN' }
    }
    return $ok
}

function Repair-Sideload {
    Write-Log 'Разрешаю установку доверенных приложений MSIX (не из Магазина)…' 'STEP'
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'
    if ((Get-RegValue $k 'AllowAllTrustedApps') -eq 1 -and (Get-RegValue $pol 'AllowAllTrustedApps') -ne 0) {
        Write-Log 'Установка доверенных приложений уже разрешена.' 'INFO'
        return $true
    }
    [void](Backup-RegKey $k 'appmodelunlock')
    [void](Backup-RegKey $pol 'policy_appx')
    $ok = Set-RegValue $k 'AllowAllTrustedApps' 1 'DWord'
    if ((Get-RegValue $pol 'AllowAllTrustedApps') -eq 0) { if (-not (Remove-RegValue $pol 'AllowAllTrustedApps')) { $ok = $false } }
    if ($ok) { Write-Log 'Установка доверенных приложений разрешена.' 'OK' }
    return $ok
}

function Repair-DiskSpace {
    Write-Log 'Освобождаю место на диске…' 'STEP'
    $before = Get-FreeSpaceGB
    foreach ($pattern in @('SoftwareDistribution.old-*', 'System32\catroot2.old-*')) {
        $parent = Split-Path (Join-Path $env:windir $pattern) -Parent
        Get-ChildItem -LiteralPath $parent -Directory -Filter (Split-Path $pattern -Leaf) -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; Write-Log 'Кэш оптимизации доставки очищен.' 'OK' } catch { }
    }
    $limit = (Get-Date).AddDays(-2)
    foreach ($t in @($env:TEMP, (Join-Path $env:windir 'Temp'))) {
        Get-ChildItem -LiteralPath $t -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Get-ChildItem -LiteralPath $script:DownloadDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.iso' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    if (Request-UserConfirm 'Удалить устаревшие компоненты Windows (DISM /StartComponentCleanup)? Это может занять 10–20 минут, зато освобождает несколько гигабайт.' 'Очистка диска') {
        [void](Invoke-Proc 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup' -TimeoutSec 3600 -LiveLog)
    }
    $after = Get-FreeSpaceGB
    Write-Log ('Свободно было ' + $before + ' ГБ, стало ' + $after + ' ГБ.') 'OK'
    if ($after -lt 20) {
        Write-Log 'Места всё ещё мало. Откройте «Очистку диска» → «Очистить системные файлы», удалите ненужные программы и большие файлы.' 'WARN'
        try { Start-Process (Resolve-SystemExe 'cleanmgr.exe') -ArgumentList ('/d ' + $env:SystemDrive.TrimEnd(':')) } catch { }
    }
    return $true
}

function Hide-ProblemUpdate {
    param([string]$Kb = 'KB5034441')
    Write-Log ('Скрываю проблемное обновление ' + $Kb + '…') 'STEP'
    try {
        $s = New-Object -ComObject Microsoft.Update.Session
        $s.ClientApplicationID = 'WURepair'
        $q = $s.CreateUpdateSearcher()
        $r = $q.Search('IsInstalled=0')
        $n = 0
        foreach ($u in $r.Updates) {
            if (@($u.KBArticleIDs) -contains ($Kb -replace '^KB', '')) { $u.IsHidden = $true; $n++ }
        }
        if ($n -gt 0) { Write-Log ($Kb + ' скрыто — Windows больше не будет пытаться его ставить.') 'OK' }
        else { Write-Log ($Kb + ' среди доступных обновлений нет.') 'INFO' }
        return $true
    } catch {
        Write-Log ('Не удалось скрыть ' + $Kb + ': ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

# ---------------------------------------------------------------------
#  Автоматический ремонт
# ---------------------------------------------------------------------
function Invoke-AutoRepair {
    Write-Log '=============== АВТОМАТИЧЕСКИЙ РЕМОНТ ===============' 'STEP'
    $script:NeedReboot = $false
    $findings = @($script:LastFindings)
    if ($findings.Count -eq 0) {
        Write-Log 'Сначала выполняю диагностику…' 'INFO'
        $findings = @((Invoke-Diagnostics).Findings)
    }
    $fixes = @(Get-RecommendedFixes $findings)
    $ids = @($findings | Where-Object { $_.Severity -in 'ERROR', 'WARN' } | ForEach-Object { $_.Id })
    $wuBroken = @($ids | Where-Object { $_ -like 'scan-*' -or $_ -like 'evt-wu-*' -or $_ -like 'svc-*' }).Count -gt 0
    if ($wuBroken -and $fixes -notcontains 'ResetWU') { $fixes += 'ResetWU' }
    if ($fixes.Count -eq 0) {
        Write-Log 'Неисправностей, которые нужно чинить, не найдено.' 'OK'
        if (-not (Request-UserConfirm 'Серьёзных проблем не найдено. Всё равно выполнить профилактический сброс компонентов Центра обновления?' 'Ремонт')) {
            return [pscustomobject]@{ Done = @(); Failed = @(); Remaining = 0; Fixes = @() }
        }
        $fixes = @('ResetWU')
    }
    Write-Log ('План ремонта: ' + (Format-FixList $fixes)) 'INFO'
    [void](Get-SessionBackupDir)
    [void](New-SafetyRestorePoint)

    $plan = @(
        @{ F = 'IFEO';      N = 'Блокировки запуска (IFEO)';         S = { Repair-Ifeo } }
        @{ F = 'Policies';  N = 'Политики';                          S = { Repair-Policies } }
        @{ F = 'Services';  N = 'Службы';                            S = { Repair-Services } }
        @{ F = 'Tasks';     N = 'Задания планировщика';              S = { Repair-UpdateTasks } }
        @{ F = 'Hosts';     N = 'Файл hosts';                        S = { Repair-Hosts } }
        @{ F = 'Routes';    N = 'Сетевые маршруты';                  S = { Repair-Routes } }
        @{ F = 'Firewall';  N = 'Брандмауэр';                        S = { Repair-Firewall } }
        @{ F = 'Time';      N = 'Время';                             S = { Repair-Time } }
        @{ F = 'Proxy';     N = 'Прокси / VPN';                      S = { Repair-Proxy } }
        @{ F = 'Network';   N = 'Сеть';                              S = { Repair-Network } }
        @{ F = 'ResetWU';   N = 'Сброс компонентов Центра обновления'; S = { Reset-WUComponents } }
        @{ F = 'Sideload';  N = 'Установка приложений MSIX';         S = { Repair-Sideload } }
        @{ F = 'KB5034441'; N = 'Проблемное обновление KB5034441';   S = { Hide-ProblemUpdate 'KB5034441' } }
        @{ F = 'Defender';  N = 'Защитник Windows';                  S = { Repair-Defender -Light } }
        @{ F = 'Disk';      N = 'Место на диске';                    S = { Repair-DiskSpace } }
        @{ F = 'Files';     N = 'Удалённые системные файлы';         S = { Repair-MissingFiles } }
        @{ F = 'DISM';      N = 'Глубокое восстановление (DISM + SFC)'; S = {
                if (Request-UserConfirm 'Найдены признаки повреждения системных файлов. Запустить глубокое восстановление DISM + SFC? Это займёт 20–60 минут, компьютер выключать нельзя.' 'Глубокое восстановление') { Repair-ComponentStore }
                else { Write-Log 'Глубокое восстановление пропущено (можно запустить отдельной кнопкой).' 'INFO'; 'skip' } } }
        @{ F = 'Store';     N = 'Microsoft Store';                   S = {
                if (Request-UserConfirm 'Microsoft Store удалён или не работает. Восстановить его сейчас? (Понадобится скачать около 100–200 МБ.)' 'Microsoft Store') { Restore-MicrosoftStore }
                else { Write-Log 'Восстановление Магазина пропущено (можно запустить отдельной кнопкой).' 'INFO'; 'skip' } } }
    )
    $done = @(); $failed = @(); $skipped = @(); $checked = @()
    $i = 0
    $todo = @($plan | Where-Object { $fixes -contains $_.F })
    foreach ($p in $todo) {
        $i++
        Set-UiStatus ('Ремонт (' + $i + ' из ' + $todo.Count + '): ' + $p.N)
        Set-UiProgress -1
        $before = $script:OkLogCount
        $res = $false
        try { $res = @(& $p.S)[-1] } catch { Write-Log ($p.N + ': ' + $_.Exception.Message) 'ERROR'; $res = $false }
        $changed = ($script:OkLogCount -gt $before)
        if ($res -is [string] -and $res -eq 'skip') { $skipped += $p.N }
        elseif (-not $res) { if ($changed) { $failed += ($p.N + ' (частично)') } else { $failed += $p.N } }
        elseif ($changed) { $done += $p.N }
        else { $checked += $p.N }
    }
    Write-Log '--- Повторная диагностика после ремонта ---' 'STEP'
    $after = Invoke-Diagnostics -Quiet
    $script:RepairSummary = [pscustomobject]@{ Done = $done; Failed = $failed; Skipped = $skipped; Checked = $checked; Remaining = $after.Errors; Fixes = $after.Fixes }
    Write-Log ('Исправлено: ' + ($(if ($done.Count) { $done -join ', ' } else { 'ничего' }))) 'INFO'
    if ($checked.Count -gt 0) { Write-Log ('Проверено, менять не понадобилось: ' + ($checked -join ', ')) 'INFO' }
    if ($skipped.Count -gt 0) { Write-Log ('Пропущено по вашему выбору: ' + ($skipped -join ', ')) 'INFO' }
    if ($failed.Count -gt 0) { Write-Log ('Не получилось: ' + ($failed -join ', ')) 'WARN' }
    if ($after.Errors -eq 0) {
        Write-Log 'Ошибок больше нет. Теперь нажмите «Найти и установить обновления».' 'OK'
    } else {
        Write-Log ('Осталось ошибок: ' + $after.Errors + '. См. список проблем.') 'WARN'
        if ($after.Fixes -contains 'InPlace') {
            Write-Log 'Часть проблем можно устранить только обновлением Windows поверх (кнопка «Обновить Windows поверх»).' 'WARN'
        }
    }
    if ($script:NeedReboot -or ($after.Fixes -contains 'Reboot')) {
        Write-Log 'Рекомендуется перезагрузить компьютер, затем запустить программу снова.' 'WARN'
    }
    return $script:RepairSummary
}
