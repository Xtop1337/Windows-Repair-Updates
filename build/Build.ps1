<#
    Сборка WURepair:
      1) склеивает движок (src\engine\*.ps1) и окно (src\WURepair.ps1) в один файл dist\WURepair.ps1;
      2) собирает из него dist\WURepair.exe (PS2EXE, только на Windows);
      3) упаковывает dist\WURepair-<версия>.zip (exe + ps1 + START.bat + инструкция).
#>
param(
    [string]$Version = '1.0.0',
    [string]$OutDir,
    [switch]$SkipExe
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$utf8Bom = New-Object Text.UTF8Encoding $true

# --- 1. Склейка ---
$engineFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src/engine') -Filter '*.ps1' | Sort-Object Name)
if ($engineFiles.Count -eq 0) { throw 'Не найдены файлы движка' }
$engine = (@($engineFiles | ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) }) -join "`r`n")
if ($engine -match "(?m)^'@") { throw "В движке есть строка, начинающаяся с '@ — её нельзя встроить в here-string." }
$verLine = [regex]::Match($engine, "(?m)^\`$script:AppVersion\s*=\s*'[^']*'")
if (-not $verLine.Success) { throw 'Не найдена строка с версией в движке' }
$engine = $engine.Replace($verLine.Value, ("`$script:AppVersion  = '" + $Version + "'"))

$ui = [IO.File]::ReadAllText((Join-Path $root 'src/WURepair.ps1'), [Text.Encoding]::UTF8)
$marker = '# <<ENGINE>>'
if ($ui.IndexOf($marker) -lt 0) { throw 'В src/WURepair.ps1 нет метки # <<ENGINE>>' }
$combined = $ui.Replace($marker, ("`$EmbeddedEngine = @'`r`n" + $engine + "`r`n'@"))
$combined = ($combined -replace "`r?`n", "`r`n")
$ps1 = Join-Path $OutDir 'WURepair.ps1'
[IO.File]::WriteAllText($ps1, $combined, $utf8Bom)

$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host ('{0}: {1}' -f $_.Extent.StartLineNumber, $_.Message) }
    throw 'Склеенный скрипт содержит синтаксические ошибки'
}
Write-Host "Склеено: $ps1 ($([math]::Round((Get-Item $ps1).Length / 1KB)) КБ)"

# --- 2. EXE ---
$exe = Join-Path $OutDir 'WURepair.exe'
if (-not $SkipExe) {
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ps2exe
    $v4 = $Version
    while (($v4.Split('.')).Count -lt 4) { $v4 += '.0' }
    Invoke-ps2exe -inputFile $ps1 -outputFile $exe -noConsole -requireAdmin -STA -noOutput -noError `
        -title 'WURepair' -description 'Ремонт Центра обновления Windows 10' -product 'WURepair' `
        -company 'WURepair' -copyright 'MIT License' -version $v4
    if (-not (Test-Path -LiteralPath $exe)) { throw 'PS2EXE не создал WURepair.exe' }
    Write-Host "Собрано: $exe"
}

# --- 3. ZIP ---
$stage = Join-Path $OutDir 'stage'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -LiteralPath $ps1 -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'START.bat') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'build/ПРОЧТИ.txt') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $stage 'LICENSE.txt')
if (Test-Path -LiteralPath $exe) { Copy-Item -LiteralPath $exe -Destination $stage }
$zip = Join-Path $OutDir ('WURepair-' + $Version + '.zip')
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host "Архив: $zip"
