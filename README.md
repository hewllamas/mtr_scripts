# mtr_scripts

Scripts for setting up and managing Windows-based Microsoft Teams Rooms (MTR) devices.

| Folder | What it is |
|---|---|
| [`mtr_setup_portable/`](mtr_setup_portable/) | Standardises Windows settings and installs software on an MTR NUC, run from a USB stick with no network needed |
| [`mtr_setup_network/`](mtr_setup_network/) | The same, run from a file share: installers and wallpaper come from the share and each report is uploaded back to it |

Vendor installers, passwords, share details and run logs are git-ignored - see each
folder's README for what to add before running.

These scripts change system settings. Try them on a spare device before a production room.
