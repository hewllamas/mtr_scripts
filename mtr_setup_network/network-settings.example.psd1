# Copy this file to network-settings.psd1 (git-ignored) next to the script and fill it in.
# Any key that matches a parameter of mtr-windows-settings.ps1 sets it, so the optional
# lines below can override the share layout. Parameters passed on the command line win.
@{
    ShareHost = 'fileserver'    # file server holding the installers and receiving reports
    ShareUser = 'setupuser'     # local account on that server (used as fileserver\setupuser)
    SharePass = 'change-me'     # its password

    # ToolShare     = 'MTR\mtr_setup_network'   # path under \\ShareHost holding run-mtr_setup.bat, assets\ and logs\
    # SoftwareShare = 'Software'                # share holding the installers
    # DisplayTimeoutMinutes = 3
}
