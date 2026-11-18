<#
    WURepair — ремонт Центра обновления Windows 10
    Окно программы. Вся работа выполняется «движком» (папка engine)
    в фоновом потоке, чтобы окно не зависало.

    Запуск:  START.bat  (или WURepair.exe из релиза)
    Тесты:   . .\src\WURepair.ps1 -NoGui   (загружает только движок)
#>
param([switch]$NoGui)

$ErrorActionPreference = 'Continue'
$EmbeddedEngine = $null
# <<ENGINE>>

# ---------------------------------------------------------------------
#  Загрузка движка
# ---------------------------------------------------------------------
if ($EmbeddedEngine) {
    $script:EngineText = $EmbeddedEngine
} else {
    $base = $PSScriptRoot
    if (-not $base) { $base = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $engineDir = Join-Path $base 'engine'
    $script:EngineText = (@(Get-ChildItem -LiteralPath $engineDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
        [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    }) -join "`r`n")
}
. ([scriptblock]::Create($script:EngineText))

if ($NoGui) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function Show-FatalMessage {
    param([string]$Text)
    [void][Windows.Forms.MessageBox]::Show($Text, 'WURepair', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
}

# ---------------------------------------------------------------------
#  Права администратора и поток STA
# ---------------------------------------------------------------------
$selfPath = $PSCommandPath
if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
$isExe = -not ($selfPath -and $selfPath -like '*.ps1')
$needStaRelaunch = (-not $isExe) -and ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA)
if (-not (Test-IsAdmin) -or $needStaRelaunch) {
    try {
        if ($isExe) {
            $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            Start-Process -FilePath $exe -Verb RunAs -ErrorAction Stop
        } else {
            $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Start-Process -FilePath $psExe -Verb RunAs -ErrorAction Stop -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $selfPath + '"')
        }
    } catch {
        Show-FatalMessage 'Для ремонта Windows нужны права администратора. Запустите программу снова и нажмите «Да» в окне запроса прав.'
    }
    return
}

$script:Mutex = New-Object Threading.Mutex($false, 'Global\WURepair_SingleInstance')
$gotMutex = $false
try { $gotMutex = $script:Mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) {
    Show-FatalMessage 'Программа уже запущена.'
    return
}

Initialize-AppDirs

# ---------------------------------------------------------------------
#  Фоновый поток для движка
# ---------------------------------------------------------------------
$Sync = [hashtable]::Synchronized(@{})
$Sync.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$Sync.AnswerEvent = New-Object Threading.AutoResetEvent($false)
$Sync.UiAttached = $true
$Sync.Findings = @()

$script:Runspace = [runspacefactory]::CreateRunspace()
$script:Runspace.ApartmentState = [Threading.ApartmentState]::STA
$script:Runspace.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
$script:Runspace.Open()
$script:Runspace.SessionStateProxy.SetVariable('Sync', $Sync)
$script:PS = [powershell]::Create()
$script:PS.Runspace = $script:Runspace
[void]$script:PS.AddScript($script:EngineText)
try { [void]$script:PS.Invoke() } catch { Show-FatalMessage ('Не удалось загрузить движок: ' + $_.Exception.Message); return }
if ($script:PS.Streams.Error.Count -gt 0) {
    Show-FatalMessage ('Ошибка при загрузке движка: ' + $script:PS.Streams.Error[0].ToString())
}

$script:Handle = $null
$script:OnDone = $null
$script:Busy = $false
$script:InTick = $false
$script:ActionButtons = @()

# ---------------------------------------------------------------------
#  Окно
# ---------------------------------------------------------------------
$colorAccent = [Drawing.Color]::FromArgb(0, 95, 184)
$colorHeader = [Drawing.Color]::FromArgb(24, 38, 64)
$fontMain = New-Object Drawing.Font('Segoe UI', 9.5)
$fontBold = New-Object Drawing.Font('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
$fontBig = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)

$form = New-Object Windows.Forms.Form
$form.Text = 'WURepair — ремонт Центра обновления Windows 10  (v' + $script:AppVersion + ')'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1180, 760)
$form.MinimumSize = New-Object Drawing.Size(940, 600)
$form.Font = $fontMain
$form.Icon = [Drawing.SystemIcons]::Shield
$form.BackColor = [Drawing.Color]::White
# масштабирование под настройки экрана (125%, 150% …)
$form.SuspendLayout()
$form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi

$tooltip = New-Object Windows.Forms.ToolTip
$tooltip.AutoPopDelay = 20000
$tooltip.InitialDelay = 400

# --- основная область: список проблем + журнал ---
$split = New-Object Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Horizontal'
$split.SplitterWidth = 6
$split.BackColor = [Drawing.Color]::FromArgb(230, 230, 230)

$lv = New-Object Windows.Forms.ListView
$lv.Dock = 'Fill'
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $false
$lv.HideSelection = $false
$lv.MultiSelect = $false
$lv.BorderStyle = 'None'
[void]$lv.Columns.Add('Статус', 90)
[void]$lv.Columns.Add('Раздел', 130)
[void]$lv.Columns.Add('Что найдено', 430)
[void]$lv.Columns.Add('Подробности (двойной щелчок — полностью)', 520)
$split.Panel1.Controls.Add($lv)

$lvTitle = New-Object Windows.Forms.Label
$lvTitle.Text = '  Найденные проблемы'
$lvTitle.Dock = 'Top'
$lvTitle.Height = 24
$lvTitle.Font = $fontBold
$lvTitle.TextAlign = 'MiddleLeft'
$lvTitle.BackColor = [Drawing.Color]::FromArgb(242, 244, 248)
$split.Panel1.Controls.Add($lvTitle)

$log = New-Object Windows.Forms.RichTextBox
$log.Dock = 'Fill'
$log.ReadOnly = $true
$log.BorderStyle = 'None'
$log.BackColor = [Drawing.Color]::FromArgb(250, 250, 250)
$log.Font = New-Object Drawing.Font('Consolas', 9.5)
$log.WordWrap = $true
$log.DetectUrls = $true
$log.Add_LinkClicked({ param($s, $e) try { Start-Process $e.LinkText } catch { } })
$split.Panel2.Controls.Add($log)

$logTitle = New-Object Windows.Forms.Label
$logTitle.Text = '  Журнал работы'
$logTitle.Dock = 'Top'
$logTitle.Height = 24
$logTitle.Font = $fontBold
$logTitle.TextAlign = 'MiddleLeft'
$logTitle.BackColor = [Drawing.Color]::FromArgb(242, 244, 248)
$split.Panel2.Controls.Add($logTitle)

# --- левая панель с кнопками ---
$left = New-Object Windows.Forms.FlowLayoutPanel
$left.Dock = 'Left'
$left.Width = 300
$left.FlowDirection = 'TopDown'
$left.WrapContents = $false
$left.AutoScroll = $true
$left.Padding = New-Object Windows.Forms.Padding(12, 10, 8, 10)
$left.BackColor = [Drawing.Color]::FromArgb(246, 247, 250)

function Add-SectionLabel {
    param([string]$Text)
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $false
    $l.Width = 268
    $l.Height = 26
    $l.TextAlign = 'BottomLeft'
    $l.Font = $fontBold
    $l.ForeColor = [Drawing.Color]::FromArgb(90, 90, 90)
    $l.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 4)
    $left.Controls.Add($l)
}

function Add-ActionButton {
    param([string]$Text, [string]$Tip, [scriptblock]$OnClick, [switch]$Primary)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Width = 268
    $b.TextAlign = 'MiddleLeft'
    $b.Padding = New-Object Windows.Forms.Padding(8, 0, 0, 0)
    $b.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 6)
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $b.Height = 48
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $colorAccent
        $b.ForeColor = [Drawing.Color]::White
        $b.Font = $fontBig
    } else {
        $b.Height = 36
        $b.FlatStyle = 'System'
    }
    $b.Add_Click($OnClick)
    $tooltip.SetToolTip($b, $Tip)
    $left.Controls.Add($b)
    $script:ActionButtons += $b
    return $b
}

# --- шапка ---
$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 78
$header.BackColor = $colorHeader
$hTitle = New-Object Windows.Forms.Label
$hTitle.Text = 'Ремонт Центра обновления Windows 10'
$hTitle.ForeColor = [Drawing.Color]::White
$hTitle.Font = New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)
$hTitle.AutoSize = $true
$hTitle.Location = New-Object Drawing.Point(14, 8)
$header.Controls.Add($hTitle)
$hInfo = New-Object Windows.Forms.Label
$hInfo.Text = 'Определяю версию Windows…'
$hInfo.ForeColor = [Drawing.Color]::FromArgb(205, 215, 235)
$hInfo.AutoSize = $false
$hInfo.Location = New-Object Drawing.Point(16, 44)
$hInfo.Size = New-Object Drawing.Size(1140, 30)
$hInfo.Anchor = 'Top, Left, Right'
$header.Controls.Add($hInfo)

# --- строка состояния ---
$bottom = New-Object Windows.Forms.Panel
$bottom.Dock = 'Bottom'
$bottom.Height = 32
$bottom.BackColor = [Drawing.Color]::FromArgb(242, 244, 248)
$progress = New-Object Windows.Forms.ProgressBar
$progress.Dock = 'Right'
$progress.Width = 280
$progress.Style = 'Continuous'
$progress.Visible = $false
$status = New-Object Windows.Forms.Label
$status.Dock = 'Fill'
$status.TextAlign = 'MiddleLeft'
$status.Padding = New-Object Windows.Forms.Padding(10, 0, 0, 0)
$status.Text = 'Готово к работе. Начните с кнопки «1. Найти проблемы».'
$bottom.Controls.Add($status)
$bottom.Controls.Add($progress)

# порядок добавления важен для Dock: сначала Fill, затем края
$form.Controls.Add($split)
$form.Controls.Add($left)
$form.Controls.Add($header)
$form.Controls.Add($bottom)

# ---------------------------------------------------------------------
#  Вывод в окно
# ---------------------------------------------------------------------
function Add-LogLine {
    param([string]$Level, [string]$Text, [string]$Time)
    if ($Level -eq 'DEBUG' -and -not $env:WUREPAIR_DEBUG) {
        if ($Text -notmatch '^\s{3}') { return }
    }
    if ($log.TextLength -gt 600000) { $log.Select(0, 200000); $log.SelectedText = '' }
    $color = [Drawing.Color]::FromArgb(40, 40, 40)
    $prefix = '   '
    switch ($Level) {
        'OK'    { $color = [Drawing.Color]::FromArgb(0, 128, 60); $prefix = ' √ ' }
        'WARN'  { $color = [Drawing.Color]::FromArgb(176, 96, 0); $prefix = ' ! ' }
        'ERROR' { $color = [Drawing.Color]::FromArgb(200, 30, 30); $prefix = ' × ' }
        'STEP'  { $color = $colorAccent; $prefix = ' » ' }
        'DEBUG' { $color = [Drawing.Color]::FromArgb(130, 130, 130) }
    }
    if (-not $Time) { $Time = Get-Date -Format 'HH:mm:ss' }
    $log.SelectionStart = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor = [Drawing.Color]::FromArgb(150, 150, 150)
    $log.AppendText($Time + ' ')
    $log.SelectionColor = $color
    if ($Level -eq 'STEP') { $log.SelectionFont = New-Object Drawing.Font('Consolas', 9.5, [Drawing.FontStyle]::Bold) }
    $log.AppendText($prefix + $Text + "`n")
    $log.SelectionFont = $log.Font
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
}

$script:SevText = @{ ERROR = 'Ошибка'; WARN = 'Внимание'; INFO = 'Сведения'; OK = 'Норма' }
$script:SevColor = @{
    ERROR = [Drawing.Color]::FromArgb(255, 228, 228)
    WARN  = [Drawing.Color]::FromArgb(255, 243, 214)
    INFO  = [Drawing.Color]::FromArgb(235, 242, 255)
    OK    = [Drawing.Color]::FromArgb(230, 246, 234)
}

function Add-FindingRow {
    param($F)
    $item = New-Object Windows.Forms.ListViewItem($script:SevText[$F.Severity])
    [void]$item.SubItems.Add([string]$F.Category)
    [void]$item.SubItems.Add([string]$F.Title)
    $d = ([string]$F.Detail -replace "\r?\n", ' | ')
    if ($d.Length -gt 300) { $d = $d.Substring(0, 300) + '…' }
    [void]$item.SubItems.Add($d)
    $item.BackColor = $script:SevColor[$F.Severity]
    $item.Tag = $F
    [void]$lv.Items.Add($item)
}

function Show-SortedFindings {
    param([object[]]$Findings)
    $order = @{ ERROR = 0; WARN = 1; INFO = 2; OK = 3 }
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($f in @($Findings | Sort-Object @{ Expression = { $order[$_.Severity] } })) { Add-FindingRow $f }
    $lv.EndUpdate()
}

$lv.Add_DoubleClick({
    if ($lv.SelectedItems.Count -eq 0) { return }
    $f = $lv.SelectedItems[0].Tag
    $text = $f.Title
    if ($f.Detail) { $text += "`r`n`r`n" + $f.Detail }
    if ($f.Fix -and $f.Fix.Count -gt 0) { $text += "`r`n`r`nЧто поможет: " + (Format-FixList $f.Fix) }
    $icon = [Windows.Forms.MessageBoxIcon]::Information
    if ($f.Severity -eq 'ERROR') { $icon = [Windows.Forms.MessageBoxIcon]::Error }
    elseif ($f.Severity -eq 'WARN') { $icon = [Windows.Forms.MessageBoxIcon]::Warning }
    [void][Windows.Forms.MessageBox]::Show($form, $text, $f.Category, [Windows.Forms.MessageBoxButtons]::OK, $icon)
})

function Set-Busy {
    param([bool]$On)
    $script:Busy = $On
    foreach ($b in $script:ActionButtons) { $b.Enabled = -not $On }
    if ($On) {
        $progress.Visible = $true
        $progress.Style = 'Marquee'
        $progress.MarqueeAnimationSpeed = 30
        $form.Cursor = [Windows.Forms.Cursors]::AppStarting
    } else {
        $progress.Visible = $false
        $form.Cursor = [Windows.Forms.Cursors]::Default
    }
}

function Start-EngineTask {
    param([string]$Name, [hashtable]$TaskArgs = @{}, [scriptblock]$OnDone = $null)
    if ($script:Busy) { return }
    Set-Busy $true
    $Sync.TaskName = $Name
    $Sync.TaskArgs = $TaskArgs
    $Sync.Result = $null
    $script:OnDone = $OnDone
    $script:PS.Commands.Clear()
    $script:PS.Streams.ClearStreams()
    [void]$script:PS.AddScript('Invoke-EngineTask')
    $script:Handle = $script:PS.BeginInvoke()
}

function Show-Message {
    param([string]$Text, [string]$Title = 'WURepair', [string]$Icon = 'info')
    $i = [Windows.Forms.MessageBoxIcon]::Information
    if ($Icon -eq 'warn') { $i = [Windows.Forms.MessageBoxIcon]::Warning }
    if ($Icon -eq 'error') { $i = [Windows.Forms.MessageBoxIcon]::Error }
    [void][Windows.Forms.MessageBox]::Show($form, $Text, $Title, [Windows.Forms.MessageBoxButtons]::OK, $i)
}

function Invoke-UiEvent {
    param($Ev)
    $d = $Ev.Data
    switch ($Ev.Type) {
        'log'           { Add-LogLine $d.Level $d.Text $d.Time }
        'status'        { $status.Text = [string]$d }
        'progress'      {
            $p = [int]$d
            if ($p -lt 0) { $progress.Style = 'Marquee' }
            else { $progress.Style = 'Continuous'; $progress.Value = [Math]::Min(100, [Math]::Max(0, $p)) }
        }
        'finding'       { Add-FindingRow $d }
        'clearfindings' { $lv.Items.Clear() }
        'sysinfo'       { $hInfo.Text = (Format-SystemInfo $d) }
        'message'       { Show-Message $d.Text $d.Title $d.Icon }
        'ask'           {
            $res = [Windows.Forms.MessageBox]::Show($form, [string]$d.Text, [string]$d.Title, [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
            $Sync.Answer = ($res -eq [Windows.Forms.DialogResult]::Yes)
            [void]$Sync.AnswerEvent.Set()
        }
        'askfile'       {
            $dlg = New-Object Windows.Forms.OpenFileDialog
            $dlg.Title = [string]$d.Title
            $dlg.Filter = [string]$d.Filter
            $dlg.CheckFileExists = $true
            if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $Sync.Answer = $dlg.FileName } else { $Sync.Answer = $null }
            [void]$Sync.AnswerEvent.Set()
        }
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 120
$timer.Add_Tick({
    if ($script:InTick) { return }
    $script:InTick = $true
    try {
        $ev = $null
        $n = 0
        while ($n -lt 300 -and $Sync.Queue.TryDequeue([ref]$ev)) {
            $n++
            try { Invoke-UiEvent $ev } catch { }
        }
        if ($script:Handle -and $script:Handle.IsCompleted -and $Sync.Queue.IsEmpty) {
            try { [void]$script:PS.EndInvoke($script:Handle) } catch { Add-LogLine 'ERROR' ('Сбой задачи: ' + $_.Exception.Message) $null }
            foreach ($e in $script:PS.Streams.Error) { Add-LogLine 'ERROR' ([string]$e) $null }
            $script:Handle = $null
            Set-Busy $false
            $cb = $script:OnDone
            $script:OnDone = $null
            if ($cb) { try { & $cb $Sync.Result } catch { Add-LogLine 'ERROR' $_.Exception.Message $null } }
        }
    } finally { $script:InTick = $false }
})

# ---------------------------------------------------------------------
#  Диалоги
# ---------------------------------------------------------------------
function Show-UpgradeDialog {
    param($R)
    if (-not $R) { return }
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Обновить Windows поверх (до 22H2)'
    $dlg.StartPosition = 'CenterParent'
    $dlg.Size = New-Object Drawing.Size(720, 560)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = $fontMain
    $dlg.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $dlg.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $txt = New-Object Windows.Forms.RichTextBox
    $txt.ReadOnly = $true
    $txt.BorderStyle = 'None'
    $txt.BackColor = $dlg.BackColor
    $txt.Location = New-Object Drawing.Point(16, 14)
    $txt.Size = New-Object Drawing.Size(672, 300)
    $lines = @()
    $lines += ('Система: ' + (Format-SystemInfo $R.Info))
    $lines += ''
    if ($R.Blockers.Count -gt 0) {
        $lines += 'СЕЙЧАС НЕЛЬЗЯ:'
        foreach ($b in $R.Blockers) { $lines += ('  × ' + $b) }
        $lines += ''
    }
    $lines += 'Важно знать:'
    foreach ($n in $R.Notes) { $lines += ('  • ' + $n) }
    $txt.Text = ($lines -join "`n")
    $dlg.Controls.Add($txt)

    $blocked = ($R.Blockers.Count -gt 0)
    $mk = {
        param([string]$Text, [int]$Y, [string]$Tip)
        $b = New-Object Windows.Forms.Button
        $b.Text = $Text
        $b.Location = New-Object Drawing.Point(16, $Y)
        $b.Size = New-Object Drawing.Size(672, 38)
        $b.TextAlign = 'MiddleLeft'
        $b.Padding = New-Object Windows.Forms.Padding(8, 0, 0, 0)
        $tooltip.SetToolTip($b, $Tip)
        $dlg.Controls.Add($b)
        return $b
    }
    $b1 = & $mk '1) Скачать «Помощник по обновлению» Microsoft и обновиться (проще всего)' 326 'Официальная программа Microsoft: скачает и установит Windows 10 22H2 поверх, сохранив файлы и программы.'
    $b2 = & $mk '2) У меня есть ISO-образ Windows 10 — выбрать файл…' 370 'Подходит, если помощник не работает. Образ можно скачать на сайте Microsoft (кнопка 3) через Media Creation Tool.'
    $b3 = & $mk '3) Открыть страницу загрузки Windows 10 на сайте Microsoft' 414 'Там есть Media Creation Tool: «Создать установочный носитель» → «ISO-файл».'
    $b4 = & $mk 'Отмена' 458 ''
    if ($blocked) { $b1.Enabled = $false; $b2.Enabled = $false }
    if ($R.Info.IsLTSC -or $R.Info.IsEnterprise) { $b1.Enabled = $false }
    $b1.Add_Click({ $f = $this.FindForm(); $f.Tag = 'assistant'; $f.Close() })
    $b2.Add_Click({ $f = $this.FindForm(); $f.Tag = 'media'; $f.Close() })
    $b3.Add_Click({ try { Start-Process $script:Win10DownloadPage } catch { } })
    $b4.Add_Click({ $this.FindForm().Close() })
    [void]$dlg.ShowDialog($form)
    switch ([string]$dlg.Tag) {
        'assistant' { Start-EngineTask 'UpgradeAssistant' }
        'media' {
            $ofd = New-Object Windows.Forms.OpenFileDialog
            $ofd.Title = 'Выберите ISO-образ Windows 10 (или setup.exe на подключённом образе)'
            $ofd.Filter = 'Образ Windows (*.iso;setup.exe)|*.iso;setup.exe|Все файлы (*.*)|*.*'
            if ($ofd.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
                Start-EngineTask 'UpgradeMedia' @{ Path = $ofd.FileName }
            }
        }
    }
}

function Show-RollbackDialog {
    $sessions = @(Get-BackupSessions)
    if ($sessions.Count -eq 0) {
        $r = [Windows.Forms.MessageBox]::Show($form, ('Резервных копий настроек пока нет (они появляются после ремонта).' + "`r`n`r`n" + 'Открыть «Восстановление системы» Windows (точки восстановления)?'), 'Откат', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [Windows.Forms.DialogResult]::Yes) { try { Start-Process (Resolve-SystemExe 'rstrui.exe') } catch { } }
        return
    }
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Откатить изменения'
    $dlg.StartPosition = 'CenterParent'
    $dlg.Size = New-Object Drawing.Size(520, 420)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = $fontMain
    $dlg.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $dlg.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = 'Выберите сеанс ремонта, изменения которого нужно отменить:'
    $lbl.Location = New-Object Drawing.Point(14, 12)
    $lbl.Size = New-Object Drawing.Size(480, 22)
    $dlg.Controls.Add($lbl)
    $lb = New-Object Windows.Forms.ListBox
    $lb.Location = New-Object Drawing.Point(14, 38)
    $lb.Size = New-Object Drawing.Size(476, 230)
    foreach ($s in $sessions) { [void]$lb.Items.Add($s.Name) }
    $lb.SelectedIndex = 0
    $dlg.Controls.Add($lb)
    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'Откатить выбранный сеанс'
    $ok.Location = New-Object Drawing.Point(14, 280)
    $ok.Size = New-Object Drawing.Size(230, 34)
    $ok.Add_Click({ $f = $this.FindForm(); $f.Tag = 'ok'; $f.Close() })
    $dlg.Controls.Add($ok)
    $rs = New-Object Windows.Forms.Button
    $rs.Text = 'Точки восстановления Windows…'
    $rs.Location = New-Object Drawing.Point(260, 280)
    $rs.Size = New-Object Drawing.Size(230, 34)
    $rs.Add_Click({ try { Start-Process (Resolve-SystemExe 'rstrui.exe') } catch { }; $this.FindForm().Close() })
    $dlg.Controls.Add($rs)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Отмена'
    $cancel.Location = New-Object Drawing.Point(14, 326)
    $cancel.Size = New-Object Drawing.Size(476, 30)
    $cancel.Add_Click({ $this.FindForm().Close() })
    $dlg.Controls.Add($cancel)
    [void]$dlg.ShowDialog($form)
    if ([string]$dlg.Tag -eq 'ok' -and $lb.SelectedIndex -ge 0) {
        $path = $sessions[$lb.SelectedIndex].FullName
        Start-EngineTask 'Rollback' @{ Path = $path }
    }
}

# ---------------------------------------------------------------------
#  Кнопки
# ---------------------------------------------------------------------
Add-SectionLabel 'ОСНОВНОЕ — по порядку'
[void](Add-ActionButton '1. Найти проблемы' 'Полная проверка: службы, политики, блокировки (hosts, брандмауэр, маршруты), время, сеть, журналы ошибок, системные файлы, Магазин. Ничего не меняет. 2–6 минут.' {
    Start-EngineTask 'Diagnose' @{} {
        param($r)
        if ($Sync.Findings) { Show-SortedFindings $Sync.Findings }
        if ($r -and $r.Errors -gt 0) {
            Show-Message ('Найдено ошибок: ' + $r.Errors + ', предупреждений: ' + $r.Warnings + '.' + "`r`n`r`n" + 'Нажмите «2. Исправить всё автоматически».' + "`r`n" + '(Двойной щелчок по строке в списке — подробности.)') 'Диагностика' 'warn'
        } elseif ($r) {
            Show-Message ('Серьёзных ошибок не найдено (предупреждений: ' + $r.Warnings + ').' + "`r`n`r`n" + 'Можно сразу нажать «3. Найти и установить обновления».') 'Диагностика' 'info'
        }
    }
} -Primary)
[void](Add-ActionButton '2. Исправить всё автоматически' 'Создаёт точку восстановления и резервные копии, затем исправляет всё найденное: включает службы, убирает запреты и блокировки, сбрасывает Центр обновления. В конце — повторная проверка.' {
    Start-EngineTask 'Repair' @{} {
        param($r)
        if ($Sync.Findings) { Show-SortedFindings $Sync.Findings }
        if (-not $r) { return }
        $t = 'Ремонт завершён.' + "`r`n`r`n"
        if ($r.Done.Count) { $t += 'Исправлено: ' + ($r.Done -join ', ') + "`r`n" }
        if ($r.Failed.Count) { $t += 'Не до конца: ' + ($r.Failed -join ', ') + "`r`n" }
        $t += "`r`nОсталось ошибок: " + $r.Remaining
        if ($r.Remaining -eq 0) { $t += "`r`n`r`nТеперь нажмите «3. Найти и установить обновления»." }
        elseif ($r.Fixes -contains 'InPlace') { $t += "`r`n`r`nОставшиеся проблемы надёжно решает «Обновить Windows поверх»." }
        elseif ($r.Fixes -contains 'Reboot') { $t += "`r`n`r`nПерезагрузите компьютер и запустите проверку ещё раз." }
        Show-Message $t 'Ремонт' 'info'
    }
} -Primary)
[void](Add-ActionButton '3. Найти и установить обновления' 'Ищет, скачивает и устанавливает обновления Windows прямо из программы (даже если окно «Центр обновления» в Параметрах не открывается).' {
    Start-EngineTask 'Install'
} -Primary)

Add-SectionLabel 'ПРОГРАММЫ И КОМПОНЕНТЫ'
[void](Add-ActionButton 'Установить Claude Desktop' 'Проверяет, подходит ли Windows (нужна 2004+, сборка 19041), исправляет препятствия, скачивает официальный пакет с claude.ai и устанавливает.' {
    Start-EngineTask 'Claude'
})
[void](Add-ActionButton 'Вернуть Microsoft Store' 'Восстанавливает Магазин: из оставшихся файлов, встроенной переустановкой или через официальный «Установщик приложений» (winget).' {
    Start-EngineTask 'Store'
})
[void](Add-ActionButton 'Вернуть Защитник Windows' 'Снимает запреты Защитника, восстанавливает его службы и приложение «Безопасность Windows». При работающем Касперском/ESET/Dr.Web Защитник останется выключенным — так и должно быть.' {
    Start-EngineTask 'Defender'
})

Add-SectionLabel 'ЕСЛИ НЕ ПОМОГЛО'
[void](Add-ActionButton 'Глубокое восстановление (DISM + SFC)' 'Восстанавливает повреждённые системные файлы и хранилище компонентов. 20–60 минут.' {
    $r = [Windows.Forms.MessageBox]::Show($form, 'Запустить глубокое восстановление DISM + SFC? Это займёт 20–60 минут; компьютер выключать нельзя.', 'Глубокое восстановление', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
    if ($r -eq [Windows.Forms.DialogResult]::Yes) { Start-EngineTask 'DeepRepair' }
})
[void](Add-ActionButton 'Обновить Windows поверх (до 22H2)' 'Самый надёжный способ: переустановка поверх с официального образа Microsoft. Файлы и программы сохраняются, удалённые компоненты (Магазин, Защитник, службы) возвращаются.' {
    Start-EngineTask 'UpgradeCheck' @{} { param($r) Show-UpgradeDialog $r }
})
[void](Add-ActionButton 'Освободить место на диске' 'Удаляет временные файлы, старые копии обновлений и (по желанию) устаревшие компоненты Windows.' {
    Start-EngineTask 'Disk'
})

Add-SectionLabel 'СЕРВИС'
[void](Add-ActionButton 'Сохранить отчёт' 'Сохраняет на Рабочий стол текстовый отчёт со всеми найденными проблемами и журналом — его можно отправить тому, кто помогает с ремонтом.' {
    Start-EngineTask 'Report'
})
[void](Add-ActionButton 'Откатить изменения' 'Возвращает настройки, изменённые программой, из резервной копии (или открывает точки восстановления Windows).' {
    Show-RollbackDialog
})
[void](Add-ActionButton 'Открыть «Центр обновления»' 'Открывает стандартное окно Параметры → Обновление и безопасность.' {
    try { Start-Process 'ms-settings:windowsupdate' } catch { Show-Message 'Не удалось открыть Параметры.' 'WURepair' 'warn' }
})
[void](Add-ActionButton 'Открыть папку программы' ('Журналы, отчёты, резервные копии и загрузки: ' + $script:RootDir) {
    try { Start-Process 'explorer.exe' $script:RootDir } catch { }
})

# ---------------------------------------------------------------------
#  Запуск
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#  Смоук-тест для CI: диагностика без вопросов → скриншот → выход
# ---------------------------------------------------------------------
function Save-Screenshot {
    param([string]$Path)
    $form.Activate()
    [Windows.Forms.Application]::DoEvents()
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($form.Location, [Drawing.Point]::Empty, $form.Size) }
    catch { $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height))) }
    $g.Dispose()
    $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $alt = [IO.Path]::ChangeExtension($Path, '.drawtobitmap.png')
    $bmp2 = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp2, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp2.Save($alt, [Drawing.Imaging.ImageFormat]::Png)
    $bmp2.Dispose()
}

function Start-SmokeTest {
    $form.TopMost = $true
    $script:SmokeGuard = New-Object Windows.Forms.Timer
    $script:SmokeGuard.Interval = 540000
    $script:SmokeGuard.Add_Tick({ $script:SmokeGuard.Stop(); $script:Busy = $false; $form.Close() })
    $script:SmokeGuard.Start()
    Start-EngineTask 'Diagnose' @{ SkipScan = $true } {
        param($r)
        if ($Sync.Findings) { Show-SortedFindings $Sync.Findings }
        $script:SmokeShot = New-Object Windows.Forms.Timer
        $script:SmokeShot.Interval = 1500
        $script:SmokeShot.Add_Tick({
            $script:SmokeShot.Stop()
            try { Save-Screenshot $env:WUREPAIR_SMOKE } catch { Add-LogLine 'ERROR' ('Скриншот: ' + $_.Exception.Message) $null }
            $form.Close()
        })
        $script:SmokeShot.Start()
    }
}

$form.Add_Shown({
    $split.SplitterDistance = [int]($split.Height * 0.48)
    Add-LogLine 'STEP' ('WURepair ' + $script:AppVersion + ' — ремонт Центра обновления Windows 10') $null
    Add-LogLine 'INFO' 'Порядок работы:' $null
    Add-LogLine 'INFO' '  1) «Найти проблемы» — программа проверит систему и покажет, что сломано (ничего не меняя).' $null
    Add-LogLine 'INFO' '  2) «Исправить всё автоматически» — перед изменениями создаётся точка восстановления и копии настроек.' $null
    Add-LogLine 'INFO' '  3) «Найти и установить обновления».' $null
    Add-LogLine 'INFO' 'Если не поможет — «Обновить Windows поверх» (файлы и программы сохраняются).' $null
    Add-LogLine 'INFO' ('Журналы и резервные копии: ' + $script:RootDir) $null
    Add-LogLine 'INFO' 'Программа не изменяет и не обходит активацию Windows.' $null
    $timer.Start()
    if ($env:WUREPAIR_SMOKE) { Start-SmokeTest } else { Start-EngineTask 'SysInfo' }
})

$form.Add_FormClosing({
    param($s, $e)
    if ($script:Busy) {
        $r = [Windows.Forms.MessageBox]::Show($form, 'Операция ещё выполняется. Если закрыть программу сейчас, ремонт прервётся (DISM/установка обновлений могут продолжиться в фоне).' + "`r`n`r`nЗакрыть всё равно?", 'WURepair', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
    }
    $timer.Stop()
    $Sync.UiAttached = $false
    $Sync.Answer = $false
    try { [void]$Sync.AnswerEvent.Set() } catch { }
    try { [void]$script:PS.BeginStop($null, $null) } catch { }
})

$form.ResumeLayout($true)
try {
    [Windows.Forms.Application]::Run($form)
} finally {
    try { $script:PS.Dispose() } catch { }
    try { $script:Runspace.Dispose() } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
}
