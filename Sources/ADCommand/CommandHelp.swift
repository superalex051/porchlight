import ADModel

/// What `help` prints. The CLI prints it itself, without the app, so asking for help never starts the
/// app or runs the command it came with. The engine answers `help` with the same text for other callers.
public enum CommandHelp {
    /// True if the arguments ask for help anywhere: `help` as an operation, or `--help`, `-help` or `-h`.
    /// So `porchlight rescue --help` explains `rescue` rather than running it.
    public static func isRequested(_ request: CommandRequest) -> Bool {
        request.operations.contains("help")
            || request.parameters.contains { ["help", "h"].contains($0.name.lowercased()) }
    }

    public static let text = """
        porchlight: start and end remote sessions with a virtual screen through the Porch Light app.

        Usage: porchlight <operation> [-<parameter>[=<value>]]... [--json] [--no-launch] [--timeout=<s>]
        Parameter names ignore case, and -name and --name mean the same. Quote a value with spaces.

        Sessions: a virtual screen becomes the main display, and the monitors stay off until the end
          session start [-client=<name>] [-lookslike=<W>x<H>] [-hidpi=on|off] [-hz=<n>] [-preset=<name>]
                        [-ownerpid=<pid>]... [-keepon=<UUID>]...
              Defaults: -client=default -lookslike=1728x1080 -hidpi=on -hz=60. Width 640 to 3840,
              height 360 to 2400, hz 24 to 240. The session ends if any -ownerpid process exits.
              -keepon leaves that monitor on. A start from the client that holds the session keeps
              its size and adds the owners.
          session resize -lookslike=<W>x<H> [-hidpi=on|off] [-hz=<n>]
          session resize -hz=<n>                Only the refresh rate. The size stays.
          session resize -preset=<name>
          session end [-client=<name>] [-force]
              Brings the monitors back. With no session it does nothing and succeeds. -force ends a
              session that another client holds.
          session status                        One line: state=idle, or the state, client, screen and size.
          session watch                         The status line, then a new one each time the session
                                                changes, until the app quits (exit 0). With --json, each
                                                line is the same JSON as session status --json.
          session presets                       The saved sizes, from presets.json, which you can edit.

        Size per device: a Parsec session gets a size for the device that connected
          session start -client=parsec -preset=auto [-ownerpid=<pid>]...
              For the newest Parsec connect, under a minute old: with auto size on, the preset of its
              address in clients.json. Otherwise, with match on, a HiDPI screen at half the size its
              client reported, which Parsec saves in ~/.parsec/config.json. Otherwise MacBook 14.
          clients list                          The settings, then each device and its preset.
          clients set -name=<name> -address=<IP> -preset=<name>
                                                Add a device, or change the one with that name.
          clients remove -name=<name>
          clients auto -on|-off                 Presets by address on or off. It starts off.
          clients match -on|-off                Match the size the client reported. It starts on.
          clients notch -on|-off                Trim a phone (wider than 2:1) to 28:15, so its notch falls
                                                in the black bars. It starts on.
          clients room -factor=<n>/<d>          A phone's extra room, 1/1 to 2/1. It starts at 4/3.

        Rescue
          rescue                                End any session and bring every monitor back. If the app
                                                doesn't answer, the restore helper does it without the app.
                                                Control-Option-Command-Escape asks the app for the same.

        Displays
          get <selector> -<key>...              Print values, joined by commas in the order asked.
          set <selector> -<key>=<value>...      Change values. Prints nothing on success.
          get -identifiers                      Every display, as JSON.
            Selectors: -UUID=, -displayID=, -name=, -nameLike= (or -n=), -originalName=, -tagID=,
                       -type=Display|VirtualScreen, -displayWithMainStatus
            Keys: -connected, -main, -placement, -resolution, -refreshRate, -hiDPI, -pinRefreshRate
            Values for set: -connected=on|off, -main=on, -placement=<x>x<y>, -resolution=<W>x<H>,
                       -refreshRate=<Hz>, -hiDPI=on|off, -pinRefreshRate=<Hz>|off
            With no selector: get -launchAtLogin, get -spiReport, set -launchAtLogin=on|off

        Virtual screens, kept until discarded
          create -type=VirtualScreen -virtualScreenName=<name> [-virtualScreenHiDPI=on|off]
                 [-useResolutionList=on -resolutionList=<W>x<H>,...]
          discard <selector>                    Delete a screen. With --force and no selector, every one.

        App
          ping                                  Check that the app is answering.
          quit                                  End any session and quit the app.
          help                                  Show this text.

        Options
          --json                One line of JSON with ok, payload, reason, warning and json.
          --no-launch           If the app isn't running, fail rather than start it.
          --timeout=<seconds>   How long to wait for the app. 15 by default, 60 for session operations.

        Output: the answer on stdout and exit 0, or "Failed." and a reason on stderr and exit 1.
        A bare "Failed." means a display, key or value wasn't recognized. A "warning:" line on stderr
        comes with a success. Session events are logged in ~/Library/Logs/PorchLight/session.log.

        Examples
          porchlight session start -client=parsec -lookslike=1728x1080 -ownerpid=$$
          porchlight session resize -preset="MacBook 14 Sharpest"
          porchlight session end -client=parsec
          porchlight get -displayWithMainStatus -resolution -refreshRate
        """
}
