<#
    dump-settings-ui.ps1

    Dumps the UI Automation tree of the Settings app window so we can find the
    exact name/AutomationId of a control without guessing.

    Usage on the MTR:
      1. Open Settings and navigate to the page you care about
         (Personalization > Start > Folders).
      2. Run this script. It finds the Settings window and prints every
         element that has a Name or AutomationId.
      3. Paste the output back.
#>

<#
    Settings is a UWP app - it does not own its own top-level window. The
    visible window belongs to ApplicationFrameHost, which hosts it, so we
    have to find that window by title rather than by the app's process name.
#>
param(
    [string]$WindowTitle = 'Settings'
)

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$proc = Get-Process -Name 'ApplicationFrameHost' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq $WindowTitle } |
        Select-Object -First 1

if (-not $proc) {
    Write-Host "No ApplicationFrameHost window titled '$WindowTitle' found. Open Settings and navigate to the page first." -ForegroundColor Red
    exit 1
}

$root = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
Write-Host "Window: $($root.Current.Name)`n" -ForegroundColor Cyan

function Show-Tree {
    param($Element, $Depth = 0)
    $name   = $Element.Current.Name
    $type   = $Element.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
    $autoId = $Element.Current.AutomationId

    if ($name -or $autoId) {
        Write-Host ('{0}[{1}] Name=''{2}'' AutomationId=''{3}''' -f ('  ' * $Depth), $type, $name, $autoId)
    }

    $children = $Element.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($child in $children) {
        Show-Tree -Element $child -Depth ($Depth + 1)
    }
}

Show-Tree -Element $root
