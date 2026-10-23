# mtr_setup_portable

Standardises Windows settings on a Microsoft Teams Rooms (MTR) NUC and installs the
software you tick, entirely from this folder. Copy it to a USB stick, plug it into the
MTR and run `run-mtr_setup.bat`. No network share or internet is needed.

## Before you run it

1. **Installers** - drop them in `assets/Software/<vendor>/`. They are not in git; see
   [`assets/Software/README.md`](assets/Software/README.md) for the expected files.
2. **VNC password** - only needed if TightVNC will be freshly installed. Put it on the
   first line of `vnc-password.txt` next to the script (git-ignored), or pass
   `-VncPassword`. VNC only honours the first 8 characters. With no password, a fresh
   TightVNC install is reported as FAILED and skipped; nothing else is affected.
3. **Wallpaper** - `assets/AV-OOS-BG-Blue.png` is used by default. Replace the image or
   pass `-SourceFile`.

## Run it

Sign in to the MTR as the local **Admin** account, plug the stick in and double-click
`run-mtr_setup.bat` (it asks for admin rights itself). Leave the stick in until the run
ends, and leave the keyboard alone while it runs - the Start folders step sends
keystrokes to open Settings.

The settings and installs run, then the report is written and, 120 seconds after the
summary, the MTR logs off - or restarts instead if a restart is pending (for example after
a hostname change or an installer asking for one).

The HKCU settings apply to the account that runs the script (Admin), not to the Skype/MTR
auto-logon account.

### Prompts at the start

1. **Setup** - untick software you don't want and choose how long before the display turns
   off (default 20 minutes). **Config + Software** installs what is ticked; **Config Only**
   installs nothing but still applies the display setting; **Cancel** (or closing the
   window) stops the script before anything is changed. If nobody touches it, it carries on
   with what's ticked after 60 seconds. Tick **Overwrite Hostname** to be asked for a new
   hostname even when the PC already has a real name.
2. **Hostname** - only if the PC still has a Windows default name (`DESKTOP-xxxxxxx`), or
   if Overwrite Hostname is ticked. Type a new name and click Rename; it takes effect after a
   restart. If nobody types, it keeps the current name after 60 seconds.

Everything starts ticked except **Splashtop Streamer**, and on **Yealink** MTRs also
**Extron Control** and **Logitech Sync**. Software already installed at the same or a
newer version is left alone.

### Options

```
run-mtr_setup.bat -noprompt      no windows: use the default selection, keep the hostname
run-mtr_setup.bat -debug         extra [diag] lines in the console
```

Running the `.ps1` directly from an elevated prompt also accepts:

| Parameter | Effect |
|---|---|
| `-Install Extron,TightVNC` | install only these (matches the start of the name), no prompt |
| `-NewHostname NAME` | rename a default-named PC without asking |
| `-VncPassword` | TightVNC password (see above) |
| `-DisplayTimeoutMinutes N` | display-off time, `0` = never |
| `-PromptSeconds N` | how long the prompts wait before carrying on |

## What it changes

| Section | Settings |
|---|---|
| Hostname | Renames a `DESKTOP-xxxxxxx` name, or any name if Overwrite Hostname is ticked (NetBIOS rules checked) |
| Start menu | Turns off recent files, recommendations, most-used apps, recently added apps, tips and account notifications; hides the Recommended section; empties the Pinned grid (swaps in `assets/start2.bin`); shows Settings and Downloads beside the power button |
| File Explorer | Shows file extensions |
| Power | Never sleeps or hibernates; display off after N minutes; USB selective suspend, hybrid sleep and PCIe link-state power management off; USB power saving off per device; Modern Standby disabled; wake enabled for the HID presence sensor and touch screen when present |
| Shortcuts and folders | Creates `Downloads\_mtrsetup` with a Desktop shortcut to it, copies `MTR-MMC-Local.msc` there and adds a Desktop shortcut for it |
| Software installs | See below |
| Default browser | Makes Firefox the default for http, https, .htm and .html through a default associations file named by policy; applies at the next sign-in |
| Taskbar | Hides search and Task view, removes Widgets, shows all tray icons, left-aligned, no badges or flashing, one taskbar, always combine, auto-hide off; clears every default pin and pins File Explorer, the MTR console, Settings, Firefox, Yealink Room Connect (Yealink only) and Logitech Sync (the last three only if installed) |
| Appearance | Wallpaper (Fill), dark mode, automatic accent colour |
| Remote management | Sets Public network interfaces to Private, enables PS Remoting and WinRM, allows ping; turns TightVNC "hide desktop wallpaper" and "serve Java viewer" off |
| Audio | Makes the Echo Cancelling Speakerphone (or a QSYS DSP shown as `DSP`) the only output - renamed Room Audio Output, volume 60, default - and its input Room Mics (volume 100, default communications); the content capture input is renamed Content Capture Input (volume 100, default); every other active or unplugged audio device is disabled. Nothing is changed if no speakerphone is found |
| Cleanup | Removes the Xbox, WhatsApp, Solitaire and LinkedIn Store apps (deprovisioned first, so new profiles do not get them) and TeamViewer if present |

Taskbar pins are set with a layout file (`C:\ProgramData\MTR-Setup\TaskbarLayout.xml`) and
the per-user Start Layout policy, and appear when Explorer restarts at the end of the run. Before that restart the saved pins under Taskband are cleared, because Explorer otherwise ignores the layout file once it has pins of its own.

The Pinned grid is emptied by copying `assets/start2.bin` (a `start2.bin` captured from an MTR with everything unpinned) into the Start menu's LocalState folder. Without that file the step is skipped.

### Software

| Software | How it installs | If already installed |
|---|---|---|
| 7-Zip | silent MSI | same or newer is skipped, older is upgraded |
| Extron Control for MS Teams Rooms | zip unpacked, silent MSI | same or newer is skipped, older is upgraded |
| Firefox ESR | silent MSI | same or newer is skipped, older is upgraded |
| Logitech Sync | installer launched with its normal window - someone has to click through it, and the script waits | skipped |
| Splashtop Streamer | silent deploy installer | same or newer is skipped, older is upgraded |
| TightVNC | silent MSI with the configured password | skipped, so an existing config is never overwritten |

An installer that fails is reported as FAILED with its log in `Downloads\_mtrsetup\Software`,
and the remaining installs carry on. Splashtop's installer carries the team deployment code
in its filename - don't rename it.

## Reports

Each run writes `<hostname>_Applied-Settings.log` to `logs/` on the stick and to
`Downloads\_mtrsetup` on the MTR: machine details, every setting with OK / SKIP / FAILED,
and notes. The script version is `$ScriptVersion` in `mtr-windows-settings.ps1`.

## Tested on

Yealink MCore 4 running Windows 11 IoT Enterprise 23H2 (22631) and 25H2 (26200) with the
Teams Rooms app 5.6.

## Notes

- The Start folders toggles are set by driving the Settings app with UI Automation, because
  the Teams Rooms shell intercepts `ms-settings:` links and the registry values for those
  toggles are not honoured by the running shell. The step maximises Settings, opens the
  navigation pane if it is collapsed, and finds the Folders row by its automation id.
- Detection of installed software uses the installed-programs list (machine-wide and the
  Admin account's own).
