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
    assets\MTR-MMC-Local.msc           MTR management console (copied to the MTR + Desktop shortcut)
    assets\start2.bin                  Start layout with nothing pinned
    logs\                              reports are uploaded here (created if missing)
\\<ShareHost>\Software\
    7zip\7z2501-x64.msi
    Extron\MTR\ExtronControlforMicrosoftTeamsRooms_2x5x1.zip
    Firefox\Firefox Setup 140.16.0esr.msi
    Logitech\LogiSyncApp-Setup.exe
    Splashtop\Splashtop_Streamer_Windows_DEPLOY_INSTALLER_v<version>_<team code>.exe
    TightVNC\tightvnc-2.8.85-gpl-setup-64bit.msi
```

This folder's `assets\` holds the console, `start2.bin` and a wallpaper to copy across. The
installers are not in git.

Copy `network-settings.example.psd1` to `network-settings.psd1` (git-ignored) and fill in
`ShareHost`, `ShareUser` and `SharePass`: a local account on the file server that can read
the shares and write `logs\`. Use a low-privilege account. Add `VncPassword` if TightVNC will
be freshly installed (VNC honours the first 8 characters; without one a fresh install is
reported FAILED and skipped). Other optional keys in the same file (or matching parameters)
change the share layout, filenames and display-off time.

The share password is stored on each MTR: `network-settings.psd1` is staged to
`C:\Scripts`, and the credential is saved in the Admin account's credential manager so
the shortcuts open without a prompt.

## Run it

On the MTR, signed in as the local **Admin** account, press Win + R and paste:

```
\\<ShareHost>\MTR\mtr_setup_network\run-mtr_setup.bat
```

Add `-noprompt` to skip the software tick-box and use the default selection, or `-debug` for
extra `[diag]` lines. The launcher copies the script and settings to `C:\Scripts` first, then
elevates and runs that local copy (an elevated session does not inherit the share
credentials, so everything on the share is read before the UAC prompt). Ignore the "CMD does
not support UNC paths" warning.

The setup prompt appears first: untick software you don't want and choose how long before
the display turns off (default 3 minutes). **Config + Software** installs what is ticked,
**Config Only** installs nothing but still applies the display setting, and **Cancel** (or
closing the window) stops the script before anything is changed. Tick **Overwrite Hostname**
to be asked for a new hostname even when the PC already has a real name; a hostname prompt
also appears for a Windows default name (`DESKTOP-xxxxxxx`). Both prompts carry on with their
defaults after 60 seconds if nobody touches them.

When it finishes it restarts Explorer, uploads the report, and after 120 seconds logs the
user off - or restarts the MTR instead if a restart is pending (for example after a hostname
change). If the settings file is missing or incomplete, or Cancel is pressed, it stops
without applying anything and without logging off.

## What it does

The same as the [portable edition](../mtr_setup_portable/README.md): the same settings,
software installs, taskbar and Start pins, default browser, Store app removal, audio setup,
prompts and restart handling. Only the plumbing differs:

- **Files come from the share:** the installers, wallpaper, MTR console and `start2.bin` are
  read from the share instead of from a stick.
- **Report:** written to `<hostname>_Applied-Settings.log` in `Downloads\_mtrsetup` and
  uploaded to `<ToolShare>\logs`.
- **Shortcuts:** in `Downloads\_mtrsetup` it adds a link to the software share and a re-run
  link to `run-mtr_setup.bat`, and puts a link to the share root on the Desktop. The share
  credential is stored for the Admin account so they open without a prompt.
- **Display-off default:** 3 minutes (the portable edition defaults to 20).
## working_files

Small tools used while developing the script. They need a real desktop session on the MTR.

| Script | What it does |
|---|---|
| `dump-settings-ui.ps1` | Prints the UI Automation tree of the open Settings window, to find control names and AutomationIds |
| `find-setting-key.ps1` | Snapshots registry keys, waits while you flip a setting by hand, and prints what changed |
| `set-start-folders.ps1` | Turns on Start folder toggles through the Settings app. Older than the version inside the portable script, which also handles the collapsed navigation pane on Windows 11 23H2 |
