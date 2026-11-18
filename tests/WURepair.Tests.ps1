# Модульные тесты чистых функций движка (Pester 5).
# Работают и на Windows PowerShell 5.1, и на PowerShell 7 (в т.ч. не на Windows).

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    if ($IsLinux -or $IsMacOS) {
        # Вне Windows файл окна не компилируется (System.Drawing) — грузим только движок.
        $engine = (@(Get-ChildItem -LiteralPath (Join-Path $root 'src/engine') -Filter '*.ps1' | Sort-Object Name |
            ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) }) -join "`r`n")
        . ([scriptblock]::Create($engine))
    } else {
        . (Join-Path $root 'src/WURepair.ps1') -NoGui
    }
}

Describe 'Format-HResult' {
    It 'переводит отрицательный int в шестнадцатеричный код' {
        Format-HResult (-2147024894) | Should -Be '0x80070002'
        Format-HResult (-2145124316) | Should -Be '0x80240024'
    }
    It 'нормализует строку' {
        Format-HResult '0x8024402c' | Should -Be '0x8024402C'
        Format-HResult '0x422' | Should -Be '0x00000422'
    }
    It 'понимает положительные коды' {
        Format-HResult 2147943458 | Should -Be '0x80070422'
        Format-HResult 0 | Should -Be '0x00000000'
    }
    It 'возвращает $null для пустого значения' {
        Format-HResult $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-ErrorInfo' {
    It 'знает 0x80070422 (служба отключена)' {
        $i = Get-ErrorInfo '0x80070422'
        $i.Known | Should -BeTrue
        $i.Fix | Should -Contain 'Services'
    }
    It 'не зависит от регистра' {
        (Get-ErrorInfo '0x8024402c').Known | Should -BeTrue
    }
    It 'классифицирует неизвестные коды по семейству' {
        (Get-ErrorInfo '0x80072999').Fix | Should -Contain 'Hosts'
        (Get-ErrorInfo '0x800F0999').Fix | Should -Contain 'DISM'
        (Get-ErrorInfo '0x80073C99').Fix | Should -Contain 'Sideload'
    }
    It 'все исправления из базы имеют описание' {
        foreach ($k in $script:ErrorKB.Keys) {
            foreach ($f in $script:ErrorKB[$k].F) { $script:FixNames.ContainsKey($f) | Should -BeTrue -Because "$k → $f" }
        }
    }
    It 'все ключи базы — корректные коды' {
        foreach ($k in $script:ErrorKB.Keys) { $k | Should -Match '^0x[0-9A-F]{8}$' }
    }
}

Describe 'Get-ErrorMessages' {
    It 'находит коды в тексте' {
        $c = Get-ErrorMessages 'Ошибка 0x80070002 и снова 0x80070002, потом 0x8024a105'
        $c.Count | Should -Be 2
        $c | Should -Contain '0x8024A105'
    }
}

Describe 'hosts' {
    It 'распознаёт адреса Microsoft' {
        Test-IsProtectedHost 'update.microsoft.com' | Should -BeTrue
        Test-IsProtectedHost 'DL.Delivery.MP.Microsoft.com.' | Should -BeTrue
        Test-IsProtectedHost 'windowsupdate.com' | Should -BeTrue
        Test-IsProtectedHost 'claude.ai' | Should -BeTrue
    }
    It 'оставляет телеметрию и чужие домены' {
        Test-IsProtectedHost 'vortex.data.microsoft.com' | Should -BeFalse
        Test-IsProtectedHost 'v10.events.data.microsoft.com' | Should -BeFalse
        Test-IsProtectedHost 'watson.telemetry.microsoft.com' | Should -BeFalse
        Test-IsProtectedHost 'example.com' | Should -BeFalse
        Test-IsProtectedHost 'notmicrosoft.com' | Should -BeFalse
        Test-IsProtectedHost 'localhost' | Should -BeFalse
    }
    It 'чинит файл hosts, не трогая остальное' {
        $lines = @(
            '# комментарий',
            '127.0.0.1 localhost',
            '0.0.0.0 update.microsoft.com',
            '0.0.0.0 vortex.data.microsoft.com',
            '0.0.0.0 fe2.update.microsoft.com vortex-win.data.microsoft.com  # смешанная',
            '192.168.1.10 nas.local',
            '#0.0.0.0 windowsupdate.microsoft.com',
            ''
        )
        $bad = @(Get-HostsBlockEntries -Lines $lines)
        $bad.Count | Should -Be 2
        $r = Get-RepairedHostsLines -Lines $lines
        $r.Removed | Should -Be 2
        $r.Lines | Should -Contain '# комментарий'
        $r.Lines | Should -Contain '127.0.0.1 localhost'
        $r.Lines | Should -Contain '0.0.0.0 vortex.data.microsoft.com'
        $r.Lines | Should -Contain "0.0.0.0`tvortex-win.data.microsoft.com"
        $r.Lines | Should -Contain '192.168.1.10 nas.local'
        $r.Lines | Should -Contain '#0.0.0.0 windowsupdate.microsoft.com'
        ($r.Lines -join "`n") | Should -Not -Match '(?m)^0\.0\.0\.0\s+update\.microsoft\.com'
        @(Get-HostsBlockEntries -Lines $r.Lines).Count | Should -Be 0
    }
}

Describe 'Get-BlackholeRoutes' {
    It 'находит маршруты в никуда' {
        $names = @('13.107.4.50,255.255.255.255,0.0.0.0,1', '10.0.0.0,255.0.0.0,192.168.1.1,1', '65.55.44.109,255.255.255.255,127.0.0.1,1', 'мусор')
        $r = @(Get-BlackholeRoutes $names)
        $r.Count | Should -Be 2
        $r[0].Destination | Should -Be '13.107.4.50'
    }
}

Describe 'ConvertFrom-WinHttpSettings' {
    It 'прямой доступ — без прокси' {
        [byte[]]$b = 0x28, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        (ConvertFrom-WinHttpSettings $b).Proxy | Should -BeNullOrEmpty
    }
    It 'читает адрес прокси' {
        $p = [Text.Encoding]::ASCII.GetBytes('10.0.0.1:3128')
        $bp = [Text.Encoding]::ASCII.GetBytes('<local>')
        $list = New-Object Collections.Generic.List[byte]
        $list.AddRange([byte[]](0x28, 0, 0, 0, 5, 0, 0, 0, 3, 0, 0, 0))
        $list.AddRange([BitConverter]::GetBytes([int]$p.Length))
        $list.AddRange($p)
        $list.AddRange([BitConverter]::GetBytes([int]$bp.Length))
        $list.AddRange($bp)
        $r = ConvertFrom-WinHttpSettings $list.ToArray()
        $r.Proxy | Should -Be '10.0.0.1:3128'
        $r.Bypass | Should -Be '<local>'
    }
    It 'пустые данные не ломают разбор' {
        (ConvertFrom-WinHttpSettings $null).Proxy | Should -BeNullOrEmpty
    }
}

Describe 'Прочее' {
    It 'ConvertTo-NativeRegPath' {
        ConvertTo-NativeRegPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' | Should -Be 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        ConvertTo-NativeRegPath 'HKCU:\Software\X\' | Should -Be 'HKCU\Software\X'
    }
    It 'ConvertTo-AccountKey' {
        ConvertTo-AccountKey 'NT AUTHORITY\LocalService' | Should -Be (ConvertTo-AccountKey 'NT Authority\localservice')
        ConvertTo-AccountKey 'LocalSystem' | Should -Be 'localsystem'
    }
    It 'Get-VersionName' {
        Get-VersionName 19045 | Should -Be '22H2'
        Get-VersionName 18363 | Should -Be '1909'
        Get-VersionName 22631 | Should -Be 'Windows 11'
    }
    It 'Get-ScStartMode' {
        Get-ScStartMode 2 $true | Should -Be 'delayed-auto'
        Get-ScStartMode 3 $false | Should -Be 'demand'
    }
    It 'Format-FixList' {
        Format-FixList @('Hosts', 'Hosts', 'Time') | Should -Be 'очистить файл hosts, синхронизировать время'
    }
    It 'у каждой службы в таблице есть имя, группа и тип запуска' {
        foreach ($s in $script:ServiceTable) {
            $s.N | Should -Not -BeNullOrEmpty
            $s.G | Should -BeIn @('WU', 'Core', 'Store', 'Defender')
            $s.S | Should -BeIn @(2, 3)
        }
    }
    It 'условия политик — scriptblock' {
        foreach ($c in $script:PolicyChecks) { $c.Bad | Should -BeOfType [scriptblock] }
        $sb = @($script:PolicyChecks | Where-Object { $_.N -eq 'WUServer' })[0].Bad
        (& $sb 'http://wsus') | Should -BeTrue
        (& $sb '') | Should -BeFalse
    }
}

Describe 'Журналы и рекомендации' {
    It 'Get-EventErrorSummary группирует коды и находит KB' {
        $now = Get-Date
        $ev = @(
            [pscustomobject]@{ Message = 'Сбой установки: 0x80070643 обновление KB5034441'; TimeCreated = $now.AddDays(-1); Properties = @() },
            [pscustomobject]@{ Message = 'Сбой установки: 0x80070643 обновление KB5034441'; TimeCreated = $now; Properties = @() },
            [pscustomobject]@{ Message = 'Windows Update failed to check for updates with error 0x80072EFD.'; TimeCreated = $now.AddDays(-3); Properties = @() },
            [pscustomobject]@{ Message = 'без кода'; TimeCreated = $now; Properties = @([pscustomobject]@{ Value = [int](-2147024894) }) }
        )
        $s = @(Get-EventErrorSummary -Events $ev)
        $s.Count | Should -Be 3
        $first = @($s | Where-Object { $_.Code -eq '0x80070643' })[0]
        $first.Count | Should -Be 2
        $first.Kbs | Should -Contain 'KB5034441'
        @($s | Where-Object { $_.Code -eq '0x80070002' }).Count | Should -Be 1
    }
    It 'Get-EventErrorSummary фильтрует по шаблону' {
        $ev = @([pscustomobject]@{ Message = '0x80073CFF и 0x80070005 Claude'; TimeCreated = (Get-Date); Properties = @() })
        $s = @(Get-EventErrorSummary -Events $ev -CodeFilter '^0x80073[CD]')
        $s.Count | Should -Be 1
        $s[0].Claude | Should -BeTrue
    }
    It 'Get-RecommendedFixes берёт исправления только из ошибок и предупреждений' {
        $f = @(
            (New-Finding 'a' 'ERROR' 'x' 't' '' @('Hosts', 'Proxy') -NoUi),
            (New-Finding 'b' 'WARN' 'x' 't' '' @('Hosts', 'Time') -NoUi),
            (New-Finding 'c' 'INFO' 'x' 't' '' @('DISM') -NoUi),
            (New-Finding 'd' 'OK' 'x' 't' '' @() -NoUi)
        )
        $r = @(Get-RecommendedFixes $f)
        $r | Should -Be @('Hosts', 'Proxy', 'Time')
    }
}

Describe 'Registry.pol (локальная групповая политика)' {
    BeforeAll {
        function New-PolEntry([string]$Key, [string]$Value, [int]$Dword) {
            $u = [Text.Encoding]::Unicode
            $ms = New-Object IO.MemoryStream
            $w = { param([byte[]]$b) $ms.Write($b, 0, $b.Length) }
            & $w $u.GetBytes('[')
            & $w $u.GetBytes($Key + [char]0)
            & $w $u.GetBytes(';')
            & $w $u.GetBytes($Value + [char]0)
            & $w $u.GetBytes(';')
            & $w ([BitConverter]::GetBytes([uint32]4))
            & $w $u.GetBytes(';')
            & $w ([BitConverter]::GetBytes([uint32]4))
            & $w $u.GetBytes(';')
            & $w ([BitConverter]::GetBytes([uint32]$Dword))
            & $w $u.GetBytes(']')
            return ,$ms.ToArray()
        }
        $hdr = [byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0)
        $e1 = New-PolEntry 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
        $e2 = New-PolEntry 'Software\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1
        $e3 = New-PolEntry 'Software\Policies\Microsoft\Windows\WindowsUpdate' 'DisableWindowsUpdateAccess' 1
        $script:PolBytes = [byte[]]($hdr + $e1 + $e2 + $e3)
        $script:PolE2 = $e2
    }
    It 'разбирает записи' {
        $e = @(Get-RegistryPolEntries $script:PolBytes)
        $e.Count | Should -Be 3
        $e[0].Value | Should -Be 'NoAutoUpdate'
        $e[1].Key | Should -Be 'Software\Policies\Microsoft\Windows\Personalization'
    }
    It 'удаляет только запреты обновлений, остальное сохраняет байт в байт' {
        $pairs = @('SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU|NoAutoUpdate', 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|DisableWindowsUpdateAccess')
        $r = Remove-RegistryPolEntries -Bytes $script:PolBytes -Pairs $pairs
        $r.Removed | Should -Be 2
        $left = @(Get-RegistryPolEntries $r.Bytes)
        $left.Count | Should -Be 1
        $left[0].Value | Should -Be 'NoLockScreen'
        $r.Bytes.Length | Should -Be (8 + $script:PolE2.Length)
    }
    It 'повреждённый файл даёт понятную ошибку' {
        { Get-RegistryPolEntries ([byte[]](0x50, 0x52, 0x65, 0x67, 1, 0, 0, 0, 0x41, 0)) } | Should -Throw
        { Get-RegistryPolEntries ([byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9)) } | Should -Throw
    }
}

Describe 'Брандмауэр и резервные копии' {
    It 'шаблон правил брандмауэра ловит блокировщики Windows' {
        foreach ($n in @('WURepairTest Block Windows Update', 'DWS_Block_Telemetry', 'Block Microsoft IPs', 'Windows Update Blocker', 'O&O ShutUp10 rule', 'block_telemetry_1')) {
            $n | Should -Match $script:FirewallSuspectPattern -Because $n
        }
    }
    It 'шаблон не трогает посторонние правила' {
        foreach ($n in @('BlockGoogleUpdate', 'Block Steam', 'Firefox update', 'Kaspersky block', 'Allow DNS', 'TeamViewer')) {
            $n | Should -Not -Match $script:FirewallSuspectPattern -Because $n
        }
    }
    It 'ConvertTo-RegFileText формирует корректный .reg' {
        $vals = @(
            [pscustomobject]@{ Name = 'SusClientId'; Kind = 'String'; Value = 'a\b"c' },
            [pscustomobject]@{ Name = 'Num'; Kind = 'DWord'; Value = -1 },
            [pscustomobject]@{ Name = 'Bin'; Kind = 'Binary'; Value = [byte[]](1, 171) },
            [pscustomobject]@{ Name = 'Exp'; Kind = 'ExpandString'; Value = '%a%' }
        )
        $t = ConvertTo-RegFileText 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate' $vals
        $t | Should -Match '^Windows Registry Editor Version 5\.00'
        $t | Should -Match '\[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\]'
        $t | Should -Match ([regex]::Escape('"SusClientId"="a\\b\"c"'))
        $t | Should -Match '"Num"=dword:ffffffff'
        $t | Should -Match '"Bin"=hex:01,ab'
        $t | Should -Match '"Exp"=hex\(2\):25,00,61,00,25,00,00,00'
    }
}

Describe 'Исходники' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $script:SrcFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -Filter '*.ps1') +
                           @(Get-ChildItem -LiteralPath (Join-Path $root 'build') -Filter '*.ps1') +
                           @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.ps1')
    }
    It 'все .ps1 сохранены в UTF-8 с BOM (иначе Windows PowerShell 5.1 испортит кириллицу)' {
        foreach ($f in $script:SrcFiles) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue -Because $f.Name
        }
    }
    It 'в движке нет строк, начинающихся с одинарного here-string' {
        $root = Split-Path -Parent $PSScriptRoot
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'src/engine') -Filter '*.ps1')) {
            [IO.File]::ReadAllText($f.FullName) | Should -Not -Match "(?m)^'@" -Because $f.Name
        }
    }
    It 'все файлы разбираются без синтаксических ошибок' {
        foreach ($f in $script:SrcFiles) {
            $t = $null; $e = $null
            [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
            $e.Count | Should -Be 0 -Because $f.Name
        }
    }
}
