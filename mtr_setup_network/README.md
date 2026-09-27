# mtr_setup_network

The network edition of the MTR setup script. It standardises Windows settings on a
Microsoft Teams Rooms (MTR) NUC like the [portable edition](../mtr_setup_portable/README.md),
but reads its installers and wallpaper from a file share and uploads each run's report
back to that share, so a fleet of MTRs can be done from one place.

Use the portable edition when there is no share (or for a customer's network).

## Set up the share

Any Windows file server the MTRs can reach works. With the defaults it needs:

```
\\<ShareHost>\MTR\mtr_setup_network\
    run-mtr_setup.bat
    mtr-windows-settings.ps1
    network-settings.psd1              your copy of network-settings.example.psd1
    assets\wallpaper.png               desktop wallpaper
    logs\                              reports are uploaded here (created if missing)
\\<ShareHost>\Software\
    Extron\MTR\ExtronControlforMicrosoftTeamsRooms_2x5x1.zip
    Logitech\LogiSyncApp-Setup.exe
```

Copy `network-settings.example.psd1` to `network-settings.psd1` (git-ignored) and fill in
`ShareHost`, `ShareUser` and `SharePass`: a local account on the file server that can read
the shares and write `logs\`. Use a low-privilege account. Optional keys in the same file
(or matching parameters) change the share layout, filenames and display-off time.

The share password is stored on each MTR: `network-settings.psd1` is staged to
`C:\Scripts`, and the credential is saved in the Admin account's credential manager so
the shortcuts open without a prompt.

## Run it

On the MTR, signed in as the local **Admin** account, press Win + R and paste:

```
\\<ShareHost>\MTR\mtr_setup_network\run-mtr_setup.bat
```

Add `-debug` for extra `[diag]` lines. The launcher copies the script and settings to
`C:\Scripts` first, then elevates and runs that local copy (an elevated session does not
inherit the share credentials, so everything on the share is read before the UAC prompt).
Ignore the "CMD does not support UNC paths" warning.

When it finishes it restarts Explorer, uploads the report, and logs the user off after 120
seconds. If the settings file is missing or incomplete it stops with a message and applies
nothing.

## What it does

The same Windows settings as the portable edition - Start menu, File Explorer, power,
taskbar, appearance, WinRM / ping and TeamViewer removal (see the portable README for the
list) - with these differences:

- No prompts: it installs both installers below, and display-off defaults to 3 minutes
  (`-DisplayTimeoutMinutes`).
- **Installs:** Extron Control for Microsoft Teams Rooms (zip unpacked, silent MSI,
  upgraded when older, skipped when the same or newer) and Logitech Sync (its installer is
  launched with its normal window when not already installed).
- **TightVNC:** sets "hide desktop wallpaper" off in the registry; it doesn't install it.
- **Shortcuts:** in `Downloads\_mtrsetup` it adds a link to the software share and a
  re-run link to `run-mtr_setup.bat`, and puts a link to the share root on the Desktop.
- **Report:** written to `Downloads\_mtrsetup` and uploaded to `<ToolShare>\logs`.
- No hostname rename, no taskbar pins, and no restart-instead-of-log-off logic - those are
  portable-edition features.

## working_files

Small tools used while developing the script. They need a real desktop session on the MTR.

| Script | What it does |
|---|---|
| `dump-settings-ui.ps1` | Prints the UI Automation tree of the open Settings window, to find control names and AutomationIds |
| `find-setting-key.ps1` | Snapshots registry keys, waits while you flip a setting by hand, and prints what changed |
| `set-start-folders.ps1` | Turns on Start folder toggles through the Settings app. Older than the version inside the portable script, which also handles the collapsed navigation pane on Windows 11 23H2 |
