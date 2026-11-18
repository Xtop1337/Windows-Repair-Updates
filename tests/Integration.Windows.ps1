<#
    Интеграционный тест на настоящей Windows (запускается в GitHub Actions на
    одноразовой виртуальной машине). Он намеренно «ломает» систему так, как это
    делают программы-«чистильщики» и блокировщики обновлений, затем проверяет,
    что диагностика всё находит, а ремонт — исправляет.
    НЕ ЗАПУСКАЙТЕ на своём компьютере.
#>
param([switch]$IReallyWantToBreakThisMachine)

$ErrorActionPreference = 'Continue'
if (-not $env:GITHUB_ACTIONS -and -not $IReallyWantToBreakThisMachine) {
    throw 'Этот тест портит настройки Windows и предназначен только для CI.'
}
$env:WUREPAIR_NO_OPEN = '1'
$env:WUREPAIR_VERBOSE = '1'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/WURepair.ps1') -NoGui
Initialize-AppDirs

$script:Fail = 0
function Assert-That {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host ('PASS  ' + $Message) -ForegroundColor Green }
    else { Write-Host ('FAIL  ' + $Message) -ForegroundColor Red; $script:Fail++ }
}
function Show-Findings {
    param($Findings)
    $Findings | Sort-Object Severity | Format-Table -AutoSize -Wrap Severity, Id, Category, Title | Out-String -Width 220 | Write-Host
}

Write-Host '=== Сведения о системе ==='
$info = Get-SystemInfo
Write-Host (Format-SystemInfo $info)

Write-Host '=== Ломаю систему ==='
$hostsPath = Get-HostsPath
$hostsBefore = [IO.File]::ReadAllText($hostsPath)
Add-Content -LiteralPath $hostsPath -Value "`r`n0.0.0.0 update.microsoft.com fe2.update.microsoft.com`r`n0.0.0.0 vortex.data.microsoft.com`r`n185.199.109.133 objects.githubusercontent.com`r`n" -Encoding ASCII

$wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
New-Item -Path "$wuPol\AU" -Force | Out-Null
New-ItemProperty -Path $wuPol -Name DisableWindowsUpdateAccess -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $wuPol -Name WUServer -Value 'http://127.0.0.1:8530' -PropertyType String -Force | Out-Null
New-ItemProperty -Path "$wuPol\AU" -Name UseWUServer -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path "$wuPol\AU" -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null

$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\UsoClient.exe'
New-Item -Path $ifeo -Force | Out-Null
New-ItemProperty -Path $ifeo -Name Debugger -Value 'systray.exe' -PropertyType String -Force | Out-Null

Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
& sc.exe config wuauserv start= disabled | Out-Host

# Как Windows Update Blocker: запрет записи в ключ службы даже для SYSTEM
[void](Enable-Privilege @('SeTakeOwnershipPrivilege', 'SeRestorePrivilege', 'SeBackupPrivilege'))
# (читать можно, записывать нельзя никому — как в реальном отчёте с Wub)
Reset-HklmKeyAcl 'SYSTEM\CurrentControlSet\Services\wuauserv' 'D:P(D;;0x6;;;SY)(D;;0x6;;;BA)(A;;KR;;;SY)(A;;KR;;;BA)(A;;KR;;;BU)'
$scTry = & sc.exe config wuauserv start= demand 2>&1 | Out-String
Write-Host ('Попытка включить заблокированную службу: ' + $scTry.Trim())
Assert-That (Test-HklmKeyLocked 'SYSTEM\CurrentControlSet\Services\wuauserv') 'ключ wuauserv заблокирован как у Windows Update Blocker'
Assert-That ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' 'Start') -eq 4) 'заблокированную службу не удалось включить обычным способом'

# «Выключенный VPN»: прокси, который не отвечает
& netsh.exe winhttp set proxy 127.0.0.1:65000 | Out-Host

# Удалённый системный файл
$sfc = Join-Path $env:windir 'System32\sfc.exe'
& takeown.exe /f $sfc | Out-Null
& icacls.exe $sfc /grant '*S-1-5-32-544:F' | Out-Null
Remove-Item -LiteralPath $sfc -Force -ErrorAction SilentlyContinue
Assert-That (-not (Test-Path -LiteralPath $sfc)) 'sfc.exe удалён для теста'

New-NetFirewallRule -DisplayName 'WURepairTest Block Windows Update' -Direction Outbound -Action Block -Service wuauserv -ErrorAction SilentlyContinue | Out-Null

& route.exe -p add 203.0.113.77 mask 255.255.255.255 0.0.0.0 2>&1 | Out-Host
$routeAdded = @(Get-BlackholeRoutes (Get-PersistentRouteNames)).Count -gt 0
Write-Host ('Тестовый маршрут добавлен: ' + $routeAdded)

$foreignRules = @(Get-NetFirewallRule -Direction Outbound -Action Block -Enabled True -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -notlike 'WURepairTest*' -and $_.DisplayName -notmatch $script:FirewallSuspectPattern } | ForEach-Object { $_.Name })
Write-Host ('Посторонних блокирующих правил: ' + $foreignRules.Count)

Write-Host '=== Диагностика (ожидаем найти всё сломанное) ==='
$d1 = Invoke-Diagnostics -SkipScan
Show-Findings $d1.Findings
$ids = @($d1.Findings | ForEach-Object { $_.Id })
Assert-That ($ids -contains 'hosts') 'hosts: блокировка найдена'
Assert-That (@($d1.Findings | Where-Object { $_.Id -like 'pol-*' -and $_.Severity -eq 'ERROR' }).Count -ge 2) 'политики: запреты найдены'
Assert-That ($ids -contains 'ifeo') 'IFEO: блокировка UsoClient найдена'
Assert-That ($ids -contains 'svc-wuauserv') 'службы: отключённый wuauserv найден'
$svcF = @($d1.Findings | Where-Object { $_.Id -eq 'svc-wuauserv' })[0]
Assert-That ($svcF.Title -match 'права ключа') 'службы: блокировка прав ключа распознана'
Assert-That ($ids -contains 'proxy-dead') 'прокси: «мёртвый» VPN-прокси найден'
Assert-That ($ids -contains 'files-missing') 'файлы: удалённый sfc.exe найден'
Assert-That ((@($d1.Findings | Where-Object { $_.Id -eq 'hosts' })[0].Detail) -notmatch 'githubusercontent') 'hosts: строка GitHub с настоящим IP не считается блокировкой'
Assert-That ($ids -contains 'fw') 'брандмауэр: блокирующее правило найдено'
if ($routeAdded) { Assert-That ($ids -contains 'routes') 'маршруты: «мёртвый» маршрут найден' }
Assert-That ($d1.Fixes -contains 'Hosts' -and $d1.Fixes -contains 'Services' -and $d1.Fixes -contains 'Policies') 'рекомендации ремонта сформированы'

Write-Host '=== Ремонт ==='
Assert-That (Repair-Ifeo) 'Repair-Ifeo'
Assert-That (Repair-Policies) 'Repair-Policies'
[void](Repair-Services)
Assert-That ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' 'Start') -ne 4) 'wuauserv больше не отключена'
Assert-That ((Get-Service wuauserv -ErrorAction SilentlyContinue) -ne $null) 'wuauserv существует'
Assert-That (-not (Test-HklmKeyLocked 'SYSTEM\CurrentControlSet\Services\wuauserv')) 'блокировка прав wuauserv снята'
Assert-That (Repair-Hosts) 'Repair-Hosts'
Assert-That ([IO.File]::ReadAllText($hostsPath) -match 'objects\.githubusercontent\.com') 'hosts: строка GitHub сохранена'
Assert-That ((Repair-Proxy) -eq $true) 'Repair-Proxy (без окна — сразу сброс)'
Assert-That (-not (Get-WinHttpProxy).Proxy) 'прокси сброшен'
Assert-That (Repair-MissingFiles) 'Repair-MissingFiles'
Assert-That (Test-Path -LiteralPath $sfc) 'sfc.exe возвращён из WinSxS'
Assert-That (Repair-Firewall) 'Repair-Firewall'
foreach ($n in $foreignRules) {
    $r = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
    Assert-That ($r -and [string]$r.Enabled -eq 'True') ('постороннее правило не тронуто: ' + $r.DisplayName)
}
if ($routeAdded) { Assert-That (Repair-Routes) 'Repair-Routes' }
[void](Repair-UpdateTasks)
Assert-That (Reset-WUComponents) 'Reset-WUComponents'

Write-Host '=== Повторная диагностика (ожидаем, что всё исправлено) ==='
$d2 = Invoke-Diagnostics -SkipScan
Show-Findings $d2.Findings
$ids2 = @($d2.Findings | Where-Object { $_.Severity -in 'ERROR', 'WARN' } | ForEach-Object { $_.Id })
foreach ($id in @('hosts', 'ifeo', 'svc-wuauserv', 'fw', 'routes', 'proxy-dead', 'files-missing')) {
    Assert-That ($ids2 -notcontains $id) ('исправлено: ' + $id)
}
Assert-That (@($d2.Findings | Where-Object { $_.Id -like 'pol-*' -and $_.Severity -eq 'ERROR' }).Count -eq 0) 'исправлено: политики'
$hostsAfter = [IO.File]::ReadAllText($hostsPath)
Assert-That ($hostsAfter -match 'vortex\.data\.microsoft\.com') 'телеметрия в hosts осталась заблокированной'
Assert-That ($hostsAfter -notmatch '(?m)^0\.0\.0\.0\s+update\.microsoft\.com') 'update.microsoft.com разблокирован'
Assert-That ((Get-Service wuauserv).Status -eq 'Running' -or (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' 'Start') -eq 3) 'wuauserv можно запустить'

Write-Host '=== Работающий VPN-прокси не трогаем ==='
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$vpnPort = $listener.LocalEndpoint.Port
& netsh.exe winhttp set proxy ('127.0.0.1:' + $vpnPort) | Out-Null
$pf = @(Test-Proxy)
Assert-That (@($pf | Where-Object { $_.Id -eq 'proxy-winhttp' -and $_.Severity -eq 'INFO' }).Count -eq 1) 'живой VPN-прокси распознан как рабочий'
Assert-That (@($pf | Where-Object { $_.Id -eq 'proxy-dead' }).Count -eq 0) 'живой VPN-прокси не считается сломанным'
[void](Repair-Proxy)
Assert-That ((Get-WinHttpProxy).Proxy -eq ('127.0.0.1:' + $vpnPort)) 'ремонт не сбросил работающий VPN-прокси'
& netsh.exe winhttp reset proxy | Out-Null
$listener.Stop()

Write-Host '=== Пробный поиск обновлений ==='
$probe = Invoke-WUSearchProbe -TimeoutSec 420
Write-Host ('Результат: Ok=' + $probe.Ok + ' Count=' + $probe.Count + ' Code=' + $probe.Code + ' TimedOut=' + $probe.TimedOut + ' ' + $probe.Message)
Assert-That ($probe.Ok -or $probe.TimedOut -or $probe.Code) 'поиск обновлений вернул понятный результат'

Write-Host '=== Отчёт ==='
$script:LastFindings = $d2.Findings
$rep = Export-Report
Assert-That (Test-Path -LiteralPath $rep) 'отчёт сохранён'

Write-Host '=== Откат ==='
$sessions = @(Get-BackupSessions)
Assert-That ($sessions.Count -gt 0) 'резервные копии созданы'
Get-ChildItem -LiteralPath $sessions[0].FullName | Format-Table Name, Length -AutoSize | Out-String | Write-Host
Assert-That (Restore-FromBackup -Dir $sessions[0].FullName) 'откат выполнен'
Assert-That ((Get-RegValue $wuPol 'DisableWindowsUpdateAccess') -eq 1) 'откат вернул политику'
Assert-That ([IO.File]::ReadAllText($hostsPath) -match '(?m)^0\.0\.0\.0\s+update\.microsoft\.com') 'откат вернул hosts'

Write-Host '=== Уборка ==='
[IO.File]::WriteAllText($hostsPath, $hostsBefore)
Remove-Item -Path $wuPol -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $ifeo -Recurse -Force -ErrorAction SilentlyContinue
[void](Unlock-ServiceKey 'wuauserv')
& netsh.exe winhttp reset proxy | Out-Null
if (-not (Test-Path -LiteralPath $sfc)) { [void](Repair-MissingFiles) }
& sc.exe config wuauserv start= demand | Out-Null
Get-NetFirewallRule -DisplayName 'WURepairTest*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
& route.exe delete 203.0.113.77 2>&1 | Out-Null

Write-Host ''
if ($script:Fail -gt 0) { Write-Host ('ПРОВАЛЕНО ПРОВЕРОК: ' + $script:Fail) -ForegroundColor Red; exit 1 }
Write-Host 'ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' -ForegroundColor Green
exit 0
