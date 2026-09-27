<#
    mtr-windows-settings.ps1  (PORTABLE edition)

    Standardises Windows shell, power and desktop settings on client MTR NUCs.
    Run elevated as the ADMIN account - the HKCU settings apply only to the
    account that runs it, not to the Skype/MTR auto-logon account.

    Runs entirely from the USB stick and assumes no network access to anything
    else: the wallpaper comes from .\assets and the installers from
    .\assets\Software, and the per-host report is written to .\logs on the stick as well as
    Downloads\_mtrsetup on the MTR.

    Usage:  run-mtr_setup.bat            (or, from an elevated prompt:
            powershell.exe -ExecutionPolicy Bypass -File .\mtr-windows-settings.ps1)
#>

# NOTE: there is no default VNC password. Pass -VncPassword, or put it on the first
#       line of vnc-password.txt next to this script (git-ignored). It is used for
#       both the viewer and admin passwords, and is set on
#       every MTR TightVNC is freshly installed on.
param(
    [string]$VncPassword       = '',   # VNC auth honours 8 chars max
    [string]$AssetsRoot        = (Join-Path $PSScriptRoot 'assets'),
    [string]$SourceFile        = (Join-Path $AssetsRoot 'AV-OOS-BG-Blue.png'),
    [string]$TempFolderName    = '_mtrsetup',
    [string]$SoftwareFolderName = 'Software',
    [string]$InstallersRoot    = (Join-Path $AssetsRoot 'Software'),
    [string]$ExtronMtrZip      = (Join-Path $InstallersRoot 'Extron\ExtronControlforMicrosoftTeamsRooms_2x5x1.zip'),
    [string]$ExtronMsiName     = 'ExtronControlforMicrosoftTeamsRooms.msi',
    [string]$LogiSyncExe       = (Join-Path $InstallersRoot 'Logitech\LogiSyncApp-Setup.exe'),
    [string]$VncMsi            = (Join-Path $InstallersRoot 'TightVNC\tightvnc-2.8.85-gpl-setup-64bit.msi'),
    [string]$FirefoxMsi        = (Join-Path $InstallersRoot 'Firefox\Firefox Setup 140.16.0esr.msi'),
    [string]$SevenZipMsi       = (Join-Path $InstallersRoot '7-Zip\7z2501-x64.msi'),
    # The Splashtop deploy installer reads the team's deployment code from its own filename - never rename it.
    # Any Splashtop_Streamer_Windows_DEPLOY_INSTALLER_*.exe in assets\Software\Splashtop is used.
    [string]$SplashtopExe      = $(
        $found = Get-ChildItem -Path (Join-Path $InstallersRoot 'Splashtop') -Filter 'Splashtop_Streamer_Windows_DEPLOY_INSTALLER_*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $found.FullName } else { Join-Path $InstallersRoot 'Splashtop\Splashtop_Streamer_Windows_DEPLOY_INSTALLER_VERSION_CODE.exe' }
    ),
    [string]$MmcFile           = (Join-Path $AssetsRoot 'MTR-MMC-Local.msc'),
    [string]$LogFolder         = (Join-Path $PSScriptRoot 'logs'),
    [int]$DisplayTimeoutMinutes = 20,   # display off after (0 = never); also picked in the setup prompt, this is its default
    [string[]]$Install,          # skip the software prompt and install only these, e.g. -Install Extron,TightVNC (matches the start of the name)
    [switch]$NoPrompt,           # skip the software prompt and install the default selection (see $UntickedByDefault)
    [string]$NewHostname,        # if the PC still has a Windows default name (DESKTOP-xxxxxxx), rename it to this without asking
    [int]$PromptSeconds = 60,    # the prompts carry on with their defaults after this long if nobody touches them
    [switch]$Debug   # extra [diag] console lines for things like the MSI ProductCode lookup
)

# Bump on every change to this file, format YYYY.MM.DD-NNN.
$ScriptVersion = '2026.09.27-001'

$ErrorActionPreference = 'Continue'

# VNC password: -VncPassword, else the first line of vnc-password.txt next to this
# script. Only needed when TightVNC is installed fresh.
if (-not $VncPassword) {
    $vncPasswordFile = Join-Path $PSScriptRoot 'vnc-password.txt'
    if (Test-Path $vncPasswordFile) { $VncPassword = "$(Get-Content -Path $vncPasswordFile -TotalCount 1)".Trim() }
}

Write-Host "mtr-windows-settings.ps1 v$ScriptVersion (portable)`n" -ForegroundColor Cyan

$script:Results = @()
$script:Section = ''
$script:RestartReasons = @()   # why a restart is needed, added to as the run goes; the launcher restarts instead of logging off when non-empty

function Add-Result {
    param($Name, $Value, $Status = 'OK', $Detail = '')
    $script:Results += [pscustomobject]@{
        Section = $script:Section
        Setting = $Name
        Value   = "$Value"
        Status  = $Status
        Detail  = $Detail
    }
}

# Section banner - also tags every Add-Result that follows.
function Write-Section {
    param($Number, $Title)
    $script:Section = $Title
    Write-Host "`n[$Number] $Title" -ForegroundColor Cyan
}

function Set-Reg {
    param($Path, $Name, $Value, $Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Write-Host ("  {0,-42} = {1}" -f $Name, $Value)
        Add-Result $Name $Value 'OK' $Path
    }
    catch {
        Write-Host ("  {0,-42} = {1}   FAILED: {2}" -f $Name, $Value, $_.Exception.Message) -ForegroundColor Red
        Add-Result $Name $Value 'FAILED' "$Path - $($_.Exception.Message)"
    }
}

# Apply one powercfg setting on both AC and DC. Values are staged into the
# stored scheme; the caller must run /setactive to apply them.
function Set-PowerValue {
    param($Scheme, $Label, $SubGroup, $Setting, $Value)
    $out  = @()
    $out += & powercfg /setacvalueindex $Scheme $SubGroup $Setting $Value
    $acOk = ($LASTEXITCODE -eq 0)
    $out += & powercfg /setdcvalueindex $Scheme $SubGroup $Setting $Value
    $dcOk = ($LASTEXITCODE -eq 0)

    if ($acOk -and $dcOk) {
        Write-Host ("  {0,-42} = {1}" -f $Label, $Value)
        Add-Result $Label $Value 'OK' "$SubGroup / $Setting (AC+DC)"
    } else {
        $msg = (($out | Where-Object { $_ }) -join ' ').Trim()
        Write-Host ("  {0,-42} = {1}   FAILED: {2}" -f $Label, $Value, $msg) -ForegroundColor Red
        Add-Result $Label $Value 'FAILED' "$SubGroup / $Setting - $msg"
    }
}

$Advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

$SoftwareChoices = @('Extron Control', 'Logitech Sync', 'TightVNC', 'Firefox ESR', '7-Zip', 'Splashtop Streamer') | Sort-Object   # order shown in the prompt

# Splashtop Streamer starts unticked everywhere, and Yealink MTRs also start with
# Extron Control and Logitech Sync unticked. Everything is still in the list and
# can be ticked; the default selection is also what -NoPrompt and an untouched
# prompt go with, so an unticked item is not installed.
$maker = try { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer } catch { '' }
$UntickedByDefault = @('Splashtop Streamer')
if ($maker -like '*Yealink*') { $UntickedByDefault += @('Extron Control', 'Logitech Sync') }
$DefaultSelection = @($SoftwareChoices | Where-Object { $UntickedByDefault -notcontains $_ })

# Version for comparisons: four fields, padded with zeros, so "25.01" and
# "25.01.00.0" compare equal.
function ConvertTo-PaddedVersion {
    param([string]$Text)
    $parts = @($Text -split '\.' | Select-Object -First 4)
    while ($parts.Count -lt 4) { $parts += '0' }
    [version]($parts -join '.')
}

# Everything that says a restart is pending: what this run recorded plus
# Windows' own markers (servicing, Windows Update, a renamed computer, files
# waiting to be replaced).
function Get-PendingRestartReasons {
    $reasons = @($script:RestartReasons)
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Windows servicing update' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $set    = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $set -and $active -ne $set) { $reasons += 'hostname change' }
    if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $reasons += 'files to replace on restart' }
    @($reasons | Select-Object -Unique)
}

# Setup prompt: tick-boxes for which software to install, plus how long before
# the display turns off. Shown once, up front, so a tech can choose and walk
# away: if nobody touches it, it carries on with the ticked items and the
# current display value after $Seconds. "Skip installs" or closing the window
# installs nothing but still applies the display setting. Returns an object
# with Software (the ticked names) and DisplayTimeoutMinutes (0 = never).
function Show-SetupPrompt {
    param([string[]]$Choices, [string[]]$Unticked = @(), [int]$DisplayMinutes, [int]$Seconds)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'MTR setup'
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.TopMost         = $true
    $form.ClientSize      = New-Object System.Drawing.Size(340, 290)

    $heading          = New-Object System.Windows.Forms.Label
    $heading.Text     = 'Tick what to install on this MTR:'
    $heading.Location = New-Object System.Drawing.Point(16, 14)
    $heading.AutoSize = $true

    $list              = New-Object System.Windows.Forms.CheckedListBox
    $list.CheckOnClick = $true
    $list.Location     = New-Object System.Drawing.Point(16, 40)
    $list.Size         = New-Object System.Drawing.Size(308, 118)
    foreach ($c in $Choices) { [void]$list.Items.Add($c, ($Unticked -notcontains $c)) }

    $offLabel          = New-Object System.Windows.Forms.Label
    $offLabel.Text     = 'Turn display off after:'
    $offLabel.Location = New-Object System.Drawing.Point(16, 172)
    $offLabel.AutoSize = $true

    # 0 = never. A value passed with -DisplayTimeoutMinutes that isn't in the
    # usual list is added, so it is never silently changed.
    $offValues = @(0, 1, 3, 5, 10, 15, 20, 30, 45, 60)
    if ($offValues -notcontains $DisplayMinutes) { $offValues = @(($offValues + $DisplayMinutes) | Sort-Object) }
    $off               = New-Object System.Windows.Forms.ComboBox
    $off.DropDownStyle = 'DropDownList'
    $off.Location      = New-Object System.Drawing.Point(158, 168)
    $off.Size          = New-Object System.Drawing.Size(166, 24)
    foreach ($v in $offValues) {
        $text = if ($v -eq 0) { 'Never' } elseif ($v -eq 1) { '1 minute' } else { "$v minutes" }
        [void]$off.Items.Add($text)
    }
    $off.SelectedIndex = [array]::IndexOf($offValues, $DisplayMinutes)

    $countdown          = New-Object System.Windows.Forms.Label
    $countdown.Location = New-Object System.Drawing.Point(16, 208)
    $countdown.Size     = New-Object System.Drawing.Size(308, 20)

    $ok              = New-Object System.Windows.Forms.Button
    $ok.Text         = 'Continue'
    $ok.Location     = New-Object System.Drawing.Point(122, 246)
    $ok.Size         = New-Object System.Drawing.Size(92, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancel              = New-Object System.Windows.Forms.Button
    $cancel.Text         = 'Skip installs'
    $cancel.Location     = New-Object System.Drawing.Point(222, 246)
    $cancel.Size         = New-Object System.Drawing.Size(102, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $form.Controls.AddRange(@($heading, $list, $offLabel, $off, $countdown, $ok, $cancel))

    $script:promptLeft = $Seconds
    $countdown.Text    = "Carrying on with these settings in $($script:promptLeft)s..."
    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:promptLeft--
        if ($script:promptLeft -le 0) {
            $timer.Stop()
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } else {
            $countdown.Text = "Carrying on with these settings in $($script:promptLeft)s..."
        }
    })
    # Any change means someone is at the keyboard - stop the auto-continue.
    $list.Add_ItemCheck({ $timer.Stop(); $countdown.Text = '' })
    $off.Add_SelectedIndexChanged({ $timer.Stop(); $countdown.Text = '' })
    $timer.Start()

    $result  = $form.ShowDialog()
    $timer.Dispose()
    $checked = @($list.CheckedItems | ForEach-Object { "$_" })
    $minutes = $offValues[$off.SelectedIndex]
    $form.Dispose()
    $picked = @()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $picked = $checked }
    [pscustomobject]@{ Software = $picked; DisplayTimeoutMinutes = $minutes }
}

# Windows names a fresh PC DESKTOP-xxxxxxx. If that is still the name, ask for
# a proper one and rename. A rename only takes effect after the next restart.
$DefaultNamePattern = '^DESKTOP-[A-Z0-9]{6,7}$'

# NetBIOS-safe: 1-15 letters/digits/hyphens, no leading or trailing hyphen, not
# all digits, and not another Windows default name.
function Test-HostnameValid {
    param([string]$Name)
    ($Name -match '^(?!-)(?!\d+$)[A-Za-z0-9-]{1,15}(?<!-)$') -and ($Name -notmatch $DefaultNamePattern)
}

# Asks for a new hostname. Returns the name, or $null to leave it alone (Keep
# current name, closing the window, or nobody typing anything for $Seconds).
function Read-NewHostname {
    param([string]$Current, [int]$Seconds)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'MTR setup - hostname'
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.TopMost         = $true
    $form.ClientSize      = New-Object System.Drawing.Size(360, 214)

    $info          = New-Object System.Windows.Forms.Label
    $info.Text     = "This PC still has the default Windows name ($Current). Enter a new hostname:"
    $info.Location = New-Object System.Drawing.Point(16, 14)
    $info.Size     = New-Object System.Drawing.Size(328, 36)

    $box           = New-Object System.Windows.Forms.TextBox
    $box.Location  = New-Object System.Drawing.Point(16, 58)
    $box.Size      = New-Object System.Drawing.Size(328, 24)
    $box.MaxLength = 15

    $err           = New-Object System.Windows.Forms.Label
    $err.Text      = 'Letters, numbers and hyphens, up to 15 characters.'
    $err.Location  = New-Object System.Drawing.Point(16, 90)
    $err.Size      = New-Object System.Drawing.Size(328, 36)

    $countdown          = New-Object System.Windows.Forms.Label
    $countdown.Location = New-Object System.Drawing.Point(16, 132)
    $countdown.Size     = New-Object System.Drawing.Size(328, 20)

    $rename          = New-Object System.Windows.Forms.Button
    $rename.Text     = 'Rename'
    $rename.Location = New-Object System.Drawing.Point(96, 170)
    $rename.Size     = New-Object System.Drawing.Size(110, 28)

    $keep              = New-Object System.Windows.Forms.Button
    $keep.Text         = 'Keep current name'
    $keep.Location     = New-Object System.Drawing.Point(214, 170)
    $keep.Size         = New-Object System.Drawing.Size(130, 28)
    $keep.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $form.AcceptButton = $rename
    $form.CancelButton = $keep
    $form.Controls.AddRange(@($info, $box, $err, $countdown, $rename, $keep))

    $script:chosenHostname = $null
    $rename.Add_Click({
        $name = $box.Text.Trim()
        if (Test-HostnameValid $name) {
            $script:chosenHostname = $name
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } else {
            $err.Text = 'Not valid: letters, numbers and hyphens only, up to 15 characters, not all digits, and not another DESKTOP-xxxxxxx name.'
        }
    })

    $script:hostnameLeft = $Seconds
    $countdown.Text      = "Keeping the current name in $($script:hostnameLeft)s..."
    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:hostnameLeft--
        if ($script:hostnameLeft -le 0) {
            $timer.Stop()
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            $form.Close()
        } else {
            $countdown.Text = "Keeping the current name in $($script:hostnameLeft)s..."
        }
    })
    # Typing means someone is at the keyboard - stop the countdown.
    $box.Add_TextChanged({ $timer.Stop(); $countdown.Text = '' })
    $timer.Start()

    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()
    return $script:chosenHostname
}

Write-Section 0 "Hostname"
$currentHost    = $env:COMPUTERNAME
$ReportHost     = $currentHost
$hostChangeNote = $null
if ($currentHost -notmatch $DefaultNamePattern) {
    Write-Host ("  {0,-42} = {1}" -f 'Hostname', $currentHost)
    Add-Result 'Hostname' $currentHost 'OK' 'not a Windows default name - left as is'
}
else {
    $newName = $NewHostname
    if (-not $newName -and -not $NoPrompt) {
        try { $newName = Read-NewHostname -Current $currentHost -Seconds $PromptSeconds }
        catch { Write-Warning "Could not show the hostname prompt ($($_.Exception.Message))" }
    }
    if (-not $newName) {
        Write-Host ("  {0,-42} = {1} (still the Windows default, left as is)" -f 'Hostname', $currentHost) -ForegroundColor Yellow
        Add-Result 'Hostname' $currentHost 'SKIP' 'still the Windows default - no new name entered'
    }
    elseif (-not (Test-HostnameValid $newName)) {
        Write-Host ("  {0,-42} = FAILED: '{1}' is not a valid hostname" -f 'Hostname', $newName) -ForegroundColor Red
        Add-Result 'Hostname' $newName 'FAILED' 'not valid: letters, numbers, hyphens; 1-15 characters; not all digits'
    }
    else {
        try {
            Rename-Computer -NewName $newName -Force -WarningAction SilentlyContinue -ErrorAction Stop
            $ReportHost     = $newName
            $hostChangeNote = "$currentHost -> $newName"
            $script:RestartReasons += 'hostname change'
            Write-Host ("  {0,-42} = {1} (takes effect after a restart)" -f 'Hostname', $hostChangeNote) -ForegroundColor Green
            Add-Result 'Hostname' $hostChangeNote 'OK' 'takes effect after a restart'
        }
        catch {
            Write-Host ("  {0,-42} = FAILED: {1}" -f 'Hostname', $_.Exception.Message) -ForegroundColor Red
            Add-Result 'Hostname' $newName 'FAILED' $_.Exception.Message
        }
    }
}

$selected = @($DefaultSelection)
if ($Install) {
    $selected = @($SoftwareChoices | Where-Object { $c = $_; @($Install | Where-Object { $c -like "$_*" }).Count })
}
elseif (-not $NoPrompt) {
    try {
        $choice = Show-SetupPrompt -Choices $SoftwareChoices -Unticked $UntickedByDefault -DisplayMinutes $DisplayTimeoutMinutes -Seconds $PromptSeconds
        $selected = @($choice.Software)
        $DisplayTimeoutMinutes = $choice.DisplayTimeoutMinutes
    }
    catch { Write-Warning "Could not show the setup prompt ($($_.Exception.Message)) - going with the default software selection" }
}
$doExtron = $selected -contains 'Extron Control'
$doLogi   = $selected -contains 'Logitech Sync'
$doVnc    = $selected -contains 'TightVNC'
$doFirefox = $selected -contains 'Firefox ESR'
$do7zip    = $selected -contains '7-Zip'
$doSplash  = $selected -contains 'Splashtop Streamer'


# ---------------------------------------------------------------------------
# 1. PERSONALIZATION > START
# ---------------------------------------------------------------------------
Write-Section 1 "Start menu"

Set-Reg $Advanced 'Start_TrackDocs'            0   # recommended + recent files + jump lists
Set-Reg $Advanced 'Start_IrisRecommendations'  0   # tips, shortcuts, new apps
Set-Reg $Advanced 'Start_TrackProgs'           0   # most used apps
Set-Reg $Advanced 'Start_AccountNotifications' 0

# Folders shown next to the Power button. This build does not read the
# classic per-user values (Start_Show*, tested above) or the HKLM GPO
# equivalent (AllowPinnedFolder*) - both write cleanly and are ignored,
# survives a full logoff/logon. The Settings app is also UWP-hosted
# (ApplicationFrameHost owns the window, not SystemSettings.exe), so this
# drives the toggle directly via UI Automation instead of the registry.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

$StartFolderIds = @{
    'Settings'  = 'SystemSettings_Start_PlacesSettings_ToggleSwitch'
    'Downloads' = 'SystemSettings_Start_PlacesDownloads_ToggleSwitch'
}

function Get-SettingsWindow {
    $proc = Get-Process -Name 'ApplicationFrameHost' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq 'Settings' } |
            Select-Object -First 1
    if ($proc) { return [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle) }
    return $null
}

# Invoke where supported, fall back to selecting - WinUI list items on the
# Settings nav pages support SelectionItemPattern rather than Invoke.
function Invoke-AutomationElement {
    param($Element)
    try {
        $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    catch {
        $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
}

# Names (and AutomationIds) of what the Settings window currently exposes, for
# failure messages - element names differ between Windows builds.
function Get-SettingsSeen {
    param($Root, [int]$Max = 120)
    $names = @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
               ForEach-Object {
                   $t = $_.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
                   $n = $_.Current.Name
                   $id = $_.Current.AutomationId
                   if ($n -or $id) { if ($id) { "$t '$n' [$id]" } else { "$t '$n'" } }
               } |
               Select-Object -Unique -First $Max)
    return ($names -join '; ')
}

# The "Folders" row on Personalization > Start: a group (AutomationId below) holding
# the clickable button. The button's own name varies between builds (plain
# "Folders", "Folders <description>", or none), so match the group by id or name
# and return whichever of the row / its button can be invoked.
function Find-StartFoldersRow {
    param($Root)
    $descendants = [System.Windows.Automation.TreeScope]::Descendants
    $isInvokable = [System.Windows.Automation.AutomationElement]::IsInvokePatternAvailableProperty
    $rows = @($Root.FindAll($descendants, [System.Windows.Automation.Condition]::TrueCondition) |
              Where-Object { $_.Current.AutomationId -eq 'SystemSettings_Start_LinkToPlacesPage_ButtonEntityItem' -or
                             $_.Current.Name -eq 'Folders' -or $_.Current.Name -like 'Folders *' })
    foreach ($row in $rows) {
        if ($row.GetCurrentPropertyValue($isInvokable)) { return $row }
        $inner = $row.FindFirst($descendants, (New-Object System.Windows.Automation.PropertyCondition($isInvokable, $true)))
        if ($inner) { return $inner }
    }
    return $null
}

# Scroll every vertically scrollable region to its end. Rows below the fold may
# not exist in the automation tree until they have been scrolled towards.
function Move-SettingsPageToEnd {
    param($Root)
    $scrollable = [System.Windows.Automation.AutomationElement]::IsScrollPatternAvailableProperty
    $regions = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($scrollable, $true)))
    foreach ($region in $regions) {
        try {
            $sp = $region.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
            if ($sp.Current.VerticallyScrollable) { $sp.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll, 100) }
        } catch { }
    }
}

$startFoldersRoot = $null
$foldersPageOpened = $false
try {
    # ms-settings: URI activation (Start-Process 'ms-settings:...') is
    # intercepted by the Teams Rooms shell on this hardware - confirmed
    # on-device: even right-click desktop > Display settings, which also
    # fires via ms-settings:, shows the same brief purple Teams splash
    # instead of opening Settings. Opening Settings from the Start menu
    # (like a human has to on this image) avoids the URI entirely.
    [System.Windows.Forms.SendKeys]::SendWait('^{ESC}')
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait('Settings')
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait('~')

    for ($i = 0; $i -lt 40 -and -not $startFoldersRoot; $i++) {
        Start-Sleep -Milliseconds 500
        $startFoldersRoot = Get-SettingsWindow
    }
    if (-not $startFoldersRoot) { throw "Settings window did not appear" }

    # On some builds (seen on Windows 11 23H2) Settings opens in a window narrow
    # enough that the left nav collapses into an "Open Navigation" button and
    # Personalization is not in the tree at all. Maximise it first so the nav is
    # expanded; if it is still collapsed, open it below.
    try { $startFoldersRoot.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Maximized) } catch { }
    Start-Sleep -Milliseconds 800

    # Click through Personalization -> Start by hand, since the ms-settings:
    # deep link that would have jumped straight there is exactly what's
    # being intercepted.
    $personalizationCond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)),
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Personalization'))
    )
    $personalizationItem = $null
    for ($i = 0; $i -lt 20 -and -not $personalizationItem; $i++) {
        Start-Sleep -Milliseconds 500
        $personalizationItem = $startFoldersRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $personalizationCond)
    }
    if (-not $personalizationItem) {
        $navCond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Open Navigation'))
        )
        # The button reads "Open Navigation" only while the pane is closed, so if
        # the pane shut again (or the click didn't take) it is found and clicked again.
        for ($attempt = 0; $attempt -lt 3 -and -not $personalizationItem; $attempt++) {
            $navButton = $startFoldersRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $navCond)
            if ($navButton) { Invoke-AutomationElement $navButton }
            for ($i = 0; $i -lt 6 -and -not $personalizationItem; $i++) {
                Start-Sleep -Milliseconds 500
                $personalizationItem = $startFoldersRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $personalizationCond)
            }
        }
    }
    if (-not $personalizationItem) {
        throw "Could not find Personalization in the Settings nav. Settings showed: $(Get-SettingsSeen $startFoldersRoot)"
    }
    Invoke-AutomationElement $personalizationItem

    $startItemCond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)),
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Start'))
    )
    $startItem = $null
    for ($i = 0; $i -lt 20 -and -not $startItem; $i++) {
        Start-Sleep -Milliseconds 500
        $startItem = $startFoldersRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $startItemCond)
    }
    if (-not $startItem) { throw "Could not find Start in the Personalization list. Settings showed: $(Get-SettingsSeen $startFoldersRoot)" }
    Invoke-AutomationElement $startItem
    Start-Sleep -Milliseconds 500

    $foldersRow = $null
    for ($i = 0; $i -lt 20 -and -not $foldersRow; $i++) {
        Start-Sleep -Milliseconds 500
        $foldersRow = Find-StartFoldersRow $startFoldersRoot
        if (-not $foldersRow -and $i -eq 4) { Move-SettingsPageToEnd $startFoldersRoot }
    }
    if (-not $foldersRow) { throw "Could not find the Folders row on the Start page. Settings showed: $(Get-SettingsSeen $startFoldersRoot)" }
    $foldersRow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $foldersPageOpened = $true
    Start-Sleep -Seconds 1
}
catch {
    Write-Host ("  {0,-42} = FAILED: {1}" -f 'Start Folders page', $_.Exception.Message) -ForegroundColor Red
    Add-Result 'Start Folders page' 'navigate' 'FAILED' $_.Exception.Message
}

$seenReported = $false
foreach ($name in $StartFolderIds.Keys) {
    if (-not $startFoldersRoot) {
        Add-Result "Start folder: $name" 'on' 'FAILED' 'Settings navigation failed'
        continue
    }
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $StartFolderIds[$name])
        $toggle = $startFoldersRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if (-not $toggle) {
            $why = "toggle not found (AutomationId=$($StartFolderIds[$name]))"
            if ($foldersPageOpened -and -not $seenReported) {
                $why += ". Settings showed: $(Get-SettingsSeen $startFoldersRoot)"
                $seenReported = $true
            }
            throw $why
        }

        $pattern = $toggle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($pattern.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) {
            Write-Host ("  {0,-42} = already on" -f "Start folder: $name")
        } else {
            $pattern.Toggle()
            Write-Host ("  {0,-42} = turned on" -f "Start folder: $name")
        }
        Add-Result "Start folder: $name" 'on' 'OK' "AutomationId=$($StartFolderIds[$name])"
    }
    catch {
        Write-Host ("  {0,-42} = FAILED: {1}" -f "Start folder: $name", $_.Exception.Message) -ForegroundColor Red
        Add-Result "Start folder: $name" 'on' 'FAILED' $_.Exception.Message
    }
}

if ($startFoldersRoot) {
    try {
        $closeCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'Close')
        $closeBtn = $startFoldersRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $closeCond)
        if ($closeBtn) { $closeBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    } catch { }
}


# ---------------------------------------------------------------------------
# 2. FILE EXPLORER
# ---------------------------------------------------------------------------
Write-Section 2 "File Explorer"

Set-Reg $Advanced 'HideFileExt' 0   # show file name extensions


# ---------------------------------------------------------------------------
# 3. POWER
# ---------------------------------------------------------------------------
Write-Section 3 "Power"

$scheme = [regex]::Match((powercfg /getactivescheme), '[0-9a-fA-F-]{36}').Value
Write-Host "  Active scheme                              = $scheme"

# /change applies to the live scheme immediately
powercfg /change standby-timeout-ac   0
powercfg /change standby-timeout-dc   0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /change monitor-timeout-ac   $DisplayTimeoutMinutes
powercfg /change monitor-timeout-dc   $DisplayTimeoutMinutes

Write-Host "  Sleep / hibernate                          = never"
$displayOffText = if ($DisplayTimeoutMinutes -eq 0) { 'never' } else { "$DisplayTimeoutMinutes min" }
Write-Host "  Display off after                          = $displayOffText"
Add-Result 'Sleep (standby)'   'never'          'OK' "scheme $scheme"
Add-Result 'Hibernate'         'never'          'OK' "scheme $scheme"
Add-Result 'Display off after' $displayOffText  'OK' "scheme $scheme"

Set-PowerValue $scheme 'USB selective suspend'      '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0
Set-PowerValue $scheme 'Hybrid sleep'               '238c9fa8-0aad-41ed-83f4-97be242c8f20' '94ac6d29-73ce-41a6-809f-6363ba21b47e' 0
Set-PowerValue $scheme 'PCIe link state power mgmt' '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0
Set-PowerValue $scheme 'Unattended sleep timeout'   '238c9fa8-0aad-41ed-83f4-97be242c8f20' '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0' 0

# Required - without this the Set-PowerValue writes above never reach the
# running system.
& powercfg /setactive $scheme | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Scheme re-activated                        = yes"
    Add-Result 'Power scheme activated' 'yes' 'OK' $scheme
} else {
    Write-Host "  Scheme re-activated                        = FAILED" -ForegroundColor Red
    Add-Result 'Power scheme activated' 'no' 'FAILED' "powercfg /setactive $scheme returned $LASTEXITCODE"
}

# Let the Tap's sensors wake the NUC. Not every NUC has both devices.
foreach ($dev in @('HID Human Presence Sensor', 'HID-compliant touch screen')) {
    $out = & powercfg /deviceenablewake $dev
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  {0,-42} = wake enabled" -f $dev)
        Add-Result "Wake: $dev" 'enabled' 'OK' ''
    } else {
        Write-Host ("  {0,-42} = not present" -f $dev) -ForegroundColor DarkGray
        Add-Result "Wake: $dev" 'not present' 'SKIP' (($out | Where-Object { $_ }) -join ' ')
    }
}

# Stop Windows powering down USB devices - keeps the Tap, camera and mic on the bus
try {
    $powerMgmt = @(Get-CimInstance -ClassName MSPower_DeviceEnable -Namespace root/WMI -ErrorAction Stop)
    $usbDevs   = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter 'PNPClass = "USB"' -ErrorAction Stop)
    $targets   = @($usbDevs | ForEach-Object {
                     $id = $_.PNPDeviceID
                     $powerMgmt | Where-Object InstanceName -Like "*$id*"
                  })
    if ($targets.Count) {
        $targets | Set-CimInstance -Property @{ Enable = $false } -ErrorAction Stop
    }
    Write-Host "  USB power saving disabled on               = $($targets.Count) device(s)"
    Add-Result 'USB power saving' "disabled on $($targets.Count)" 'OK' "$($usbDevs.Count) USB devices enumerated"
}
catch {
    Write-Host "  USB power saving                           = FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Add-Result 'USB power saving' 'disable' 'FAILED' $_.Exception.Message
}

Set-Reg 'HKLM:\System\CurrentControlSet\Control\Power' 'PlatformAoAcOverride' 0   # disable Modern Standby


# ---------------------------------------------------------------------------
# 4. SHORTCUTS AND FOLDER STRUCTURE
# ---------------------------------------------------------------------------
Write-Section 4 "Shortcuts and Folder Structure"

# Resolve the real Downloads path (survives folder redirection)
$dlKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$dlGuid = '{374DE290-123F-4565-9164-39C4925E467B}'
$downloads = (Get-ItemProperty -Path $dlKey -Name $dlGuid -ErrorAction SilentlyContinue).$dlGuid
if ($downloads) { $downloads = [Environment]::ExpandEnvironmentVariables($downloads) }
else            { $downloads = Join-Path $env:USERPROFILE 'Downloads' }
Write-Host "  Downloads  = $downloads"

$workDir = Join-Path $downloads $TempFolderName
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
Write-Host "  created    = $workDir"
Add-Result 'Temp folder' $TempFolderName 'OK' $workDir

# MTR management console - kept in _mtrsetup, with a Desktop shortcut to that copy.
$mmcName = [IO.Path]::GetFileName($MmcFile)
if (Test-Path $MmcFile) {
    Copy-Item -Path $MmcFile -Destination $workDir -Force
    $mmcLocal = Join-Path $workDir $mmcName
    Write-Host "  copied $mmcName -> $workDir" -ForegroundColor Green
    Add-Result 'MMC console' $mmcName 'OK' "$MmcFile -> $workDir"

    $mmcLnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ([IO.Path]::GetFileNameWithoutExtension($mmcName) + '.lnk')
    $wsh = New-Object -ComObject WScript.Shell
    $mmcLnk = $wsh.CreateShortcut($mmcLnkPath)
    $mmcLnk.TargetPath       = $mmcLocal
    $mmcLnk.WorkingDirectory = $workDir
    $mmcLnk.Description      = 'MTR management console'
    $mmcLnk.Save()
    Write-Host "  shortcut   = $mmcLnkPath  ->  $mmcLocal"
    Add-Result 'Shortcut' ([IO.Path]::GetFileName($mmcLnkPath)) 'OK' "$mmcLnkPath -> $mmcLocal"
} else {
    Write-Warning "Not found on the USB stick: $MmcFile"
    Add-Result 'MMC console' $mmcName 'FAILED' "not found: $MmcFile"
}


# ---------------------------------------------------------------------------
# 5. SOFTWARE INSTALLS
# ---------------------------------------------------------------------------
Write-Section 5 "Software installs"

$selectedText = if ($selected.Count) { $selected -join ', ' } else { 'none' }
Write-Host ("  {0,-42} = {1}" -f 'Selected', $selectedText)
Add-Result 'Software selected' $selectedText 'OK' ''

$softwareFolder = Join-Path $workDir $SoftwareFolderName
New-Item -Path $softwareFolder -ItemType Directory -Force | Out-Null
Write-Host "  created    = $softwareFolder"
Add-Result 'Software folder' $SoftwareFolderName 'OK' $softwareFolder

# Helpers for the install blocks below, which run in alphabetical order so the
# report lists them that way. Every install waits for its installer to finish,
# so the end-of-script logoff/restart can't cut one off mid-way.
function Test-AppInstalled {
    param([string]$NameLike)
    $uninstallPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $NameLike } |
        Select-Object -First 1
}

# Reads a summary property straight out of the MSI's own database, rather
# than trusting the zip's filename.
function Get-MsiProperty {
    param([string]$Path, [string]$Property)
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db     = $installer.OpenDatabase($Path, 0)
        $view   = $db.OpenView("SELECT Value FROM Property WHERE Property = '$Property'")
        [void]$view.Execute()
        $record = $view.Fetch()
        if ($record) { return $record.StringData(1).Trim() }
    }
    catch { }
    return $null
}

# 7-Zip - MSI, judged by version like Firefox: same or newer is left alone.
$szName = [IO.Path]::GetFileName($SevenZipMsi)
if (-not $do7zip) {
    Write-Host ("  {0,-42} = not selected" -f '7-Zip')
    Add-Result '7-Zip' 'not selected' 'SKIP' 'unticked in the software prompt'
}
elseif (-not (Test-Path $SevenZipMsi)) {
    Write-Warning "Not found on the USB stick: $SevenZipMsi"
    Add-Result '7-Zip install' $szName 'FAILED' "not found: $SevenZipMsi"
}
else {
    $szVersion   = Get-MsiProperty $SevenZipMsi 'ProductVersion'
    $szInstalled = Test-AppInstalled '*7-Zip*'
    $szUpToDate  = $false
    if ($szInstalled -and $szInstalled.DisplayVersion -and $szVersion) {
        try { $szUpToDate = (ConvertTo-PaddedVersion $szInstalled.DisplayVersion) -ge (ConvertTo-PaddedVersion $szVersion) } catch { }
    }
    if ($szUpToDate) {
        Write-Host ("  {0,-42} = already installed ({1})" -f '7-Zip', $szInstalled.DisplayVersion)
        Add-Result '7-Zip install' "already installed ($($szInstalled.DisplayVersion))" 'OK' ''
    } else {
        Copy-Item -Path $SevenZipMsi -Destination $softwareFolder -Force
        $szPath   = Join-Path $softwareFolder $szName
        $szLog    = Join-Path $softwareFolder '7-ZipInstall.log'
        $szAction = if ($szInstalled) { "upgrading $($szInstalled.DisplayVersion) -> $szVersion" } else { "installing $szVersion" }
        Write-Host ("  {0,-42} = {1}" -f '7-Zip', $szAction) -ForegroundColor Yellow
        $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$szPath`"", '/qn', '/norestart', '/l*v', "`"$szLog`"") -Wait -PassThru
        if ($p.ExitCode -in 0, 3010) { if ($p.ExitCode -eq 3010) { $script:RestartReasons += 'an installer asked for a restart' }
            Write-Host ("  {0,-42} = installed (exit {1})" -f '7-Zip', $p.ExitCode) -ForegroundColor Green
            Add-Result '7-Zip install' "$szAction (exit $($p.ExitCode))" 'OK' $szLog
        } else {
            Write-Host ("  {0,-42} = FAILED (exit {1})" -f '7-Zip', $p.ExitCode) -ForegroundColor Red
            Add-Result '7-Zip install' "exit $($p.ExitCode)" 'FAILED' "see $szLog"
        }
    }
}

# Extron Teams MTR app - copied down and extracted into the Software folder
$zipName = [IO.Path]::GetFileName($ExtronMtrZip)

if (-not $doExtron) {
    Write-Host ("  {0,-42} = not selected" -f 'Extron Control')
    Add-Result 'Extron Control' 'not selected' 'SKIP' 'unticked in the software prompt'
} elseif (Test-Path $ExtronMtrZip) {
    Copy-Item -Path $ExtronMtrZip -Destination $softwareFolder -Force
    Write-Host "  copied $zipName -> $softwareFolder" -ForegroundColor Green
    Add-Result 'Extron Teams MTR zip' $zipName 'OK' "$ExtronMtrZip -> $softwareFolder"

    $zipLocal    = Join-Path $softwareFolder $zipName
    $extractTemp = Join-Path $softwareFolder '_extract_tmp'
    try {
        Expand-Archive -Path $zipLocal -DestinationPath $extractTemp -Force -ErrorAction Stop
        # .msi (not .exe) - it's a plain Windows Installer package, so it
        # can be driven silently via msiexec rather than the double-click
        # .exe wrapper. See "Installer Read Me.txt" inside the zip.
        $msi = Get-ChildItem -Path $extractTemp -Filter '*.msi' -Recurse -File | Select-Object -First 1
        if ($msi) {
            # Copied under a fixed name, not the zip's versioned filename
            # (e.g. "..._v2x5x1.msi") - Windows Installer caches the exact
            # source filename a product was installed from, and a repair
            # later resolves against that cached name. A mismatch there
            # fails with "SecureRepair Failed" / ProcessComponents return 3
            # (surfaces as msiexec exit 1603), confirmed on a test MTR.
            $msi = Copy-Item -Path $msi.FullName -Destination (Join-Path $softwareFolder $ExtronMsiName) -Force -PassThru
            Write-Host ("  extracted  = {0} -> {1}" -f $msi.Name, $softwareFolder) -ForegroundColor Green
            Add-Result 'Extron Teams MTR extract' $msi.Name 'OK' $msi.FullName

            Remove-Item -Path $zipLocal -Force -ErrorAction SilentlyContinue
            Write-Host "  removed    = $zipLocal"
        } else {
            Write-Host "  extract FAILED: no .msi found in $zipName" -ForegroundColor Red
            Add-Result 'Extron Teams MTR extract' $zipName 'FAILED' 'no .msi found inside the archive'
        }
    }
    catch {
        Write-Host "  extract FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Add-Result 'Extron Teams MTR extract' $zipName 'FAILED' $_.Exception.Message
    }
    finally {
        Remove-Item -Path $extractTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Warning "Not found on the USB stick: $ExtronMtrZip"
    Add-Result 'Extron Teams MTR zip' $zipName 'FAILED' "not found: $ExtronMtrZip"
}

if ($msi) {
    $msiPath        = Join-Path $softwareFolder $msi.Name
    $msiLog         = Join-Path $softwareFolder 'ExtronInstall.log'
    $packageVersion = Get-MsiProperty $msiPath 'ProductVersion'
    $productCode    = Get-MsiProperty $msiPath 'ProductCode'

    # Ask Windows Installer directly whether this exact ProductCode is
    # registered, rather than pattern-matching the Uninstall registry's
    # DisplayName - that missed a real install on a test MTR whose DisplayName
    # didn't match '*Extron Control*', and disagreeing with Windows Installer
    # here is exactly what leads to msiexec refusing with 1638 below.
    $installedVersion = $null
    $productState     = $null
    $productStateErr  = $null
    if ($productCode) {
        try {
            $installerCom = New-Object -ComObject WindowsInstaller.Installer
            $productState = $installerCom.ProductState($productCode)
            if ($productState -eq 5) {
                $installedVersion = $installerCom.ProductInfo($productCode, 'VersionString')
            }
        }
        catch { $productStateErr = $_.Exception.Message }
    }
    if ($Debug) {
        Write-Host ("  [diag] ProductCode={0} ProductState={1} InstalledVersion={2} Error={3}" -f `
            $productCode, $productState, $installedVersion, $productStateErr) -ForegroundColor DarkGray
    }

    # Windows Installer's own version comparisons only honour the first three
    # fields (Major.Minor.Build) of ProductVersion - a 4th field is legal but
    # ignored for product-identity purposes. Truncate both sides the same way
    # before comparing, or a package whose metadata carries a 4th field (e.g.
    # 2.5.1.1) reads as "newer" than an installed 2.5.1 that MSI itself
    # considers identical - which is what led to the same install being
    # attempted twice on a test MTR (1638, then 1603 on the forced repair).
    function ConvertTo-MsiVersion {
        param([string]$VersionString)
        if (-not $VersionString) { return $null }
        $parts = @($VersionString -split '\.')[0..2]
        return [version]($parts -join '.')
    }

    # Only treat it as up to date if both versions actually parsed and the
    # installed one is not older - anything else (not installed, older, or
    # version unreadable either side) falls through to installing/upgrading.
    $upToDate = $false
    if ($installedVersion -and $packageVersion) {
        try { $upToDate = (ConvertTo-MsiVersion $installedVersion) -ge (ConvertTo-MsiVersion $packageVersion) }
        catch { $upToDate = $false }
    }

    if ($upToDate) {
        Write-Host ("  {0,-42} = already installed ({1})" -f 'Extron Control', $installedVersion)
        Add-Result 'Extron Control install' "already installed ($installedVersion)" 'OK' $installedVersion
    } else {
        $action = if ($installedVersion) { "upgrading $installedVersion -> $packageVersion" } else { "installing $packageVersion" }
        Write-Host ("  {0,-42} = {1}" -f 'Extron Control', $action) -ForegroundColor Yellow
        $msiArgs = @('/i', "`"$msiPath`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"")
        $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru

        if ($p.ExitCode -eq 1638) {
            # ERROR_PRODUCT_VERSION - a build already on the machine shares this package's
            # ProductCode, so plain /i refuses it outright. /f (repair) is what MSI expects
            # to bring a same-ProductCode install forward to a different package's version.
            Write-Host ("  {0,-42} = same product code installed, repairing to {1}" -f 'Extron Control', $packageVersion) -ForegroundColor Yellow
            $repairArgs = @('/fvomus', "`"$msiPath`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"")
            $p = Start-Process msiexec.exe -ArgumentList $repairArgs -Wait -PassThru
        }

        if ($p.ExitCode -in 0, 3010) { if ($p.ExitCode -eq 3010) { $script:RestartReasons += 'an installer asked for a restart' }
            Write-Host ("  {0,-42} = installed (exit {1})" -f 'Extron Control', $p.ExitCode) -ForegroundColor Green
            Add-Result 'Extron Control install' "$action (exit $($p.ExitCode))" 'OK' $msiLog
        } else {
            Write-Host ("  {0,-42} = FAILED (exit {1})" -f 'Extron Control', $p.ExitCode) -ForegroundColor Red
            Add-Result 'Extron Control install' "exit $($p.ExitCode)" 'FAILED' "see $msiLog"
        }
    }
}

# Firefox ESR - judged by version from the installed-programs list, which sees
# both MSI and regular-installer copies. (MSI ProductState can't be used: every
# Firefox MSI shares one ProductCode, and an .exe install isn't an MSI at all.)
# Same or newer is left alone; older is upgraded by the install.
$ffName = [IO.Path]::GetFileName($FirefoxMsi)
if (-not $doFirefox) {
    Write-Host ("  {0,-42} = not selected" -f 'Firefox ESR')
    Add-Result 'Firefox ESR' 'not selected' 'SKIP' 'unticked in the software prompt'
}
elseif (-not (Test-Path $FirefoxMsi)) {
    Write-Warning "Not found on the USB stick: $FirefoxMsi"
    Add-Result 'Firefox install' $ffName 'FAILED' "not found: $FirefoxMsi"
}
else {
    $ffVersion   = Get-MsiProperty $FirefoxMsi 'ProductVersion'
    $ffInstalled = Test-AppInstalled '*Mozilla Firefox*'
    $ffUpToDate  = $false
    if ($ffInstalled -and $ffInstalled.DisplayVersion -and $ffVersion) {
        try { $ffUpToDate = (ConvertTo-PaddedVersion $ffInstalled.DisplayVersion) -ge (ConvertTo-PaddedVersion $ffVersion) } catch { }
    }
    if ($ffUpToDate) {
        Write-Host ("  {0,-42} = already installed ({1})" -f 'Firefox ESR', $ffInstalled.DisplayVersion)
        Add-Result 'Firefox install' "already installed ($($ffInstalled.DisplayVersion))" 'OK' ''
    } else {
        Copy-Item -Path $FirefoxMsi -Destination $softwareFolder -Force
        $ffPath = Join-Path $softwareFolder $ffName
        $ffLog  = Join-Path $softwareFolder 'FirefoxInstall.log'
        $ffAction = if ($ffInstalled) { "upgrading $($ffInstalled.DisplayVersion) -> $ffVersion" } else { "installing $ffVersion" }
        Write-Host ("  {0,-42} = {1}" -f 'Firefox ESR', $ffAction) -ForegroundColor Yellow
        $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$ffPath`"", '/qn', '/norestart', '/l*v', "`"$ffLog`"") -Wait -PassThru
        if ($p.ExitCode -in 0, 3010) { if ($p.ExitCode -eq 3010) { $script:RestartReasons += 'an installer asked for a restart' }
            Write-Host ("  {0,-42} = installed (exit {1})" -f 'Firefox ESR', $p.ExitCode) -ForegroundColor Green
            Add-Result 'Firefox install' "$ffAction (exit $($p.ExitCode))" 'OK' $ffLog
        } else {
            Write-Host ("  {0,-42} = FAILED (exit {1})" -f 'Firefox ESR', $p.ExitCode) -ForegroundColor Red
            Add-Result 'Firefox install' "exit $($p.ExitCode)" 'FAILED' "see $ffLog"
        }
    }
}

# Logitech Sync installer - straight copy, no extraction needed
$logiName = [IO.Path]::GetFileName($LogiSyncExe)
if (-not $doLogi) {
    Write-Host ("  {0,-42} = not selected" -f 'Logitech Sync')
    Add-Result 'Logitech Sync' 'not selected' 'SKIP' 'unticked in the software prompt'
} elseif (Test-Path $LogiSyncExe) {
    Copy-Item -Path $LogiSyncExe -Destination $softwareFolder -Force
    Write-Host "  copied $logiName -> $softwareFolder" -ForegroundColor Green
    Add-Result 'Logitech Sync installer' $logiName 'OK' "$LogiSyncExe -> $softwareFolder"
} else {
    Write-Warning "Not found on the USB stick: $LogiSyncExe"
    Add-Result 'Logitech Sync installer' $logiName 'FAILED' "not found: $LogiSyncExe"
}

if ($doLogi -and (Test-Path (Join-Path $softwareFolder $logiName))) {
    $logiInstalled = Test-AppInstalled '*Logitech Sync*'
    if ($logiInstalled) {
        $ver = if ($logiInstalled.DisplayVersion) { " ($($logiInstalled.DisplayVersion))" } else { '' }
        Write-Host ("  {0,-42} = already installed{1}" -f 'Logitech Sync', $ver)
        Add-Result 'Logitech Sync install' "already installed$ver" 'OK' $logiInstalled.DisplayVersion
    } else {
        Write-Host ("  {0,-42} = launching installer" -f 'Logitech Sync') -ForegroundColor Yellow
        Start-Process -FilePath (Join-Path $softwareFolder $logiName) -Wait
        Add-Result 'Logitech Sync install' 'launched installer' 'OK' $logiName
    }
}

# Splashtop Streamer - the DEPLOY installer carries this team's deployment code
# in its filename, so it is copied and run under its original name. prevercheck
# makes it upgrade an existing Streamer in place. Version comes from the exe's
# ProductVersion (FileVersion is a different scheme, e.g. 3.74.4.29).
$spName = [IO.Path]::GetFileName($SplashtopExe)
if (-not $doSplash) {
    Write-Host ("  {0,-42} = not selected" -f 'Splashtop Streamer')
    Add-Result 'Splashtop Streamer' 'not selected' 'SKIP' 'unticked in the software prompt'
}
elseif (-not (Test-Path $SplashtopExe)) {
    Write-Warning "Not found on the USB stick: $SplashtopExe"
    Add-Result 'Splashtop install' $spName 'FAILED' "not found: $SplashtopExe"
}
else {
    $spVersion = (Get-Item $SplashtopExe).VersionInfo.ProductVersion
    if (-not $spVersion -and $spName -match '_v([\d.]+)_') { $spVersion = $Matches[1] }
    $spInstalled = Test-AppInstalled '*Splashtop*Streamer*'
    $spUpToDate  = $false
    if ($spInstalled -and $spInstalled.DisplayVersion -and $spVersion) {
        try { $spUpToDate = (ConvertTo-PaddedVersion $spInstalled.DisplayVersion) -ge (ConvertTo-PaddedVersion $spVersion) } catch { }
    }
    if ($spUpToDate) {
        Write-Host ("  {0,-42} = already installed ({1})" -f 'Splashtop Streamer', $spInstalled.DisplayVersion)
        Add-Result 'Splashtop install' "already installed ($($spInstalled.DisplayVersion))" 'OK' ''
    } else {
        Copy-Item -Path $SplashtopExe -Destination $softwareFolder -Force
        $spPath   = Join-Path $softwareFolder $spName
        $spAction = if ($spInstalled) { "upgrading $($spInstalled.DisplayVersion) -> $spVersion" } else { "installing $spVersion" }
        Write-Host ("  {0,-42} = {1}" -f 'Splashtop Streamer', $spAction) -ForegroundColor Yellow
        $p = Start-Process -FilePath $spPath -ArgumentList @('prevercheck', '/s', '/i', 'confirm_d=0,hidewindow=1') -Wait -PassThru
        if ($p.ExitCode -in 0, 3010) { if ($p.ExitCode -eq 3010) { $script:RestartReasons += 'an installer asked for a restart' }
            Write-Host ("  {0,-42} = installed (exit {1})" -f 'Splashtop Streamer', $p.ExitCode) -ForegroundColor Green
            Add-Result 'Splashtop install' "$spAction (exit $($p.ExitCode))" 'OK' $spName
        } else {
            Write-Host ("  {0,-42} = FAILED (exit {1})" -f 'Splashtop Streamer', $p.ExitCode) -ForegroundColor Red
            Add-Result 'Splashtop install' "exit $($p.ExitCode)" 'FAILED' "exit code from $spName"
        }
    }
}

# TightVNC server - skipped if any TightVNC is already on the machine, so an
# existing config and password are never overwritten. Wallpaper handling is
# set afterwards in the Remote management section.
$vncName      = [IO.Path]::GetFileName($VncMsi)
$vncInstalled = Test-AppInstalled '*TightVNC*'
if (-not $doVnc) {
    Write-Host ("  {0,-42} = not selected" -f 'TightVNC')
    Add-Result 'TightVNC' 'not selected' 'SKIP' 'unticked in the software prompt'
}
elseif ($vncInstalled) {
    $ver = if ($vncInstalled.DisplayVersion) { " ($($vncInstalled.DisplayVersion))" } else { '' }
    Write-Host ("  {0,-42} = already installed{1}" -f 'TightVNC', $ver)
    Add-Result 'TightVNC install' "already installed$ver" 'OK' $vncInstalled.DisplayVersion
}
elseif (-not (Test-Path $VncMsi)) {
    Write-Warning "Not found on the USB stick: $VncMsi"
    Add-Result 'TightVNC install' $vncName 'FAILED' "not found: $VncMsi"
}
elseif (-not $VncPassword) {
    Write-Host ("  {0,-42} = FAILED: no VNC password supplied" -f 'TightVNC') -ForegroundColor Red
    Add-Result 'TightVNC install' 'no VNC password' 'FAILED' 'put the password on the first line of vnc-password.txt next to the script, or pass -VncPassword'
}
else {
    Copy-Item -Path $VncMsi -Destination $softwareFolder -Force
    $vncPath = Join-Path $softwareFolder $vncName
    $vncLog  = Join-Path $softwareFolder 'TightVNCInstall.log'
    Write-Host ("  {0,-42} = installing silently" -f 'TightVNC') -ForegroundColor Yellow
    # /le logs errors only - a fuller log would record the password properties.
    $vncArgs = @('/i', "`"$vncPath`"", '/qn', '/norestart', '/le', "`"$vncLog`"",
                 'ADDLOCAL=Server', 'SERVER_REGISTER_AS_SERVICE=1', 'SERVER_ADD_FIREWALL_EXCEPTION=1', 'SERVER_ALLOW_SAS=1',
                 'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
                 'SET_PASSWORD=1', "VALUE_OF_PASSWORD=$VncPassword",
                 'SET_USECONTROLAUTHENTICATION=1', 'VALUE_OF_USECONTROLAUTHENTICATION=1',
                 'SET_CONTROLPASSWORD=1', "VALUE_OF_CONTROLPASSWORD=$VncPassword",
                 'SET_REMOVEWALLPAPER=1', 'VALUE_OF_REMOVEWALLPAPER=0',           # "Hide desktop wallpaper" off from the first start
                 'SET_ACCEPTHTTPCONNECTIONS=1', 'VALUE_OF_ACCEPTHTTPCONNECTIONS=0')   # "Serve Java Viewer to Web clients" off
    $p = Start-Process msiexec.exe -ArgumentList $vncArgs -Wait -PassThru
    if ($p.ExitCode -in 0, 3010) { if ($p.ExitCode -eq 3010) { $script:RestartReasons += 'an installer asked for a restart' }
        Write-Host ("  {0,-42} = installed (exit {1})" -f 'TightVNC', $p.ExitCode) -ForegroundColor Green
        Add-Result 'TightVNC install' "installed (exit $($p.ExitCode))" 'OK' $vncLog
    } else {
        Write-Host ("  {0,-42} = FAILED (exit {1})" -f 'TightVNC', $p.ExitCode) -ForegroundColor Red
        Add-Result 'TightVNC install' "exit $($p.ExitCode)" 'FAILED' "see $vncLog"
    }
}


# ---------------------------------------------------------------------------
# 6. PERSONALIZATION > TASKBAR
# ---------------------------------------------------------------------------
# Runs after the installs so the pins step can find Firefox's Start menu shortcut.
Write-Section 6 "Taskbar"

# --- Items ---
# Search: Hide   (0=Hide 1=Icon only 2=Search box 3=Icon+label)
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
Set-Reg $Advanced 'ShowTaskViewButton' 0      # Task view: Off

# Widgets. Neither registry route works on the MTR build - TaskbarDa is
# anti-tampered below the ACL layer and ignored by the shell, and
# SOFTWARE\Policies is locked to SYSTEM. Removing the package is what takes.
# The policy write is still attempted for hosts that are not locked down;
# failure is expected here, so it is recorded as SKIP rather than FAILED.
$dsh = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
try {
    if (-not (Test-Path $dsh)) { New-Item -Path $dsh -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $dsh -Name 'AllowNewsAndInterests' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    Write-Host ("  {0,-42} = {1}" -f 'AllowNewsAndInterests (policy)', 0)
    Add-Result 'AllowNewsAndInterests (policy)' 0 'OK' $dsh
}
catch {
    Write-Host ("  {0,-42} = skipped (Policies locked to SYSTEM)" -f 'AllowNewsAndInterests (policy)') -ForegroundColor DarkGray
    Add-Result 'AllowNewsAndInterests (policy)' 0 'SKIP' "$dsh - expected on this build: $($_.Exception.Message)"
}

$widgets = @()
try { $widgets = @(Get-AppxPackage -AllUsers -Name 'MicrosoftWindows.Client.WebExperience' -ErrorAction Stop) } catch { }

if ($widgets.Count) {
    foreach ($w in $widgets) {
        try {
            Remove-AppxPackage -Package $w.PackageFullName -AllUsers -ErrorAction Stop
            Write-Host ("  {0,-42} = removed" -f 'Widgets (WebExperience)') -ForegroundColor Green
            Add-Result 'Widgets (WebExperience)' 'removed' 'OK' $w.PackageFullName
        }
        catch {
            Write-Host ("  {0,-42} = FAILED: {1}" -f 'Widgets (WebExperience)', $_.Exception.Message) -ForegroundColor Red
            Add-Result 'Widgets (WebExperience)' 'remove' 'FAILED' "$($w.PackageFullName) - $($_.Exception.Message)"
        }
    }
} else {
    Write-Host ("  {0,-42} = not installed" -f 'Widgets (WebExperience)')
    Add-Result 'Widgets (WebExperience)' 'not installed' 'OK' 'nothing to remove'
}

# Deprovision so a newly created profile does not get it back
try {
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
              Where-Object DisplayName -like '*WebExperience*')
    foreach ($p in $prov) {
        Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
        Write-Host ("  {0,-42} = deprovisioned" -f 'Widgets (provisioned)') -ForegroundColor Green
        Add-Result 'Widgets (provisioned)' 'deprovisioned' 'OK' $p.PackageName
    }
    if (-not $prov.Count) {
        Write-Host ("  {0,-42} = not provisioned" -f 'Widgets (provisioned)')
        Add-Result 'Widgets (provisioned)' 'not provisioned' 'OK' 'nothing to remove'
    }
}
catch {
    Write-Host ("  {0,-42} = FAILED: {1}" -f 'Widgets (provisioned)', $_.Exception.Message) -ForegroundColor Red
    Add-Result 'Widgets (provisioned)' 'deprovision' 'FAILED' $_.Exception.Message
}

# --- System tray icons ---
Set-Reg 'HKCU:\Software\Microsoft\Input\Settings' 'EnableExpressiveInputShellHotkey' 0   # Emoji and more: Never
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PenWorkspace' 'PenWorkspaceButtonDesiredVisibility' 0
Set-Reg $Advanced 'TaskbarVirtualTouchpadVisibility' 0

# Show every registered tray icon rather than hiding them in the overflow menu
$notify = 'HKCU:\Control Panel\NotifyIconSettings'
if (Test-Path $notify) {
    $icons = Get-ChildItem $notify
    $icons | ForEach-Object {
        New-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -PropertyType DWord -Force | Out-Null
    }
    Write-Host "  promoted $($icons.Count) tray icons to always-visible"
    Add-Result 'Tray icons promoted' $icons.Count 'OK' (($icons.Name | Split-Path -Leaf) -join ', ')
}

# --- Behaviours ---
Set-Reg $Advanced 'TaskbarAl'          0   # Alignment: Left
Set-Reg $Advanced 'TaskbarBadges'      0   # Badges on taskbar apps
Set-Reg $Advanced 'TaskbarFlashing'    0   # Flashing on taskbar apps
Set-Reg $Advanced 'MMTaskbarEnabled'   0   # Taskbar on all displays
Set-Reg $Advanced 'TaskbarSn'          0   # Share any window from taskbar
Set-Reg $Advanced 'TaskbarSd'          0   # Far corner shows desktop
Set-Reg $Advanced 'TaskbarGlomLevel'   0   # Combine buttons + hide labels: Always
Set-Reg $Advanced 'MMTaskbarGlomLevel' 0   # ...on other taskbars: Always
Set-Reg $Advanced 'TaskbarSi'          1   # Smaller buttons: When taskbar is full

# Auto-hide lives in a binary blob, bit 0x01 of byte 8
$stuck = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
if (Test-Path $stuck) {
    $bytes = (Get-ItemProperty -Path $stuck -Name Settings).Settings
    $bytes[8] = $bytes[8] -band 0xFE
    Set-ItemProperty -Path $stuck -Name Settings -Value $bytes
    Write-Host "  Automatically hide the taskbar              = off"
    Add-Result 'Automatically hide the taskbar' 'off' 'OK' "$stuck (Settings byte 8, bit 0x01)"
}

# --- Pins ---
# File Explorer and Firefox, added after the default pins. Set with a taskbar
# layout file plus the per-user "Start Layout" policy (User Configuration >
# Administrative Templates > Start Menu and Taskbar), so it applies to the
# account running this (Admin) at its next sign-in, and again at any sign-in
# after the file changes. A pin whose shortcut is missing at sign-in is not shown.
$pinEntries = @('<taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer"/>')
Write-Host ("  {0,-42} = on next sign-in" -f 'Taskbar pin: File Explorer')
Add-Result 'Taskbar pin: File Explorer' 'on next sign-in' 'OK' 'Microsoft.Windows.Explorer'

$pinShell    = New-Object -ComObject WScript.Shell
$firefoxLink = $null
foreach ($programs in @((Join-Path $env:ALLUSERSPROFILE 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
    $firefoxLink = Get-ChildItem -Path $programs -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object {
        $sc = $pinShell.CreateShortcut($_.FullName)
        $sc.TargetPath -like '*\firefox.exe' -and -not $sc.Arguments
    } | Select-Object -First 1
    if ($firefoxLink) { break }
}
if ($firefoxLink) {
    $firefoxPath = $firefoxLink.FullName.Replace($env:ALLUSERSPROFILE, '%ALLUSERSPROFILE%').Replace($env:APPDATA, '%APPDATA%')
    $pinEntries += '<taskbar:DesktopApp DesktopApplicationLinkPath="' + [Security.SecurityElement]::Escape($firefoxPath) + '"/>'
    Write-Host ("  {0,-42} = on next sign-in" -f 'Taskbar pin: Firefox')
    Add-Result 'Taskbar pin: Firefox' 'on next sign-in' 'OK' $firefoxLink.FullName
} else {
    Write-Host ("  {0,-42} = not installed" -f 'Taskbar pin: Firefox')
    Add-Result 'Taskbar pin: Firefox' 'not installed' 'SKIP' 'no Firefox Start menu shortcut found'
}

$layoutXml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection>
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        $($pinEntries -join "`r`n        ")
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@

# Left untouched when the content is unchanged, so a re-run does not make the
# file look newer and re-apply the pins at the next sign-in.
$layoutFile = Join-Path $env:ProgramData 'MTR-Setup\TaskbarLayout.xml'
try {
    $layoutDir = Split-Path $layoutFile
    if (-not (Test-Path $layoutDir)) { New-Item -Path $layoutDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    $current = if (Test-Path $layoutFile) { [IO.File]::ReadAllText($layoutFile) } else { $null }
    if ($current -ceq $layoutXml) {
        Write-Host ("  {0,-42} = unchanged" -f 'Taskbar layout file')
        Add-Result 'Taskbar layout file' 'unchanged' 'OK' $layoutFile
    } else {
        [IO.File]::WriteAllText($layoutFile, $layoutXml, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ("  {0,-42} = written" -f 'Taskbar layout file')
        Add-Result 'Taskbar layout file' 'written' 'OK' $layoutFile
    }

    $explorerPolicy = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
    Set-Reg $explorerPolicy 'StartLayoutFile'   $layoutFile 'ExpandString'
    Set-Reg $explorerPolicy 'LockedStartLayout' 1
    $script:TaskbarPinsSet = $true
}
catch {
    Write-Host ("  {0,-42} = FAILED: {1}" -f 'Taskbar layout file', $_.Exception.Message) -ForegroundColor Red
    Add-Result 'Taskbar layout file' 'write' 'FAILED' $_.Exception.Message
}


# ---------------------------------------------------------------------------
# 7. APPEARANCE - wallpaper and colours
# ---------------------------------------------------------------------------
# Applies to the Windows desktop for the account running this (Admin).
# The MTR console theme is separate and untouched.
Write-Section 7 "Appearance"

$imgName = [IO.Path]::GetFileName($SourceFile)
if (Test-Path $SourceFile) {
    Copy-Item -Path $SourceFile -Destination $workDir -Force
    Write-Host "  copied $imgName -> $workDir" -ForegroundColor Green
    Add-Result 'Background image' $imgName 'OK' "$SourceFile -> $workDir"
} else {
    Write-Warning "Not found on the USB stick: $SourceFile"
    Add-Result 'Background image' $imgName 'FAILED' "not found: $SourceFile"
}

# Point at the local copy - the share is unmounted by now and the wallpaper
# path has to stay resolvable at every future logon.
$localImg = Join-Path $workDir $imgName
if (Test-Path $localImg) {
    Set-Reg 'HKCU:\Control Panel\Desktop' 'Wallpaper'      $localImg 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'WallpaperStyle' '10'      'String'   # 10 = Fill
    Set-Reg 'HKCU:\Control Panel\Desktop' 'TileWallpaper'  '0'       'String'

    # Registry alone only takes effect at next logon. SPI_SETDESKWALLPAPER =
    # 0x0014, SPIF_UPDATEINIFILE (0x01) | SPIF_SENDCHANGE (0x02).
    if (-not ('Native.Wallpaper' -as [type])) {
        Add-Type -Namespace Native -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
    }
    $rc = [Native.Wallpaper]::SystemParametersInfo(0x0014, 0, $localImg, 0x03)

    if ($rc -ne 0) {
        Write-Host "  wallpaper  = $localImg (Fill)" -ForegroundColor Green
        Add-Result 'Desktop wallpaper' $imgName 'OK' "$localImg, style Fill, applied live"
    } else {
        Write-Host "  wallpaper  = set in registry, live apply failed" -ForegroundColor Yellow
        Add-Result 'Desktop wallpaper' $imgName 'OK' "$localImg, registry set; applies at next logon"
    }
} else {
    Write-Warning "Wallpaper not set - $localImg is missing"
    Add-Result 'Desktop wallpaper' $imgName 'FAILED' "local image missing: $localImg"
}

# Colours last - the automatic accent is derived from the wallpaper, so this
# has to run after the wallpaper is in place to pick up the right one.
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
Set-Reg $personalize 'AppsUseLightTheme'    0   # Choose your mode: Dark
Set-Reg $personalize 'SystemUsesLightTheme' 0
Set-Reg 'HKCU:\Control Panel\Desktop' 'AutoColorization' 1   # Accent colour: Automatic


# ---------------------------------------------------------------------------
# 8. REMOTE MANAGEMENT (WinRM / PS Remoting)
# ---------------------------------------------------------------------------
Write-Section 8 "Remote management (WinRM)"

# Enable-PSRemoting's firewall rule only opens on Domain/Private profiles.
# These are workgroup machines, so the LAN NIC can default to Public, and
# the Hyper-V "Default Switch" adapter these NUCs also carry almost always
# is Public - -SkipNetworkProfileCheck below lets Enable-PSRemoting proceed
# regardless, but the rule still only takes effect on Private/Domain, so
# fix the category first rather than relying on that flag alone.
try {
    $publicProfiles = @(Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public')
    foreach ($p in $publicProfiles) {
        Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
        Write-Host ("  {0,-42} = Public -> Private" -f $p.InterfaceAlias)
        Add-Result "Network category: $($p.InterfaceAlias)" 'Public -> Private' 'OK' "InterfaceIndex $($p.InterfaceIndex)"
    }
    if (-not $publicProfiles.Count) {
        Write-Host "  Network category                           = already Private/Domain"
        Add-Result 'Network category' 'Private/Domain' 'OK' 'no Public-profile interfaces found'
    }
}
catch {
    Write-Host "  Network category                           = FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Add-Result 'Network category' 'Private' 'FAILED' $_.Exception.Message
}

try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
    Write-Host "  WinRM / PS Remoting                         = enabled" -ForegroundColor Green
    Add-Result 'PS Remoting' 'enabled' 'OK' 'Enable-PSRemoting -Force -SkipNetworkProfileCheck'
}
catch {
    Write-Host "  WinRM / PS Remoting                         = FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Add-Result 'PS Remoting' 'enable' 'FAILED' $_.Exception.Message
}

Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
$winrm = Get-Service -Name WinRM -ErrorAction SilentlyContinue
if ($winrm) {
    Write-Host ("  {0,-42} = {1} ({2})" -f 'WinRM service', $winrm.Status, $winrm.StartType)
    Add-Result 'WinRM service' "$($winrm.Status) ($($winrm.StartType))" 'OK' ''
}

# ICMP echo (ping) - off by default on this build, same as WinRM's rule was.
# Needed so an audit/health-check script can reach the machine at all before
# it even gets to WinRM.
try {
    $icmpRules = @(Get-NetFirewallRule -DisplayName 'File and Printer Sharing (Echo Request - ICMP*-In)' -ErrorAction Stop)
    $icmpRules | Enable-NetFirewallRule -ErrorAction Stop
    Write-Host ("  {0,-42} = enabled ({1} rule(s))" -f 'ICMP (ping)', $icmpRules.Count) -ForegroundColor Green
    Add-Result 'ICMP (ping)' 'enabled' 'OK' (($icmpRules.DisplayName | Select-Object -Unique) -join ', ')
}
catch {
    Write-Host "  ICMP (ping)                                = FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Add-Result 'ICMP (ping)' 'enable' 'FAILED' $_.Exception.Message
}

# TightVNC server settings the fleet wants off, both on the Server tab:
#   RemoveWallpaper=0        "Hide desktop wallpaper" unticked
#   AcceptHttpConnections=0  "Serve Java Viewer to Web clients" unticked
# A fresh install already gets both from the install properties; this covers a
# TightVNC that was already there. The service keeps its settings in memory
# (that is what the Configuration window shows), so a registry change only shows
# once the service restarts - restart it, but only when a value actually had to
# change, so a run never drops a VNC session needlessly. A 64-bit build uses the
# native registry view, a 32-bit build the WOW6432Node one; use whichever exists.
$vncSettings = [ordered]@{ RemoveWallpaper = 0; AcceptHttpConnections = 0 }
$vncSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'tvnserver' -or $_.DisplayName -like 'TightVNC*' } | Select-Object -First 1
if (-not $vncSvc) {
    Write-Host ("  {0,-42} = TightVNC not installed, nothing to set" -f 'TightVNC settings')
    Add-Result 'TightVNC settings' 'TightVNC not installed' 'SKIP' 'nothing to set'
}
else {
    $vncKey = @('HKLM:\SOFTWARE\TightVNC\Server', 'HKLM:\SOFTWARE\WOW6432Node\TightVNC\Server') | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $vncKey) { $vncKey = 'HKLM:\SOFTWARE\TightVNC\Server' }
    $vncChanged = $false
    foreach ($name in $vncSettings.Keys) {
        $was = (Get-ItemProperty -Path $vncKey -Name $name -ErrorAction SilentlyContinue).$name
        if ($was -ne $vncSettings[$name]) { $vncChanged = $true }
        Set-Reg $vncKey $name $vncSettings[$name]
    }
    if ($vncChanged -and $vncSvc.Status -eq 'Running') {
        try {
            Restart-Service -Name $vncSvc.Name -Force -ErrorAction Stop
            Write-Host ("  {0,-42} = restarted to load the settings" -f 'TightVNC service') -ForegroundColor Green
            Add-Result 'TightVNC service' 'restarted' 'OK' 'to load the changed settings'
        }
        catch {
            Write-Host ("  {0,-42} = FAILED to restart: {1}" -f 'TightVNC service', $_.Exception.Message) -ForegroundColor Red
            Add-Result 'TightVNC service' 'restart' 'FAILED' $_.Exception.Message
        }
    }
}


# ---------------------------------------------------------------------------
# 9. CLEANUP
# ---------------------------------------------------------------------------
# Unwanted software found on the fleet gets removed here. One entry so far;
# add more the same way as they turn up.
Write-Section 9 "Cleanup"

# TeamViewer - unmanaged remote-access tool, redundant now that WinRM and
# VNC are the sanctioned remote paths. Some builds register more than one
# Uninstall entry (e.g. a 32-bit view alongside the native one).
try {
    $tvEntries = @(Get-ItemProperty -Path @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*TeamViewer*' })

    if ($tvEntries.Count) {
        foreach ($tv in $tvEntries) {
            $raw = $tv.UninstallString
            if (-not $raw) {
                Write-Host ("  {0,-42} = FAILED: no UninstallString" -f "TeamViewer ($($tv.DisplayName))") -ForegroundColor Red
                Add-Result 'TeamViewer removal' $tv.DisplayName 'FAILED' 'no UninstallString on this registry entry'
                continue
            }
            try {
                if ($raw -match '(?i)msiexec') {
                    # MSI-registered build - PSChildName under the Uninstall key is the
                    # ProductCode itself, fall back to pulling it out of the string.
                    $code = if ($tv.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') { $tv.PSChildName }
                             elseif ($raw -match '(\{[0-9A-Fa-f-]{36}\})') { $Matches[1] }
                             else { $null }
                    if (-not $code) { throw "could not determine ProductCode from '$raw'" }
                    Start-Process msiexec.exe -ArgumentList @('/x', $code, '/qn', '/norestart') -Wait -ErrorAction Stop
                } else {
                    # TeamViewer's own NSIS uninstaller - /S is its documented silent switch.
                    $exe = $raw.Trim('"')
                    Start-Process -FilePath $exe -ArgumentList '/S' -Wait -ErrorAction Stop
                }
                Write-Host ("  {0,-42} = removed" -f "TeamViewer ($($tv.DisplayName))") -ForegroundColor Green
                Add-Result 'TeamViewer removal' $tv.DisplayName 'OK' $raw
            }
            catch {
                Write-Host ("  {0,-42} = FAILED: {1}" -f "TeamViewer ($($tv.DisplayName))", $_.Exception.Message) -ForegroundColor Red
                Add-Result 'TeamViewer removal' $tv.DisplayName 'FAILED' $_.Exception.Message
            }
        }
    } else {
        Write-Host "  TeamViewer                                 = not installed"
        Add-Result 'TeamViewer removal' 'not installed' 'OK' 'nothing to remove'
    }
}
catch {
    Write-Host "  TeamViewer                                 = FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Add-Result 'TeamViewer removal' 'check' 'FAILED' $_.Exception.Message
}


# ---------------------------------------------------------------------------
# 10. REPORT
# ---------------------------------------------------------------------------
Write-Host "`n[12] Writing report" -ForegroundColor Cyan

$restartReasons = @(Get-PendingRestartReasons)

$os   = Get-CimInstance Win32_OperatingSystem
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$cv   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

$displayVersion = (Get-ItemProperty $cv -Name DisplayVersion -EA SilentlyContinue).DisplayVersion
$ubr            = (Get-ItemProperty $cv -Name UBR            -EA SilentlyContinue).UBR
$winVersion     = "$($os.Caption) $displayVersion (build $($os.BuildNumber).$ubr)"

# The MTR app is installed per-user for the Skype account, so -AllUsers is
# required when running as Admin.
$mtrApp = 'not found'
try {
    $pkg = Get-AppxPackage -AllUsers -Name 'Microsoft.SkypeRoomSystem' -EA Stop |
           Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) { $mtrApp = "$($pkg.Name) $($pkg.Version)" }
} catch { }
if ($mtrApp -eq 'not found') {
    $legacy = 'C:\Program Files\Skype Room System\SkypeRoomSystem.exe'
    if (Test-Path $legacy) {
        $mtrApp = "SkypeRoomSystem $((Get-Item $legacy).VersionInfo.FileVersion) (legacy install)"
    }
}

$ips = Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
       Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
       ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) [$($_.InterfaceAlias)]" }
if (-not $ips) { $ips = @('none') }

$stamp    = Get-Date
$failed   = @($script:Results | Where-Object Status -eq 'FAILED')
$skipped  = @($script:Results | Where-Object Status -eq 'SKIP')
$logName  = "$ReportHost-MTR-Applied-Settings.log"
$logPath  = Join-Path $workDir $logName

$report = New-Object System.Text.StringBuilder
function Add-Line { param($t = '') [void]$report.AppendLine($t) }

Add-Line '============================================================'
Add-Line ' MTR Windows standardisation'
Add-Line " Script: v$ScriptVersion (portable)"
Add-Line " Run:    $($stamp.ToString('yyyy-MM-dd HH:mm:ss'))"
Add-Line " User:   $env:USERDOMAIN\$env:USERNAME"
Add-Line '============================================================'
Add-Line
Add-Line '--- MACHINE ------------------------------------------------'
Add-Line ("  {0,-22} {1}" -f 'Hostname',     $(if ($hostChangeNote) { "$ReportHost (renamed from $currentHost - restart needed)" } else { $ReportHost }))
Add-Line ("  {0,-22} {1}" -f 'Manufacturer', $cs.Manufacturer)
Add-Line ("  {0,-22} {1}" -f 'Model',        $cs.Model)
Add-Line ("  {0,-22} {1}" -f 'Serial',       $bios.SerialNumber)
Add-Line ("  {0,-22} {1}" -f 'BIOS',         $bios.SMBIOSBIOSVersion)
Add-Line ("  {0,-22} {1}" -f 'Windows',      $winVersion)
Add-Line ("  {0,-22} {1}" -f 'MTR app',      $mtrApp)
Add-Line ("  {0,-22} {1}" -f 'Last boot',    $os.LastBootUpTime)
Add-Line ("  {0,-22} {1}" -f 'Restart pending', $(if ($restartReasons.Count) { 'yes - ' + ($restartReasons -join ', ') } else { 'no' }))
foreach ($i in $ips) { Add-Line ("  {0,-22} {1}" -f 'IPv4', $i) }
Add-Line
Add-Line '--- SETTINGS APPLIED ---------------------------------------'
$lastSection = ''
foreach ($r in $script:Results) {
    if ($r.Section -ne $lastSection) {
        Add-Line
        Add-Line "  [$($r.Section)]"
        $lastSection = $r.Section
    }
    Add-Line ("    {0,-6} {1,-42} = {2}" -f $r.Status, $r.Setting, $r.Value)
    if ($r.Status -eq 'FAILED') { Add-Line ("           -> {0}" -f $r.Detail) }
}
Add-Line
Add-Line '--- SUMMARY ------------------------------------------------'
Add-Line ("  {0,-22} {1}" -f 'Total',   $script:Results.Count)
Add-Line ("  {0,-22} {1}" -f 'OK',      ($script:Results.Count - $failed.Count - $skipped.Count))
Add-Line ("  {0,-22} {1}" -f 'Skipped', $skipped.Count)
Add-Line ("  {0,-22} {1}" -f 'Failed',  $failed.Count)
if ($skipped.Count) {
    Add-Line
    foreach ($s in $skipped) { Add-Line "  SKIP:   $($s.Setting) - $($s.Detail)" }
}
if ($failed.Count) {
    Add-Line
    foreach ($f in $failed) { Add-Line "  FAILED: $($f.Setting) - $($f.Detail)" }
}
Add-Line
Add-Line '--- NOTES --------------------------------------------------'
Add-Line '  The Widgets toggle in Settings still reads On after the'
Add-Line '  package is removed. Check the taskbar, not the toggle.'
Add-Line
Add-Line '  Not verified visually - confirm under Taskbar behaviours:'
Add-Line '    Show flashing, Share any window, Smaller taskbar buttons'
Add-Line
if ($restartReasons.Count) {
    Add-Line "  Restart pending: $($restartReasons -join ', ')."
    Add-Line '  The launcher restarts the MTR after its countdown instead of logging off.'
    Add-Line
}
if ($script:TaskbarPinsSet) {
    Add-Line '  Taskbar pins (File Explorer, Firefox) appear at the next sign-in of this'
    Add-Line '  account - the launcher logs off or restarts after its countdown.'
    Add-Line
}
Add-Line '  WinRM is enabled on this machine, but it is a workgroup machine'
Add-Line '  (not domain-joined) - connecting from another PC still needs that'
Add-Line '  PC''s own TrustedHosts set first, e.g. from an elevated prompt there:'
Add-Line "    Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$ReportHost' -Concatenate"
Add-Line '  then connect with -Credential using this machine''s local Admin account.'
Add-Line

Set-Content -Path $logPath -Value $report.ToString() -Encoding UTF8
Write-Host "  report     = $logPath"

# Copy back onto the USB stick. Not recorded via Add-Result - the report is
# already written, so a result added here would not appear in the file it describes.
try {
    if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force -EA Stop | Out-Null }
    Copy-Item -Path $logPath -Destination $LogFolder -Force -EA Stop
    Write-Host "  saved to   = $LogFolder\$logName" -ForegroundColor Green
}
catch {
    Write-Warning "Could not save report to $LogFolder - $($_.Exception.Message)"
    Write-Host   "  local copy kept at $logPath" -ForegroundColor Yellow
}


# ---------------------------------------------------------------------------
# 11. APPLY
# ---------------------------------------------------------------------------
Write-Host "`n[13] Restarting Explorer to apply..." -ForegroundColor Cyan
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }

Write-Host "`nDone. Applied to $ReportHost\$env:USERNAME" -ForegroundColor Green
if ($restartReasons.Count) { Write-Host "Restart pending: $($restartReasons -join ', ')." -ForegroundColor Yellow }

if ($failed.Count) {
    Write-Host "$($failed.Count) of $($script:Results.Count) settings FAILED:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $($_.Setting) - $($_.Detail)" -ForegroundColor Red }
} else {
    Write-Host "All $($script:Results.Count) settings applied successfully." -ForegroundColor Green
}

Write-Host "`nReport: $logPath`n"

# 3010 (the Windows "restart required" code) tells run-mtr_setup.bat to restart
# the MTR after its countdown instead of logging off.
if ($restartReasons.Count) { exit 3010 }
