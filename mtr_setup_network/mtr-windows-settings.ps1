<#
    mtr-windows-settings.ps1

    Standardises Windows shell, power and desktop settings on Microsoft Teams
    Rooms (MTR) NUCs, reading installers and the wallpaper from a file share.
    Run elevated as the ADMIN account - the HKCU settings apply only to the
    account that runs it, not to the Skype/MTR auto-logon account.

    Writes a per-host report into Downloads\_mtrsetup and uploads it to the share.

    Usage:  run-mtr_setup.bat  (or powershell.exe -ExecutionPolicy Bypass -File
            .\mtr-windows-settings.ps1). The share details come from
            network-settings.psd1 next to this script, or from parameters.
#>

# NOTE: there is no default share host, account or password. Put them in
#       network-settings.psd1 next to this script (git-ignored - copy
#       network-settings.example.psd1), or pass them as parameters. The account
#       is stored in the MTR's credential manager for the Admin user.
param(
    [string]$ShareHost      = '',                       # file server holding the installers and receiving reports
    [string]$ShareUser      = '',                       # local account on $ShareHost (used as HOST\user)
    [string]$SharePass      = '',
    [string]$ToolShare      = 'MTR\mtr_setup_network',  # path under \\$ShareHost holding this tool: run-mtr_setup.bat, assets\, logs\
    [string]$SoftwareShare  = 'Software',               # share under \\$ShareHost holding the installers
    [string]$SourceFile,                                # wallpaper - default \\$ShareHost\$ToolShare\assets\wallpaper.png
    [string]$TempFolderName = '_mtrsetup',
    [string]$ExtronMtrZip,                              # default \\$ShareHost\$SoftwareShare\Extron\MTR\ExtronControlforMicrosoftTeamsRooms_2x5x1.zip
    [string]$ExtronMsiName  = 'ExtronControlforMicrosoftTeamsRooms.msi',
    [string]$LogiSyncExe,                               # default \\$ShareHost\$SoftwareShare\Logitech\LogiSyncApp-Setup.exe
    [string]$SetupBat,                                  # default \\$ShareHost\$ToolShare\run-mtr_setup.bat
    [string]$LogShare,                                  # default \\$ShareHost\$ToolShare\logs
    [int]$DisplayTimeoutMinutes = 3,
    [switch]$Debug   # extra [diag] console lines for things like the MSI ProductCode lookup
)

# Bump on every change to this file, format YYYY.MM.DD-NNN.
$ScriptVersion = '2026.09.27-001'

$ErrorActionPreference = 'Continue'
Write-Host "mtr-windows-settings.ps1 v$ScriptVersion`n" -ForegroundColor Cyan

# Site settings: any key in network-settings.psd1 that matches a parameter name
# sets it, unless it was passed on the command line.
$settingsFile = Join-Path $PSScriptRoot 'network-settings.psd1'
if (Test-Path $settingsFile) {
    $siteSettings = Import-PowerShellDataFile -Path $settingsFile
    $knownParams  = @($MyInvocation.MyCommand.Parameters.Keys)
    foreach ($key in $siteSettings.Keys) {
        if ($knownParams -contains $key -and -not $PSBoundParameters.ContainsKey($key)) { Set-Variable -Name $key -Value $siteSettings[$key] }
    }
}
if (-not ($ShareHost -and $ShareUser -and $SharePass)) {
    Write-Host 'ShareHost, ShareUser and SharePass are not set. Copy network-settings.example.psd1 to' -ForegroundColor Red
    Write-Host 'network-settings.psd1 next to this script and fill it in, or pass them as parameters.' -ForegroundColor Red
    exit 2
}
if (-not $SourceFile)   { $SourceFile   = "\\$ShareHost\$ToolShare\assets\wallpaper.png" }
if (-not $ExtronMtrZip) { $ExtronMtrZip = "\\$ShareHost\$SoftwareShare\Extron\MTR\ExtronControlforMicrosoftTeamsRooms_2x5x1.zip" }
if (-not $LogiSyncExe)  { $LogiSyncExe  = "\\$ShareHost\$SoftwareShare\Logitech\LogiSyncApp-Setup.exe" }
if (-not $SetupBat)     { $SetupBat     = "\\$ShareHost\$ToolShare\run-mtr_setup.bat" }
if (-not $LogShare)     { $LogShare     = "\\$ShareHost\$ToolShare\logs" }

$script:Results = @()
$script:Section = ''

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

$startFoldersRoot = $null
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
    if (-not $personalizationItem) { throw "Could not find Personalization in the Settings nav" }
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
    if (-not $startItem) { throw "Could not find Start in the Personalization list" }
    Invoke-AutomationElement $startItem
    Start-Sleep -Milliseconds 500

    $foldersRowCond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Folders'))
    )
    $foldersRow = $null
    for ($i = 0; $i -lt 20 -and -not $foldersRow; $i++) {
        Start-Sleep -Milliseconds 500
        $foldersRow = $startFoldersRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $foldersRowCond)
    }
    if (-not $foldersRow) { throw "Could not find the Folders row on the Start page" }
    $foldersRow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Seconds 1
}
catch {
    Write-Host ("  {0,-42} = FAILED: {1}" -f 'Start Folders page', $_.Exception.Message) -ForegroundColor Red
    Add-Result 'Start Folders page' 'navigate' 'FAILED' $_.Exception.Message
}

foreach ($name in $StartFolderIds.Keys) {
    if (-not $startFoldersRoot) {
        Add-Result "Start folder: $name" 'on' 'FAILED' 'Settings navigation failed'
        continue
    }
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $StartFolderIds[$name])
        $toggle = $startFoldersRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        if (-not $toggle) { throw "toggle not found (AutomationId=$($StartFolderIds[$name]))" }

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
# 2. PERSONALIZATION > TASKBAR - items
# ---------------------------------------------------------------------------
Write-Section 2 "Taskbar items"

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


# ---------------------------------------------------------------------------
# 3. PERSONALIZATION > TASKBAR - system tray icons
# ---------------------------------------------------------------------------
Write-Section 3 "System tray icons"

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


# ---------------------------------------------------------------------------
# 4. PERSONALIZATION > TASKBAR - behaviours
# ---------------------------------------------------------------------------
Write-Section 4 "Taskbar behaviours"

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


# ---------------------------------------------------------------------------
# 5. FILE EXPLORER
# ---------------------------------------------------------------------------
Write-Section 5 "File Explorer"

Set-Reg $Advanced 'HideFileExt' 0   # show file name extensions


# ---------------------------------------------------------------------------
# 6. POWER
# ---------------------------------------------------------------------------
Write-Section 6 "Power"

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
Write-Host "  Display off after                          = $DisplayTimeoutMinutes min"
Add-Result 'Sleep (standby)'   'never'                     'OK' "scheme $scheme"
Add-Result 'Hibernate'         'never'                     'OK' "scheme $scheme"
Add-Result 'Display off after' "$DisplayTimeoutMinutes min" 'OK' "scheme $scheme"

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
# 7. SHORTCUTS AND FOLDER STRUCTURE
# ---------------------------------------------------------------------------
Write-Section 7 "Shortcuts and Folder Structure"

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

# Stash the share credential so the shortcut opens without a prompt
cmdkey /delete:$ShareHost 2>&1 | Out-Null
cmdkey /add:$ShareHost /user:"$ShareHost\$ShareUser" /pass:"$SharePass" | Out-Null
Write-Host "  credential = $ShareHost\$ShareUser  (stored for $env:USERNAME)"
Add-Result 'Stored credential' "$ShareHost\$ShareUser" 'OK' "for $env:USERNAME"

$lnkTarget = "\\$ShareHost\$SoftwareShare"
$lnkPath   = Join-Path $workDir "$SoftwareShare on $ShareHost.lnk"
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($lnkPath)
$lnk.TargetPath  = $lnkTarget
$lnk.Description = "Software share - $lnkTarget"
$lnk.Save()
Write-Host "  shortcut   = $lnkPath  ->  $lnkTarget"
Add-Result 'Shortcut' ([IO.Path]::GetFileName($lnkPath)) 'OK' "$lnkPath -> $lnkTarget"

# Points at the network copy (not the C:\Scripts staged copy) so re-running
# it always picks up whatever this script currently does.
$setupLnkPath = Join-Path $workDir 'run-mtr_setup.bat - Shortcut.lnk'
$setupLnk = $wsh.CreateShortcut($setupLnkPath)
$setupLnk.TargetPath  = $SetupBat
$setupLnk.Description = "Re-run MTR setup - $SetupBat"
$setupLnk.Save()
Write-Host "  shortcut   = $setupLnkPath  ->  $SetupBat"
Add-Result 'Shortcut' ([IO.Path]::GetFileName($setupLnkPath)) 'OK' "$setupLnkPath -> $SetupBat"

# Root of the share, on the Desktop rather than in _mtrsetup - meant to be
# visible without digging through Downloads.
$desktop         = [Environment]::GetFolderPath('Desktop')
$shareRootTarget = "\\$ShareHost"
$shareRootLnkPath = Join-Path $desktop "$ShareHost share.lnk"
$shareRootLnk = $wsh.CreateShortcut($shareRootLnkPath)
$shareRootLnk.TargetPath  = $shareRootTarget
$shareRootLnk.Description = "MTR share - $shareRootTarget"
$shareRootLnk.Save()
Write-Host "  shortcut   = $shareRootLnkPath  ->  $shareRootTarget"
Add-Result 'Shortcut' ([IO.Path]::GetFileName($shareRootLnkPath)) 'OK' "$shareRootLnkPath -> $shareRootTarget"


# ---------------------------------------------------------------------------
# 8. SOFTWARE INSTALLS
# ---------------------------------------------------------------------------
Write-Section 8 "Software installs"

$softwareFolder = Join-Path $workDir $SoftwareShare
New-Item -Path $softwareFolder -ItemType Directory -Force | Out-Null
Write-Host "  created    = $softwareFolder"
Add-Result 'Software folder' $SoftwareShare 'OK' $softwareFolder

# Extron Teams MTR app - copied down and extracted into the Software folder
$zipName      = [IO.Path]::GetFileName($ExtronMtrZip)
$zipShareRoot = ($ExtronMtrZip -split '\\')[0..3] -join '\'     # -> \\host\share
net use $zipShareRoot /user:"$ShareHost\$ShareUser" "$SharePass" 2>&1 | Out-Null

if (Test-Path $ExtronMtrZip) {
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
    Write-Warning "Source not reachable: $ExtronMtrZip"
    Add-Result 'Extron Teams MTR zip' $zipName 'FAILED' "source not reachable: $ExtronMtrZip"
}

# Logitech Sync installer - straight copy, no extraction needed
$logiName = [IO.Path]::GetFileName($LogiSyncExe)
if (Test-Path $LogiSyncExe) {
    Copy-Item -Path $LogiSyncExe -Destination $softwareFolder -Force
    Write-Host "  copied $logiName -> $softwareFolder" -ForegroundColor Green
    Add-Result 'Logitech Sync installer' $logiName 'OK' "$LogiSyncExe -> $softwareFolder"
} else {
    Write-Warning "Source not reachable: $LogiSyncExe"
    Add-Result 'Logitech Sync installer' $logiName 'FAILED' "source not reachable: $LogiSyncExe"
}

net use $zipShareRoot /delete 2>&1 | Out-Null

# Install whichever of the two isn't already on the machine. Extron runs
# silently via msiexec; LogiSync has no documented silent switch so it's
# launched interactively. Both use -Wait so the end-of-script logoff
# doesn't cut an install (or the tech's wizard) off mid-way.
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

        if ($p.ExitCode -in 0, 3010) {
            Write-Host ("  {0,-42} = installed (exit {1})" -f 'Extron Control', $p.ExitCode) -ForegroundColor Green
            Add-Result 'Extron Control install' "$action (exit $($p.ExitCode))" 'OK' $msiLog
        } else {
            Write-Host ("  {0,-42} = FAILED (exit {1})" -f 'Extron Control', $p.ExitCode) -ForegroundColor Red
            Add-Result 'Extron Control install' "exit $($p.ExitCode)" 'FAILED' "see $msiLog"
        }
    }
}

if (Test-Path (Join-Path $softwareFolder $logiName)) {
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


# ---------------------------------------------------------------------------
# 9. APPEARANCE - wallpaper and colours
# ---------------------------------------------------------------------------
# Applies to the Windows desktop for the account running this (Admin).
# The MTR console theme is separate and untouched.
Write-Section 9 "Appearance"

$shareRoot = ($SourceFile -split '\\')[0..3] -join '\'     # -> \\host\share
net use $shareRoot /user:"$ShareHost\$ShareUser" "$SharePass" 2>&1 | Out-Null

$imgName = [IO.Path]::GetFileName($SourceFile)
if (Test-Path $SourceFile) {
    Copy-Item -Path $SourceFile -Destination $workDir -Force
    Write-Host "  copied $imgName -> $workDir" -ForegroundColor Green
    Add-Result 'Background image' $imgName 'OK' "$SourceFile -> $workDir"
} else {
    Write-Warning "Source not reachable: $SourceFile"
    Add-Result 'Background image' $imgName 'FAILED' "source not reachable: $SourceFile"
}

net use $shareRoot /delete 2>&1 | Out-Null

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
# 10. REMOTE MANAGEMENT (WinRM / PS Remoting)
# ---------------------------------------------------------------------------
Write-Section 10 "Remote management (WinRM)"

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
        Add-Result 'Network category' 'Private' 'OK' "$($p.InterfaceAlias) was Public"
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

# TightVNC: "Hide desktop wallpaper" (Server tab, Miscellaneous) must stay
# unchecked - RemoveWallpaper=0. 32-bit and 64-bit TightVNC builds read this
# from different registry views, so write both; whichever doesn't apply is
# simply unused. Takes effect on the next VNC connection, not the current one.
Set-Reg 'HKLM:\SOFTWARE\TightVNC\Server' 'RemoveWallpaper' 0
Set-Reg 'HKLM:\SOFTWARE\WOW6432Node\TightVNC\Server' 'RemoveWallpaper' 0


# ---------------------------------------------------------------------------
# 11. CLEANUP
# ---------------------------------------------------------------------------
# Unwanted software found on the fleet gets removed here. One entry so far;
# add more the same way as they turn up.
Write-Section 11 "Cleanup"

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
# 12. REPORT
# ---------------------------------------------------------------------------
Write-Host "`n[12] Writing report" -ForegroundColor Cyan

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
$logName  = "$env:COMPUTERNAME-MTR-Applied-Settings.log"
$logPath  = Join-Path $workDir $logName

$report = New-Object System.Text.StringBuilder
function Add-Line { param($t = '') [void]$report.AppendLine($t) }

Add-Line '============================================================'
Add-Line ' MTR Windows standardisation'
Add-Line " Script: v$ScriptVersion"
Add-Line " Run:    $($stamp.ToString('yyyy-MM-dd HH:mm:ss'))"
Add-Line " User:   $env:USERDOMAIN\$env:USERNAME"
Add-Line '============================================================'
Add-Line
Add-Line '--- MACHINE ------------------------------------------------'
Add-Line ("  {0,-22} {1}" -f 'Hostname',     $env:COMPUTERNAME)
Add-Line ("  {0,-22} {1}" -f 'Manufacturer', $cs.Manufacturer)
Add-Line ("  {0,-22} {1}" -f 'Model',        $cs.Model)
Add-Line ("  {0,-22} {1}" -f 'Serial',       $bios.SerialNumber)
Add-Line ("  {0,-22} {1}" -f 'BIOS',         $bios.SMBIOSBIOSVersion)
Add-Line ("  {0,-22} {1}" -f 'Windows',      $winVersion)
Add-Line ("  {0,-22} {1}" -f 'MTR app',      $mtrApp)
Add-Line ("  {0,-22} {1}" -f 'Last boot',    $os.LastBootUpTime)
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
Add-Line '  WinRM is enabled on this machine, but it is a workgroup machine'
Add-Line '  (not domain-joined) - connecting from another PC still needs that'
Add-Line '  PC''s own TrustedHosts set first, e.g. from an elevated prompt there:'
Add-Line "    Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$env:COMPUTERNAME' -Concatenate"
Add-Line '  then connect with -Credential using this machine''s local Admin account.'
Add-Line

Set-Content -Path $logPath -Value $report.ToString() -Encoding UTF8
Write-Host "  report     = $logPath"

# Upload to the share. Not recorded via Add-Result - the report is already
# written, so a result added here would not appear in the file it describes.
$logShareRoot = ($LogShare -split '\\')[0..3] -join '\'
net use $logShareRoot /user:"$ShareHost\$ShareUser" "$SharePass" 2>&1 | Out-Null
try {
    if (-not (Test-Path $LogShare)) { New-Item -Path $LogShare -ItemType Directory -Force -EA Stop | Out-Null }
    Copy-Item -Path $logPath -Destination $LogShare -Force -EA Stop
    Write-Host "  uploaded   = $LogShare\$logName" -ForegroundColor Green
}
catch {
    Write-Warning "Could not upload report to $LogShare - $($_.Exception.Message)"
    Write-Host   "  local copy kept at $logPath" -ForegroundColor Yellow
}
net use $logShareRoot /delete 2>&1 | Out-Null


# ---------------------------------------------------------------------------
# 13. APPLY
# ---------------------------------------------------------------------------
Write-Host "`n[13] Restarting Explorer to apply..." -ForegroundColor Cyan
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }

Write-Host "`nDone. Applied to $env:COMPUTERNAME\$env:USERNAME" -ForegroundColor Green

if ($failed.Count) {
    Write-Host "$($failed.Count) of $($script:Results.Count) settings FAILED:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $($_.Setting) - $($_.Detail)" -ForegroundColor Red }
} else {
    Write-Host "All $($script:Results.Count) settings applied successfully." -ForegroundColor Green
}

Write-Host "`nReport: $logPath`n"
