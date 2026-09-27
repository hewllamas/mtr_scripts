# Installers

The installers are not in git (vendor-licensed, and some are over GitHub's 100 MB file
limit). Put each one in its own folder here; the script finds them by these names.

| Folder | File | Where to get it |
|---|---|---|
| `7-Zip/` | `7z2501-x64.msi` | 7-zip.org, 64-bit MSI |
| `Extron/` | `ExtronControlforMicrosoftTeamsRooms_2x5x1.zip` | Extron's download page for Extron Control for Microsoft Teams Rooms |
| `Firefox/` | `Firefox Setup 140.16.0esr.msi` | Mozilla's enterprise downloads, Firefox ESR, 64-bit MSI |
| `Logitech/` | `LogiSyncApp-Setup.exe` | Logitech Sync download page |
| `Splashtop/` | `Splashtop_Streamer_Windows_DEPLOY_INSTALLER_v<version>_<code>.exe` | Your Splashtop admin console, deployment section |
| `TightVNC/` | `tightvnc-2.8.85-gpl-setup-64bit.msi` | tightvnc.com, 64-bit MSI |

The names above are the defaults in the parameter block of `mtr-windows-settings.ps1`. If
you use a different version, edit the default or pass the matching parameter (`-SevenZipMsi`,
`-ExtronMtrZip`, `-FirefoxMsi`, `-LogiSyncExe`, `-VncMsi`).

Splashtop is found by pattern, so any `Splashtop_Streamer_Windows_DEPLOY_INSTALLER_*.exe`
in `Splashtop/` works. Its filename carries your team's deployment code - don't rename it,
and don't commit it.
