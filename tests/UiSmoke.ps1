<#
    Смоук-тест окна программы (для CI): запускает WURepair.exe или WURepair.ps1
    в режиме WUREPAIR_SMOKE — окно само выполняет диагностику, сохраняет
    скриншот и закрывается.
#>
param(
    [string]$Exe,
    [string]$Script,
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$TimeoutSec = 600
)
$ErrorActionPreference = 'Stop'
$Out = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Path (Split-Path $Out -Parent) -Force | Out-Null
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
$env:WUREPAIR_SMOKE = $Out
$env:WUREPAIR_NO_OPEN = '1'
if ($Exe) {
    $p = Start-Process -FilePath ([IO.Path]::GetFullPath($Exe)) -PassThru
} else {
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File "' + [IO.Path]::GetFullPath($Script) + '"')
}
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch { }
    throw "Окно не завершилось за $TimeoutSec с"
}
Write-Host ('Код выхода: ' + $p.ExitCode)
if (-not (Test-Path -LiteralPath $Out)) { throw 'Скриншот не создан — окно не дошло до конца диагностики.' }
Write-Host ('Скриншот: ' + $Out + ' (' + (Get-Item $Out).Length + ' байт)')
