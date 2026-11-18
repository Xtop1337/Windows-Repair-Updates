# =====================================================================
#  WURepair — справочные таблицы: службы, политики, домены, блокировки
# =====================================================================

# Обычная (не [ordered]) таблица: у упорядоченной индекс-число означает позицию.
$script:BuildNames = @{
    10240 = '1507'; 10586 = '1511'; 14393 = '1607'; 15063 = '1703'; 16299 = '1709'
    17134 = '1803'; 17763 = '1809'; 18362 = '1903'; 18363 = '1909'; 19041 = '2004'
    19042 = '20H2'; 19043 = '21H1'; 19044 = '21H2'; 19045 = '22H2'
}
$script:LatestWin10Build = 19045
$script:ClaudeMinBuild = 19041

# Службы и их значения по умолчанию в Windows 10.
#  S   — тип запуска (2 = автоматически, 3 = вручную)
#  D   — отложенный запуск
#  A   — учётная запись службы
#  Exe — что должно быть в пути к файлу службы
#  Img — исходный путь (восстанавливается, только если путь подменён)
#  Dll — библиотека службы (Parameters\ServiceDll)
#  G   — группа: WU (обновление), Store (приложения/MSIX), Defender, Core
$script:ServiceTable = @(
    @{ N = 'wuauserv';         R = 'Центр обновления Windows';                  G = 'WU';    S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Img = '%systemroot%\system32\svchost.exe -k netsvcs -p'; Dll = 'wuaueng.dll'; Crit = $true }
    @{ N = 'BITS';             R = 'Фоновая интеллектуальная служба передачи'; G = 'WU';    S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Img = '%SystemRoot%\System32\svchost.exe -k netsvcs -p'; Dll = 'qmgr.dll'; Crit = $true }
    @{ N = 'CryptSvc';         R = 'Службы криптографии';                       G = 'WU';    S = 2; D = $false; A = 'NT Authority\NetworkService'; Exe = 'svchost.exe'; Img = '%SystemRoot%\system32\svchost.exe -k NetworkService -p'; Dll = 'cryptsvc.dll'; Crit = $true }
    @{ N = 'TrustedInstaller'; R = 'Установщик модулей Windows';                G = 'WU';    S = 3; D = $false; A = 'LocalSystem'; Exe = 'TrustedInstaller.exe'; Img = '%SystemRoot%\servicing\TrustedInstaller.exe'; Crit = $true }
    @{ N = 'msiserver';        R = 'Установщик Windows (MSI)';                  G = 'WU';    S = 3; D = $false; A = 'LocalSystem'; Exe = 'msiexec.exe'; Img = '%systemroot%\system32\msiexec.exe /V'; Crit = $false }
    @{ N = 'UsoSvc';           R = 'Служба оркестратора обновлений';            G = 'WU';    S = 2; D = $true;  A = 'LocalSystem'; Exe = 'svchost.exe'; Img = '%systemroot%\system32\svchost.exe -k netsvcs -p'; Dll = 'usosvc.dll'; Crit = $true; MinBuild = 16299 }
    @{ N = 'WaaSMedicSvc';     R = 'Служба Medic Центра обновления Windows';   G = 'WU';    S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Img = '%systemroot%\system32\svchost.exe -k wusvcs -p'; Dll = 'WaaSMedicSvc.dll'; Crit = $false; MinBuild = 17134 }
    @{ N = 'DoSvc';            R = 'Оптимизация доставки';                      G = 'WU';    S = 2; D = $true;  A = 'NT Authority\NetworkService'; Exe = 'svchost.exe'; Img = '%SystemRoot%\System32\svchost.exe -k NetworkService -p'; Dll = 'dosvc.dll'; Crit = $false }
    @{ N = 'EventLog';         R = 'Журнал событий Windows';                    G = 'Core';  S = 2; D = $false; A = 'NT AUTHORITY\LocalService'; Exe = 'svchost.exe'; Crit = $true }
    @{ N = 'Schedule';         R = 'Планировщик заданий';                       G = 'Core';  S = 2; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Crit = $true }
    @{ N = 'Winmgmt';          R = 'Инструментарий управления Windows (WMI)';   G = 'Core';  S = 2; D = $false; A = 'localSystem'; Exe = 'svchost.exe'; Crit = $true }
    @{ N = 'W32Time';          R = 'Служба времени Windows';                    G = 'Core';  S = 3; D = $false; A = 'NT AUTHORITY\LocalService'; Exe = 'svchost.exe'; Crit = $false }
    @{ N = 'VSS';              R = 'Теневое копирование тома (точки восстановления)'; G = 'Core'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'vssvc.exe'; Crit = $false }
    @{ N = 'swprv';            R = 'Программный поставщик теневого копирования'; G = 'Core'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Crit = $false }
    @{ N = 'AppXSvc';          R = 'Служба развёртывания AppX (установка приложений MSIX)'; G = 'Store'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Img = '%SystemRoot%\system32\svchost.exe -k wsappx -p'; Crit = $true }
    @{ N = 'StateRepository';  R = 'Служба репозитория состояний';              G = 'Store'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Crit = $true }
    @{ N = 'ClipSVC';          R = 'Служба лицензий клиента (ClipSVC)';         G = 'Store'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Crit = $false }
    @{ N = 'InstallService';   R = 'Служба установки Microsoft Store';          G = 'Store'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Crit = $false }
    @{ N = 'wlidsvc';          R = 'Помощник по входу в учётную запись Microsoft'; G = 'Store'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Crit = $false }
    @{ N = 'TokenBroker';      R = 'Диспетчер веб-учётных записей';             G = 'Store'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Crit = $false }
    @{ N = 'LicenseManager';   R = 'Служба лицензий Windows (для Магазина)';    G = 'Store'; S = 3; D = $false; A = 'NT Authority\LocalService'; Exe = 'svchost.exe'; Crit = $false }
    @{ N = 'StorSvc';          R = 'Служба хранилища';                          G = 'Store'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'svchost.exe'; Crit = $false }
    @{ N = 'mpssvc';           R = 'Брандмауэр Защитника Windows (нужен для установки MSIX)'; G = 'Store'; S = 2; D = $false; A = 'NT Authority\LocalService'; Exe = 'svchost.exe'; Crit = $true }
    @{ N = 'BFE';              R = 'Служба базовой фильтрации';                 G = 'Store'; S = 2; D = $false; A = 'NT AUTHORITY\LocalService'; Exe = 'svchost.exe'; Crit = $true }
    @{ N = 'WinDefend';        R = 'Служба антивирусной программы Защитника';   G = 'Defender'; S = 2; D = $false; A = 'LocalSystem'; Exe = 'MsMpEng.exe'; Crit = $false }
    @{ N = 'WdNisSvc';         R = 'Служба проверки сети Защитника';            G = 'Defender'; S = 3; D = $false; A = 'NT Authority\LocalService'; Exe = 'NisSrv.exe'; Crit = $false }
    @{ N = 'SecurityHealthService'; R = 'Служба «Безопасность Windows»';        G = 'Defender'; S = 3; D = $false; A = 'LocalSystem'; Exe = 'SecurityHealthService.exe'; Crit = $false; MinBuild = 15063 }
    @{ N = 'wscsvc';           R = 'Центр обеспечения безопасности';            G = 'Defender'; S = 2; D = $true;  A = 'NT AUTHORITY\LocalService'; Exe = 'svchost.exe'; Crit = $false }
)

# Безопасный дескриптор по умолчанию (из официального сценария Microsoft
# для сброса Центра обновления) — применяется, только если в текущем
# дескрипторе есть запрещающие записи (их ставят «блокировщики» обновлений).
$script:DefaultServiceSD = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)'

# Политики, которые запрещают обновления/Магазин/установку приложений.
#  Bad — условие «плохого» значения; Area — к чему относится.
$script:PolicyChecks = @(
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'DisableWindowsUpdateAccess'; Bad = { param($v) $v -eq 1 }; T = 'Политика запрещает доступ к Центру обновления'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'DoNotConnectToWindowsUpdateInternetLocations'; Bad = { param($v) $v -eq 1 }; T = 'Политика запрещает подключаться к серверам обновления'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'WUServer'; Bad = { param($v) [string]$v -ne '' }; T = 'Обновления перенаправлены на чужой сервер (WSUS): {0}'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'WUStatusServer'; Bad = { param($v) [string]$v -ne '' }; T = 'Указан чужой сервер отчётов обновления: {0}'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'UpdateServiceUrlAlternate'; Bad = { param($v) [string]$v -ne '' }; T = 'Указан альтернативный сервер обновления: {0}'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'SetDisableUXWUAccess'; Bad = { param($v) $v -eq 1 }; T = 'Политика скрывает кнопки Центра обновления'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'DisableOSUpgrade'; Bad = { param($v) $v -eq 1 }; T = 'Политика запрещает обновление версии Windows'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'TargetReleaseVersion'; Bad = { param($v) $v -eq 1 }; T = 'Версия Windows «закреплена» политикой (не даёт обновиться до 22H2)'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'DeferFeatureUpdatesPeriodInDays'; Bad = { param($v) $v -gt 0 }; T = 'Обновления версии отложены политикой на {0} дн.'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'DeferQualityUpdatesPeriodInDays'; Bad = { param($v) $v -gt 0 }; T = 'Обновления безопасности отложены политикой на {0} дн.'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N = 'NoAutoUpdate'; Bad = { param($v) $v -eq 1 }; T = 'Автоматическое обновление отключено политикой'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N = 'UseWUServer'; Bad = { param($v) $v -eq 1 }; T = 'Включено использование чужого сервера обновлений (UseWUServer)'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OSUpgrade'; N = 'DisableOSUpgrade'; Bad = { param($v) $v -eq 1 }; T = 'Политика запрещает обновление версии Windows'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; N = 'NoWindowsUpdate'; Bad = { param($v) $v -eq 1 }; T = 'Центр обновления скрыт политикой (компьютер)'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; N = 'NoWindowsUpdate'; Bad = { param($v) $v -eq 1 }; T = 'Центр обновления скрыт политикой (пользователь)'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate'; N = 'DisableWindowsUpdateAccess'; Bad = { param($v) $v -eq 1 }; T = 'Доступ к Центру обновления запрещён (компьютер)'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate'; N = 'DisableWindowsUpdateAccess'; Bad = { param($v) $v -eq 1 }; T = 'Доступ к Центру обновления запрещён (пользователь)'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SYSTEM\Internet Communication Management\Internet Communication'; N = 'DisableWindowsUpdateAccess'; Bad = { param($v) $v -eq 1 }; T = 'Подключение к Центру обновления запрещено'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Internet Communication Management\Internet Communication'; N = 'DisableWindowsUpdateAccess'; Bad = { param($v) $v -eq 1 }; T = 'Подключение к Центру обновления запрещено политикой'; Sev = 'ERROR'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; N = 'SettingsPageVisibility'; Bad = { param($v) [string]$v -match '(?i)windowsupdate|windowsdefender|appsfeatures' }; T = 'Страницы «Параметров» скрыты: {0}'; Sev = 'WARN'; Area = 'WU' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N = 'RemoveWindowsStore'; Bad = { param($v) $v -eq 1 }; T = 'Microsoft Store запрещён политикой'; Sev = 'ERROR'; Area = 'Store' }
    @{ P = 'HKCU:\Software\Policies\Microsoft\WindowsStore'; N = 'RemoveWindowsStore'; Bad = { param($v) $v -eq 1 }; T = 'Microsoft Store запрещён политикой (пользователь)'; Sev = 'ERROR'; Area = 'Store' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N = 'DisableStoreApps'; Bad = { param($v) $v -eq 1 }; T = 'Приложения из Магазина запрещены политикой'; Sev = 'ERROR'; Area = 'Store' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; N = 'DODownloadMode'; Bad = { param($v) $v -eq 100 }; T = 'Режим загрузки «Bypass» (100) — может ломать загрузки Магазина'; Sev = 'WARN'; Area = 'Store' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'; N = 'AllowAllTrustedApps'; Bad = { param($v) $v -eq 0 }; T = 'Политика запрещает устанавливать приложения MSIX не из Магазина (мешает установке Claude)'; Sev = 'ERROR'; Area = 'Store' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'; N = 'DisableDeploymentToNonSystemVolumes'; Bad = { param($v) $v -eq 1 }; T = 'Политика ограничивает установку приложений'; Sev = 'INFO'; Area = 'Store' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; N = 'DisableAntiSpyware'; Bad = { param($v) $v -eq 1 }; T = 'Защитник Windows выключен политикой'; Sev = 'WARN'; Area = 'Defender' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; N = 'DisableAntiVirus'; Bad = { param($v) $v -eq 1 }; T = 'Антивирус Защитника выключен политикой'; Sev = 'WARN'; Area = 'Defender' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; N = 'DisableRealtimeMonitoring'; Bad = { param($v) $v -eq 1 }; T = 'Защита в реальном времени выключена политикой'; Sev = 'WARN'; Area = 'Defender' }
)

# Значения, которые удаляются вместе с «закреплением» версии.
$script:PolicyCompanions = @{
    'TargetReleaseVersion'            = @('TargetReleaseVersionInfo', 'ProductVersion')
    'DeferFeatureUpdatesPeriodInDays' = @('DeferFeatureUpdates', 'PauseFeatureUpdatesStartTime')
    'DeferQualityUpdatesPeriodInDays' = @('DeferQualityUpdates', 'PauseQualityUpdatesStartTime')
    'WUServer'                        = @('WUStatusServer', 'UpdateServiceUrlAlternate')
}

$script:PauseValues = @(
    'PauseUpdatesExpiryTime', 'PauseUpdatesStartTime',
    'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime',
    'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime'
)

# Программы, запуск которых «блокировщики» отключают через
# Image File Execution Options (значение Debugger).
$script:IfeoTargets = @(
    'MusNotification.exe', 'MusNotificationUx.exe', 'UsoClient.exe', 'MoUsoCoreWorker.exe',
    'WaaSMedicAgent.exe', 'SIHClient.exe', 'wuauclt.exe', 'SetupHost.exe', 'SetupPrep.exe',
    'Windows10UpgraderApp.exe', 'Windows10Upgrade.exe', 'remsh.exe', 'TiWorker.exe',
    'TrustedInstaller.exe', 'WinStore.App.exe', 'MpCmdRun.exe', 'MsMpEng.exe',
    'SecHealthUI.exe', 'SecurityHealthService.exe', 'SecurityHealthSystray.exe',
    'DismHost.exe', 'dism.exe', 'sfc.exe', 'AppInstaller.exe', 'winget.exe', 'wsreset.exe',
    'Claude.exe', 'msiexec.exe', 'EOSNotify.exe', 'osrrb.exe', 'disksnapshot.exe'
)

# Задания планировщика, нужные для автоматического обновления
# (включены по умолчанию в Windows 10).
$script:UpdateTasks = @(
    '\Microsoft\Windows\WindowsUpdate\Scheduled Start',
    '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan',
    '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan Static Task',
    '\Microsoft\Windows\UpdateOrchestrator\Report policies',
    '\Microsoft\Windows\UpdateOrchestrator\UpdateModelTask',
    '\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker',
    '\Microsoft\Windows\WaaSMedic\PerformRemediation',
    '\Microsoft\Windows\InstallService\ScanForUpdates',
    '\Microsoft\Windows\InstallService\ScanForUpdatesAsUser'
)

# Домены, записи которых в hosts ломают обновления/Магазин/загрузки.
$script:ProtectedDomainSuffixes = @(
    'microsoft.com', 'windowsupdate.com', 'windows.com', 'windows.net', 'microsoft.net',
    'live.com', 'live.net', 'msftconnecttest.com', 'msftncsi.com', 'msedge.net',
    's-microsoft.com', 'microsoftonline.com', 'msauth.net', 'msftauth.net', 'aka.ms',
    'gfx.ms', 'microsoftstore.com', 'msocsp.com', 'digicert.com',
    'claude.ai', 'claude.com', 'anthropic.com', 'github.com', 'githubusercontent.com'
)
# Чисто «шпионские» (телеметрия/реклама) адреса оставляем заблокированными —
# для обновлений и Магазина они не нужны.
$script:TelemetryHostPattern = '(?i)(vortex|telemetry|watson|^oca\.|\.events\.data\.microsoft\.com$|^v10\.|^v20\.|^sqm\.|^statsfe|^ads\d*\.|adnxs|^rad\.msn|^feedback\.|^diagnostics\.|^ceuswatcab|^umwatson|^choice\.microsoft\.com$|^df\.telemetry|^compatexchange|^settings-sandbox)'

# Серверы, доступность которых проверяем.
$script:ConnectivityTargets = @(
    @{ H = 'www.microsoft.com';               P = 443; R = 'Сайт Microsoft';                  Need = 'WU' }
    @{ H = 'update.microsoft.com';            P = 443; R = 'Центр обновления';                Need = 'WU' }
    @{ H = 'fe2.update.microsoft.com';        P = 443; R = 'Центр обновления (поиск)';        Need = 'WU' }
    @{ H = 'sls.update.microsoft.com';        P = 443; R = 'Центр обновления (служба поиска)'; Need = 'WU' }
    @{ H = 'download.windowsupdate.com';      P = 80;  R = 'Загрузка обновлений';             Need = 'WU' }
    @{ H = 'dl.delivery.mp.microsoft.com';    P = 443; R = 'Загрузка обновлений (CDN)';       Need = 'WU' }
    @{ H = 'ctldl.windowsupdate.com';         P = 80;  R = 'Списки сертификатов';             Need = 'WU' }
    @{ H = 'go.microsoft.com';                P = 443; R = 'Ссылки Microsoft (загрузки)';     Need = 'WU' }
    @{ H = 'displaycatalog.mp.microsoft.com'; P = 443; R = 'Каталог Microsoft Store';         Need = 'Store' }
    @{ H = 'login.live.com';                  P = 443; R = 'Вход в учётную запись Microsoft'; Need = 'Store' }
    @{ H = 'api.github.com';                  P = 443; R = 'GitHub (загрузка «Установщика приложений»)'; Need = 'Store' }
    @{ H = 'claude.ai';                       P = 443; R = 'Загрузка Claude Desktop';         Need = 'Claude' }
)

# Ключевые файлы Центра обновления и установки приложений.
$script:CriticalFiles = @(
    @{ P = 'System32\wuaueng.dll';            R = 'движок Центра обновления' }
    @{ P = 'System32\wuapi.dll';              R = 'интерфейс Центра обновления' }
    @{ P = 'System32\wuauclt.exe';            R = 'клиент Центра обновления' }
    @{ P = 'System32\usoclient.exe';          R = 'оркестратор обновлений'; MinBuild = 16299 }
    @{ P = 'System32\qmgr.dll';               R = 'служба BITS' }
    @{ P = 'System32\cryptsvc.dll';           R = 'службы криптографии' }
    @{ P = 'System32\AppXDeploymentServer.dll'; R = 'установка приложений MSIX' }
    @{ P = 'System32\Dism.exe';               R = 'DISM' }
    @{ P = 'System32\sfc.exe';                R = 'проверка системных файлов' }
    @{ P = 'System32\msiexec.exe';            R = 'установщик MSI' }
    @{ P = 'servicing\TrustedInstaller.exe';  R = 'установщик модулей Windows' }
)

# Пакеты приложений, связанные с Магазином.
$script:StorePackages = @(
    @{ N = 'Microsoft.WindowsStore';           R = 'Microsoft Store';             Crit = $true }
    @{ N = 'Microsoft.StorePurchaseApp';       R = 'Покупки в Магазине';          Crit = $false }
    @{ N = 'Microsoft.DesktopAppInstaller';    R = 'Установщик приложений (winget)'; Crit = $false }
    @{ N = 'Microsoft.Windows.SecHealthUI';    R = 'Приложение «Безопасность Windows»'; Crit = $false }
)

# Правила брандмауэра, похожие на блокировку обновлений.
# Только явные признаки блокировки Windows/Microsoft (не трогаем, например, «BlockGoogleUpdate»).
$script:FirewallSuspectPattern = '(?i)(\bDWS\b|DWS_|spy|telemetr|windows[\s_-]*update|wuauserv|winupdate|microsoft[\s_-]*update|block[\s_-]*(windows|microsoft|win10|telemetr)|(windows|microsoft)[\s_-]*block|O&O|ShutUp10|w10privacy|debloat|\bwin10\b|windows10|stopupdates|blackbird|destroy[\s_-]*windows)'
$script:FirewallSuspectServices = @('wuauserv', 'bits', 'dosvc', 'usosvc', 'waasmedicsvc', 'cryptsvc', 'installservice', 'appxsvc', 'clipsvc', 'wlidsvc')
$script:FirewallSuspectPrograms = '(?i)(\\svchost\.exe|\\wuauclt\.exe|\\usoclient\.exe|\\MoUsoCoreWorker\.exe|\\WinStore\.App\.exe|\\SIHClient\.exe|\\TiWorker\.exe|\\SetupHost\.exe)$'
