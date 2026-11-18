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
Add-Content -LiteralPath $hostsPath -Value "`r`n0.0.0.0 update.microsoft.com fe2.update.microsoft.com`r`n0.0.0.0 vortex.data.microsoft.com`r`n" -Encoding ASCII

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

New-NetFirewallRule -DisplayName 'WURepairTest Block Windows Update' -Direction Outbound -Action Block -Service wuauserv -ErrorAction SilentlyContinue | Out-Null

& route.exe -p add 203.0.113.77 mask 255.255.255.255 0.0.0.0 2>&1 | Out-Host
$routeAdded = @(Get-BlackholeRoutes (Get-PersistentRouteNames)).Count -gt 0
Write-Host ('Тестовый маршрут добавлен: ' + $routeAdded)

Write-Host '=== Диагностика (ожидаем найти всё сломанное) ==='
$d1 = Invoke-Diagnostics -SkipScan
Show-Findings $d1.Findings
$ids = @($d1.Findings | ForEach-Object { $_.Id })
Assert-That ($ids -contains 'hosts') 'hosts: блокировка найдена'
Assert-That (@($d1.Findings | Where-Object { $_.Id -like 'pol-*' -and $_.Severity -eq 'ERROR' }).Count -ge 2) 'политики: запреты найдены'
Assert-That ($ids -contains 'ifeo') 'IFEO: блокировка UsoClient найдена'
Assert-That ($ids -contains 'svc-wuauserv') 'службы: отключённый wuauserv найден'
Assert-That ($ids -contains 'fw') 'брандмауэр: блокирующее правило найдено'
if ($routeAdded) { Assert-That ($ids -contains 'routes') 'маршруты: «мёртвый» маршрут найден' }
Assert-That ($d1.Fixes -contains 'Hosts' -and $d1.Fixes -contains 'Services' -and $d1.Fixes -contains 'Policies') 'рекомендации ремонта сформированы'

Write-Host '=== Ремонт ==='
Assert-That (Repair-Ifeo) 'Repair-Ifeo'
Assert-That (Repair-Policies) 'Repair-Policies'
[void](Repair-Services)
Assert-That ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' 'Start') -ne 4) 'wuauserv больше не отключена'
Assert-That (Repair-Hosts) 'Repair-Hosts'
Assert-That (Repair-Firewall) 'Repair-Firewall'
if ($routeAdded) { Assert-That (Repair-Routes) 'Repair-Routes' }
[void](Repair-UpdateTasks)
Assert-That (Reset-WUComponents) 'Reset-WUComponents'

Write-Host '=== Повторная диагностика (ожидаем, что всё исправлено) ==='
$d2 = Invoke-Diagnostics -SkipScan
Show-Findings $d2.Findings
$ids2 = @($d2.Findings | Where-Object { $_.Severity -in 'ERROR', 'WARN' } | ForEach-Object { $_.Id })
foreach ($id in @('hosts', 'ifeo', 'svc-wuauserv', 'fw', 'routes')) {
    Assert-That ($ids2 -notcontains $id) ('исправлено: ' + $id)
}
Assert-That (@($d2.Findings | Where-Object { $_.Id -like 'pol-*' -and $_.Severity -eq 'ERROR' }).Count -eq 0) 'исправлено: политики'
$hostsAfter = [IO.File]::ReadAllText($hostsPath)
Assert-That ($hostsAfter -match 'vortex\.data\.microsoft\.com') 'телеметрия в hosts осталась заблокированной'
Assert-That ($hostsAfter -notmatch '(?m)^0\.0\.0\.0\s+update\.microsoft\.com') 'update.microsoft.com разблокирован'
Assert-That ((Get-Service wuauserv).Status -eq 'Running' -or (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' 'Start') -eq 3) 'wuauserv можно запустить'

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
& sc.exe config wuauserv start= demand | Out-Null
Get-NetFirewallRule -DisplayName 'WURepairTest*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
& route.exe delete 203.0.113.77 2>&1 | Out-Null

Write-Host ''
if ($script:Fail -gt 0) { Write-Host ('ПРОВАЛЕНО ПРОВЕРОК: ' + $script:Fail) -ForegroundColor Red; exit 1 }
Write-Host 'ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' -ForegroundColor Green
exit 0
