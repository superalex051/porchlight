import ADFoundation
import ADModel
import Foundation

/// Chooses the size for `session start -preset=auto` when Parsec has just connected a device. The first
/// rule that gives a size wins:
///
/// 1. With `autoSize` on, the preset of the client whose address is the connect's, in `clients.json`.
/// 2. With `matchClient` on, a screen matched to the size the device's Parsec client reported, which
///    Parsec saves in its config file (`ClientScreen` has the arithmetic).
/// 3. The default, `MacBook 14`.
///
/// Each choice is logged with the rule that made it.
nonisolated public final class DeviceSizer: Sendable {
    /// The client whose device Parsec's log names. A session for any other client gets the default.
    static let parsecClient = "parsec"
    /// The newest connect counts only if it's this recent. The watcher starts the session in the same
    /// second as the connect line, so an older one is from an earlier session.
    static let freshSeconds = 60.0
    /// The log's times are whole seconds, so a connect can read as a little after now.
    static let aheadSeconds = 5.0
    static let defaultName = "MacBook 14"
    /// What the default is if `presets.json` no longer has a preset by its name.
    static let builtInDefault = Preset(name: defaultName, lookslike: "1728x1080", hidpi: true, hz: 60)
    /// A client's own size gets the rate a start with no `-hz` gets.
    static let clientHz = 60
    /// Parsec's config counts as saved at the connect if it was written no earlier than this before the
    /// connect line. The line's time is cut to the second, and the file can come just before it.
    static let configSlackSeconds = 2.0
    /// How long a start waits for Parsec to save the client's size at this connect, and how often it
    /// looks. Parsec saved it 0 to 1 s after the connect line in the connects seen so far.
    static let configWaitSeconds = 3.0
    static let configPollSeconds = 0.25

    public let clients: ClientStore
    private let presets: PresetStore
    private let parsecLog: URL
    private let parsecConfig: URL
    private let clock: any ADClock
    private let timeZone: TimeZone
    private let log: @Sendable (String) -> Void

    /// `timeZone` is the one Parsec writes its log in: this Mac's.
    public init(
        clients: ClientStore,
        presets: PresetStore,
        parsecLog: URL,
        parsecConfig: URL,
        clock: any ADClock,
        timeZone: TimeZone = .current,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.clients = clients
        self.presets = presets
        self.parsecLog = parsecLog
        self.parsecConfig = parsecConfig
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
    }

    /// The preset for a session of `client`, with a line in the log saying why. With `sessionRunning`,
    /// `client` already has a session, and a start only adds owners and keeps its size, so the line says
    /// that rather than name a size that won't be used. The preset is still chosen, for a session that
    /// ends before the start gets its turn, but without waiting for Parsec's config.
    func choose(client: String, sessionRunning: Bool = false) async -> Preset {
        let choice = await decide(client: client, waiting: !sessionRunning)
        if sessionRunning {
            log("Auto size: a session for \(client) is already running, so it keeps its size")
            return choice.preset ?? defaultPreset()
        }
        guard let chosen = choice.preset else {
            let preset = defaultPreset()
            log("Auto size: \(choice.why), so the size is \(preset.name), the default")
            return preset
        }
        log("Auto size: \(choice.why), so the size is \(choice.size ?? chosen.name)")
        return chosen
    }

    /// `MacBook 14` as `presets.json` has it, or as it's built in if it's been deleted or renamed.
    func defaultPreset() -> Preset {
        presets.preset(named: Self.defaultName) ?? Self.builtInDefault
    }

    /// A size, or nil for the default, and the reason, written to follow `Auto size: `.
    private struct Choice {
        var preset: Preset?
        var why: String
        /// How the log names the size, if not by the preset's name.
        var size: String?
    }

    private func decide(client: String, waiting: Bool) async -> Choice {
        let mapping = clients.mapping()
        guard mapping.autoSize || mapping.matchClient else { return Choice(why: "off") }
        guard client == Self.parsecClient else {
            return Choice(why: "only Parsec sessions are sized per device, and this one is for \(client)")
        }

        let text: String
        do {
            text = try ParsecLog.tail(of: parsecLog)
        } catch {
            return Choice(why: "Parsec's log can't be read")
        }
        let now = clock.now()
        guard let connect = ParsecLog.latestConnect(in: text, timeZone: timeZone),
            connect.at.timeIntervalSince(now) <= Self.aheadSeconds,
            now.timeIntervalSince(connect.at) <= Self.freshSeconds
        else {
            return Choice(why: "no Parsec connect in the last \(Int(Self.freshSeconds)) s")
        }

        let byAddress = byAddress(connect, mapping)
        guard byAddress.preset == nil, mapping.matchClient else { return byAddress }
        return await byClientSize(connect, mapping, waiting: waiting, notByAddress: byAddress.why)
    }

    /// Rule 1: the preset of the client with the connect's address, or why there's none.
    private func byAddress(_ connect: ParsecConnect, _ mapping: ClientMapping) -> Choice {
        let when = timeOfDay(connect.at)
        guard mapping.autoSize else {
            let from = connect.address.map { "came from \($0)" } ?? "has no address"
            return Choice(why: "the Parsec connect at \(when) \(from), and presets by address are off")
        }
        guard let address = connect.address else {
            return Choice(why: "the Parsec connect at \(when) has no address")
        }
        guard let rule = mapping.clients.first(where: { ClientAddress.normalized($0.match.address) == address }) else {
            return Choice(why: "\(address), from the Parsec connect at \(when), isn't a client")
        }
        guard let preset = presets.preset(named: rule.preset) else {
            return Choice(why: "client \(rule.name) asks for preset \(rule.preset), which isn't saved")
        }
        return Choice(preset: preset, why: "the Parsec connect at \(when) came from \(address), which is client \(rule.name)")
    }

    /// Rule 2: a screen matched to the size in Parsec's config, or why there's none. The size counts
    /// whether or not Parsec saved it at this connect: it doesn't always save a size that hasn't
    /// changed, so an older one is most likely this device's too. The log says which it was.
    private func byClientSize(
        _ connect: ParsecConnect,
        _ mapping: ClientMapping,
        waiting: Bool,
        notByAddress: String
    ) async -> Choice {
        let reading: ParsecConfigReading
        do {
            reading = try await savedSize(since: connect.at, waiting: waiting)
        } catch {
            return Choice(why: "\(notByAddress); Parsec's config can't be read")
        }
        guard let reported = reading.size else {
            return Choice(why: "\(notByAddress); Parsec's config has no client size")
        }
        let source = isSaved(reading, at: connect.at)
            ? "the client reported \(reported)"
            : "Parsec kept \(reported) from an earlier connect (saved at \(dateAndTime(reading.saved, beside: connect.at)))"
        do {
            let screen = try ClientScreen(reported: reported, clearOfNotch: mapping.clearOfNotch, phoneRoom: mapping.phoneRoom)
            let size = screen.looksLike.description
            return Choice(
                preset: Preset(name: size, lookslike: size, hidpi: true, hz: Self.clientHz),
                why: "\(notByAddress); \(source)",
                size: screen.note.map { "\(size) (\($0))" } ?? size
            )
        } catch {
            return Choice(why: "\(notByAddress); \(source), which is \(error.reason)")
        }
    }

    /// Parsec's config once it holds a size saved at this connect, or, after `configWaitSeconds`
    /// without one, as it is then. Without `waiting`, as it is now. Throws if it can't be read by then.
    private func savedSize(since connect: Date, waiting: Bool) async throws -> ParsecConfigReading {
        let deadline = clock.now().addingTimeInterval(Self.configWaitSeconds)
        while true {
            let reading = Result { try ParsecConfig.read(parsecConfig) }
            if case .success(let found) = reading, found.size != nil, isSaved(found, at: connect) { return found }
            guard waiting, clock.now() < deadline else { return try reading.get() }
            do {
                try await clock.sleep(seconds: Self.configPollSeconds)
            } catch {
                return try reading.get()
            }
        }
    }

    /// True if the file was written at the connect or after it.
    private func isSaved(_ reading: ParsecConfigReading, at connect: Date) -> Bool {
        reading.saved >= connect.addingTimeInterval(-Self.configSlackSeconds)
    }

    /// `HH:mm:ss`, as the log line has it, so the line can be found there.
    private func timeOfDay(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// The time of day, with the date in front if it isn't the connect's day.
    private func dateAndTime(_ date: Date, beside connect: Date) -> String {
        guard !calendar.isDate(date, inSameDayAs: connect) else { return timeOfDay(date) }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) + timeOfDay(date)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
