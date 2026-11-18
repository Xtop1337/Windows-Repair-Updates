@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "SCRIPT=%~dp0WURepair.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0src\WURepair.ps1"
if not exist "%SCRIPT%" (
  echo Не найден WURepair.ps1. Сначала распакуйте ВЕСЬ архив в папку, затем запустите START.bat оттуда.
  pause
  exit /b 1
)
rem Программа сама запросит права администратора (окно «Разрешить этому приложению вносить изменения?» - нажмите «Да»).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT%"
exit /b 0
