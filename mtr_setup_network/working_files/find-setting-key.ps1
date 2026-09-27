<#
    find-setting-key.ps1

    Finds which registry value a Settings toggle actually controls, by
    snapshotting before and after you flip it by hand. Recurses into every
    subkey under each root, not just the root itself.

    Usage on the MTR:
      1. Run this script. It snapshots the relevant keys and waits.
      2. Flip the setting in the Settings app.
      3. Press any key back in this window.
      It prints every value that changed.
#>

param(
    [string[]]$Paths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer',
        'HKCU:\Control Panel\Desktop',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
    )
)

# Subkey names to not even descend into - shellbag / MRU / jump-list caches
# that can run into thousands of entries and have nothing to do with a
# Settings toggle.
$Noisy = 'BagMRU', 'StreamMRU', 'RecentDocs', 'UserAssist', 'ShellNoRoam',
         'TypedPaths', 'RunMRU', 'WordWheelQuery', 'FileExts', 'ComDlg32',
         'Streams', 'Discardable', 'Classes', 'MuiCache'

function Get-Snapshot {
    param($Paths)
    $snap    = @{}
    $queue   = New-Object System.Collections.Generic.Queue[string]
    $visited = 0
    $Paths | Where-Object { Test-Path $_ } | ForEach-Object { $queue.Enqueue($_) }

    while ($queue.Count) {
        $p = $queue.Dequeue()
        $item = Get-Item -Path $p -ErrorAction SilentlyContinue
        if (-not $item) { continue }

        foreach ($name in $item.Property) {
            try { $snap["$p|$name"] = (Get-ItemProperty -Path $p -Name $name -ErrorAction Stop).$name }
            catch { }
        }

        Get-ChildItem -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -notin $Noisy } |
            ForEach-Object { $queue.Enqueue($_.PSPath) }

        $visited++
        if ($visited % 1000 -eq 0) { Write-Host "." -NoNewline }
    }
    Write-Host ""
    return $snap
}

Write-Host "Snapshotting (recursive):" -ForegroundColor Cyan
$Paths | ForEach-Object { Write-Host "  $_" }
Write-Host "  ...this may take a few seconds"
$before = Get-Snapshot $Paths
Write-Host "  $($before.Count) values captured"

Write-Host "`nNow flip the setting in the Settings app, then press any key here..." -ForegroundColor Yellow
[void][System.Console]::ReadKey($true)

$after = Get-Snapshot $Paths

Write-Host "`nChanged values:" -ForegroundColor Cyan
$keys = ($before.Keys + $after.Keys) | Select-Object -Unique
$found = $false
foreach ($k in $keys) {
    $b = $before[$k]
    $a = $after[$k]
    if ("$b" -ne "$a") {
        $found = $true
        $path, $name = $k -split '\|', 2
        Write-Host "  $path" -ForegroundColor Green
        Write-Host "    $name : $b -> $a"
    }
}
if (-not $found) {
    Write-Host "  none of the watched keys changed - the setting lives somewhere else." -ForegroundColor Red
    Write-Host "  Add its likely path to -Paths and try again."
}
