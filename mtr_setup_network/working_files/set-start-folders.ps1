<#
    set-start-folders.ps1

    Turns on Start > Folders toggles via UI Automation. This build does not
    read the equivalent registry values - HKCU Explorer\Advanced and the
    HKLM GPO path were both tested and confirmed inert, so this drives the
    actual Settings app instead.

    Needs a real desktop session - cannot run headless. Opens Settings
    itself and leaves it open at the end so the result is visible.
#>

param(
    [string[]]$Folders = @('Settings', 'Downloads')
)

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# AutomationId for every toggle on the Folders page, captured from a live
# dump from a test MTR.
$Ids = @{
    'Settings'        = 'SystemSettings_Start_PlacesSettings_ToggleSwitch'
    'File Explorer'   = 'SystemSettings_Start_PlacesFileExplorer_ToggleSwitch'
    'Documents'       = 'SystemSettings_Start_PlacesDocuments_ToggleSwitch'
    'Downloads'       = 'SystemSettings_Start_PlacesDownloads_ToggleSwitch'
    'Music'           = 'SystemSettings_Start_PlacesMusic_ToggleSwitch'
    'Pictures'        = 'SystemSettings_Start_PlacesPictures_ToggleSwitch'
    'Videos'          = 'SystemSettings_Start_PlacesVideos_ToggleSwitch'
    'Network'         = 'SystemSettings_Start_PlacesNetwork_ToggleSwitch'
    'Personal folder' = 'SystemSettings_Start_PlacesUserProfile_ToggleSwitch'
}

function Get-SettingsWindow {
    $proc = Get-Process -Name 'ApplicationFrameHost' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq 'Settings' } |
            Select-Object -First 1
    if ($proc) { return [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle) }
    return $null
}

Write-Host "Opening Settings..." -ForegroundColor Cyan
Start-Process 'ms-settings:personalization-start'

$root = $null
for ($i = 0; $i -lt 20 -and -not $root; $i++) {
    Start-Sleep -Milliseconds 500
    $root = Get-SettingsWindow
}
if (-not $root) {
    Write-Host "Settings window did not appear within 10 seconds." -ForegroundColor Red
    exit 1
}

# Navigate to the Folders page by clicking the "Folders" row on the Start page
$foldersRowCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Folders'))
)
$foldersRow = $null
for ($i = 0; $i -lt 20 -and -not $foldersRow; $i++) {
    Start-Sleep -Milliseconds 500
    $foldersRow = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $foldersRowCond)
}
if (-not $foldersRow) {
    Write-Host "Could not find the Folders row on the Start page - is it already navigated somewhere else?" -ForegroundColor Red
    exit 1
}

$foldersRow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Seconds 1

foreach ($name in $Folders) {
    $autoId = $Ids[$name]
    if (-not $autoId) { Write-Host "  $name - unknown folder name, skipping" -ForegroundColor Red; continue }

    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $autoId)
    $toggle = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $toggle) {
        Write-Host "  $name : NOT FOUND (AutomationId=$autoId) - page layout may have changed" -ForegroundColor Red
        continue
    }

    try {
        $pattern = $toggle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($pattern.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) {
            Write-Host "  $name : already On" -ForegroundColor Green
        } else {
            $pattern.Toggle()
            Write-Host "  $name : turned On" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  $name : Toggle pattern not supported - clicked instead, verify manually" -ForegroundColor Yellow
        $toggle.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
}

Write-Host "`nDone. Settings left open on the Folders page - check it looks right." -ForegroundColor Cyan
