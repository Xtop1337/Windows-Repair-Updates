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
$layout = [IO.Path]::ChangeExtension($Out, '.layout.txt')
if (Test-Path -LiteralPath $layout) {
    Write-Host '===== РАСКЛАДКА ОКНА ====='
    Get-Content -LiteralPath $layout -Encoding UTF8 | ForEach-Object { Write-Host $_ }
}
$jpg = [IO.Path]::ChangeExtension($Out, '.small.jpg')
if (Test-Path -LiteralPath $jpg) {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($jpg))
    Write-Host ('===== JPEG-BASE64-BEGIN ' + [IO.Path]::GetFileName($Out) + ' ' + $b64.Length + ' =====')
    for ($i = 0; $i -lt $b64.Length; $i += 4000) { Write-Host ('B64:' + $b64.Substring($i, [Math]::Min(4000, $b64.Length - $i))) }
    Write-Host '===== JPEG-BASE64-END ====='
}
