import ADEngine
import ADFoundation
import ADInput
import ADModel
import ADUI
import AppKit
import ServiceManagement
import UserNotifications

nonisolated private let log = ADLog.logger("app")

/// What the command line asks for. `--wait-for-pid=<pid>` comes from a restart, and `--safe` from a
/// person or `Scripts/run.sh`. Anything else is ignored, because the system can add arguments of its own.
private struct LaunchOptions {
    var safeMode: Bool
    var waitForPID: pid_t?

    init(arguments: [String]) {
        safeMode = arguments.contains("--safe")
        let prefix = "--wait-for-pid="
        if let value = arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count),
            let pid = pid_t(value), pid > 0
        {
            waitForPID = pid
        }
    }
}

/// The app's whole life. Everything it calls is tested in its own module, so this only puts them in order.
@main
enum AppMain {
    /// Longer than a restarting copy can take to exit, which is `AppDelegate.restartExitSeconds`. A copy
    /// still there after this holds the lock, so this one finds that out and exits quietly.
    private static let oldCopyWaitSeconds = 15.0

    static func main() {
        let options = LaunchOptions(arguments: CommandLine.arguments)
        // This much first, because it's how the system learns the app has launched, and the copy that
        // opened this one may be waiting to hear that before it exits.
        let application = NSApplication.shared

        // Before the hotkeys, so a restart can't conflict with its own exiting copy. Blocking is safe
        // here, because no hotkey or menu exists yet that would need this thread.
        if let pid = options.waitForPID { waitForExit(of: pid) }

        let shiftHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        let isTestSetup = EngineRuntime.isTestSetup(ProcessInfo.processInfo.environment)
        let delegate = AppDelegate(safeMode: options.safeMode || shiftHeld, isTestSetup: isTestSetup)
        if isTestSetup {
            log.notice("A test setup leaves the emergency hotkeys to the real app")
        } else {
            delegate.registerHotkeys()
        }
        application.delegate = delegate
        // The application only holds its delegate weakly.
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func waitForExit(of pid: pid_t) {
        guard pid != getpid() else { return }
        let deadline = Date().addingTimeInterval(oldCopyWaitSeconds)
        // Signal 0 sends nothing. It only asks whether the process is there.
        while kill(pid, 0) == 0 || errno != ESRCH {
            guard Date() < deadline else {
                log.error("The copy being restarted hasn't exited, so this one is going on anyway")
                return
            }
            usleep(50_000)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// How long a restart waits to hear that the new copy launched. The system may hold that answer until
    /// the new copy checks in, and the new copy may be waiting for this one to exit, so this can't wait
    /// forever. It's shorter than `AppMain.oldCopyWaitSeconds`.
    private static let restartExitSeconds = 5.0
    /// So the answer to a `quit` command gets out before the socket closes.
    private static let quitReplySeconds = 0.2
    /// Twice the engine's own 10 second limit on ending a session at quit.
    private static let terminateLimitSeconds = 20.0

    private let safeMode: Bool
    /// A dry run, or a setup that refused to start. See `EngineRuntime.isTestSetup`.
    private let isTestSetup: Bool
    /// For the app's whole life, because releasing it removes every key it registered.
    private let hotkeys = CarbonHotkeyRegistry()

    private var runtime: EngineRuntime?
    private var statusItem: StatusItemController?
    /// Made the first time Edit Presets... is chosen.
    private var presetsWindow: PresetsWindowController?
    private var startFailure: String?
    private var isTerminating = false
    private var hasRepliedToTerminate = false
    private var terminateLimit: Timer?
    private var restartFallback: Task<Void, Never>?

    init(safeMode: Bool, isTestSetup: Bool) {
        self.safeMode = safeMode
        self.isTestSetup = isTestSetup
    }

    // MARK: Launch

    /// A throw here doesn't stop the launch. `EmergencyHotkeys` has already logged each key that failed,
    /// each key that worked is still a way out, and one in conflict starts working once the other process
    /// lets go. Presses come in off the main thread, so each action only hops over and returns.
    func registerHotkeys() {
        do {
            try EmergencyHotkeys.register(
                on: hotkeys,
                rescue: { Task { @MainActor in self.rescue() } },
                restart: { Task { @MainActor in self.restart() } },
                quit: { Task { @MainActor in self.quit() } }
            )
        } catch {
            log.error("Going on without every emergency hotkey")
        }
    }

    /// Not earlier, because the engine needs the run loop.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never shown, but it's where the presets window's Command-C, Command-W and the rest are found.
        NSApp.mainMenu = MainMenu.make()
        let runtime = EngineRuntime(environment: ProcessInfo.processInfo.environment, safeMode: safeMode)
        self.runtime = runtime
        runtime.dispatcher.onQuit = { [weak self] in self?.quitAfterReplying() ?? nil }
        // On a turn of its own, because a rebuild reads a file and asks the system about the login item,
        // and this is called from the middle of a session step.
        runtime.onSessionChange = { [weak self] in Task { self?.statusItem?.reload() } }

        Task {
            do {
                try await runtime.start()
            } catch EngineRuntimeError.alreadyRunning {
                exit(0)
            } catch EngineRuntimeError.refused(let why) {
                // A test setup's own words, which name variables and never a path.
                log.error("The engine refused this setup: \(why, privacy: .public)")
                startFailure = "Not running: \(why)"
            } catch {
                // Not the error's own words, which can include a path from the environment.
                let failure = error as NSError
                log.error("The engine couldn't start: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
                startFailure = "Not running: can't set up the state directory, its lock or the socket"
            }
            if !isTerminating { showStatusItem() }
        }
    }

    private func showStatusItem() {
        statusItem = StatusItemController(
            title: StatusMenuModel.statusItemTitle(dryRun: isTestSetup),
            description: StatusMenuModel.statusItemDescription(dryRun: isTestSetup),
            content: { [weak self] in self?.menuItems() ?? [] },
            perform: { [weak self] in self?.perform($0) }
        )
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Menu

    private func menuItems() -> [StatusMenuItem] {
        guard let runtime else { return [] }
        var items = StatusMenuModel.build(
            status: runtime.session.status(),
            presets: runtime.presets,
            safeMode: safeMode,
            launchAtLogin: runtime.launchAtLoginIsEnabled,
            dryRun: isTestSetup
        )
        if let startFailure, !items.isEmpty { items[0].title = startFailure }
        return items
    }

    private func perform(_ action: StatusMenuAction) {
        switch action {
        case .endSession:
            run(
                action,
                ["session", "end"],
                [CommandParameter(name: "force"), CommandParameter(name: "reason", value: "End Session in the status menu")]
            )
        case .reconnectAll:
            rescue()
        case .editPresets:
            showPresets()
        case .toggleLaunchAtLogin:
            toggleLaunchAtLogin()
        case .restart:
            restart()
        case .quit:
            quit()
        case .selectPreset(let name):
            run(action, ["session", "resize"], [CommandParameter(name: "preset", value: name)])
        case .selectRefreshRate(let hz):
            // The rate alone, so the session keeps its size, as it is when this resize gets its turn.
            run(action, ["session", "resize"], [CommandParameter(name: "hz", value: String(hz))])
        case .none:
            break
        }
    }

    private func rescue() {
        run(.reconnectAll, ["rescue"])
    }

    /// Through the runtime's own files, so a dry run edits its copy. A save applies the next time the
    /// menu, `-preset=` or `-preset=auto` reads the presets, since each reads the file then.
    private func showPresets() {
        guard let runtime else { return }
        let controller = presetsWindow ?? PresetsWindowController(library: runtime.presetLibrary)
        presetsWindow = controller
        controller.show()
    }

    /// Returns at once. A failure, or a success with a warning, goes to a notification, because there's
    /// no window here to show it in.
    private func run(_ action: StatusMenuAction, _ operations: [String], _ parameters: [CommandParameter] = []) {
        guard let runtime else {
            log.error("A command came before the engine was built")
            return
        }
        Task {
            let result = await runtime.dispatcher.handle(CommandRequest(operations: operations, parameters: parameters))
            if let notice = StatusNotice.after(action, ok: result.ok, reason: result.reason, warning: result.warning) {
                post(notice)
            }
            statusItem?.reload()
        }
    }

    /// Goes through the command, so a dry run stays in its own copy. `requiresApproval` can come with an
    /// error or without one, and either way the person has to say yes in System Settings.
    private func toggleLaunchAtLogin() {
        guard let runtime else { return }
        let wanted = !runtime.launchAtLoginIsEnabled
        Task {
            let result = await runtime.dispatcher.handle(
                CommandRequest(
                    operations: ["set"],
                    parameters: [CommandParameter(name: "launchAtLogin", value: wanted ? "on" : "off")]
                )
            )
            if wanted, !runtime.isDryRun, SMAppService.mainApp.status == .requiresApproval {
                post(.launchAtLoginNeedsApproval)
                SMAppService.openSystemSettingsLoginItems()
            } else if let notice = StatusNotice.after(
                .toggleLaunchAtLogin, ok: result.ok, reason: result.reason, warning: result.warning
            ) {
                post(notice)
            }
            statusItem?.reload()
        }
    }

    // MARK: Restart and quit

    /// Keeps the session: this copy just exits, with no end sequence, and the new one picks the session
    /// up from the ledger as any launch does. If the new copy can't be opened, this one stays.
    ///
    /// Never in a test setup, where the menu has it off: the new copy would get none of this
    /// environment, so it would be the real app, on the real displays and the real ledger.
    private func restart() {
        guard !isTerminating, restartFallback == nil else { return }
        guard !isTestSetup else {
            log.notice("A test setup doesn't restart, because the new copy would be the real app")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--wait-for-pid=\(getpid())"]

        restartFallback = Task {
            try? await Task.sleep(for: .seconds(Self.restartExitSeconds))
            guard !Task.isCancelled else { return }
            log.notice("No answer yet from the copy being opened, so exiting for it to go on")
            exit(0)
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            // Only the words go across, because the error itself can't.
            let failure = error?.localizedDescription
            Task { @MainActor in self.restartAnswered(failure: failure) }
        }
    }

    private func restartAnswered(failure: String?) {
        guard let failure else { exit(0) }
        restartFallback?.cancel()
        restartFallback = nil
        post(.restartFailed(failure))
    }

    /// Not during a restart, which is going to bring up a new copy whatever happens here, and which is
    /// about to exit anyway. A quit now would only end the session it means to keep. Safe from inside a
    /// task, which is where the hotkey and the `quit` command call it from.
    private func quit() {
        guard !isTerminating, restartFallback == nil else { return }
        Termination.request()
    }

    /// Nil if it's going to quit. During a restart it won't, and says so, so the caller isn't told it worked.
    private func quitAfterReplying() -> String? {
        guard restartFallback == nil else { return "restarting" }
        Task {
            try? await Task.sleep(for: .seconds(Self.quitReplySeconds))
            quit()
        }
        return nil
    }

    /// Runs the end sequence first, with a limit of its own. AppKit keeps the run loop going until the
    /// reply, and that loop runs the task here only because `Termination` calls in from a plain run loop
    /// callback. AppKit can ask more than once, as a logout does, and only the first ask does anything,
    /// because a second `shutdown` would return at once and let the app go too early.
    ///
    /// If no reply has come after `terminateLimitSeconds`, it goes anyway, so a quit can never hang. That
    /// limit is a run loop timer, which fires even if main actor jobs are stuck. The ledger then says what
    /// was left, and the next launch or the guardian finishes it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        let limit = Timer(timeInterval: Self.terminateLimitSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                log.error("No reply \(Int(Self.terminateLimitSeconds)) seconds into quitting, so the app is quitting anyway")
                self.replyToTerminate()
            }
        }
        RunLoop.main.add(limit, forMode: .common)
        terminateLimit = limit

        Task {
            await runtime.shutdown()
            replyToTerminate()
        }
        return .terminateLater
    }

    private func replyToTerminate() {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        terminateLimit?.invalidate()
        terminateLimit = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

extension AppDelegate {
    /// A status menu has no window to show a failure in, so this also logs it, in case notifications are
    /// off. Only a failure is logged as an error. The permission is only asked for when there's something
    /// to say. A test setup only logs it, because its notification would read as the real app's.
    fileprivate func post(_ notice: StatusNotice) {
        if notice.isError {
            log.error("\(notice.title, privacy: .public): \(notice.body, privacy: .public)")
        } else {
            log.info("\(notice.title, privacy: .public): \(notice.body, privacy: .public)")
        }
        guard !isTestSetup else {
            log.notice("A test setup doesn't post notifications, so that one stays in the log")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                log.info("Notifications are off, so that one stays in the log")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        }
    }
}
