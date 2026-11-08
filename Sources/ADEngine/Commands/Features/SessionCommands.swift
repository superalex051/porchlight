import ADModel

/// A session's parameters, checked before anything else looks at them. A parameter this doesn't know
/// must stop the command: `session start -json` is a typo for `--json`, and it must not turn monitors off.
private struct SessionParameters {
    private static let repeatable: Set<String> = ["ownerpid", "keepon"]

    private let parameters: [CommandParameter]

    init(_ parameters: [CommandParameter], allowed: Set<String>) throws {
        var seen = Set<String>()
        for parameter in parameters {
            guard allowed.contains(parameter.name) else {
                throw SessionError(reason: "unknown parameter: \(parameter.name)")
            }
            guard seen.insert(parameter.name).inserted || Self.repeatable.contains(parameter.name) else {
                throw SessionError(reason: "repeated parameter: \(parameter.name)")
            }
        }
        self.parameters = parameters
    }

    func first(_ name: String) -> CommandParameter? {
        parameters.first { $0.name == name }
    }

    func all(_ name: String) -> [CommandParameter] {
        parameters.filter { $0.name == name }
    }

    /// Letters, digits, dot, dash and underscore, so a name fits in the status line. Nil if none was given.
    func client() throws -> String? {
        guard let parameter = first("client") else { return nil }
        guard let name = parameter.value, !name.isEmpty, name.utf8.allSatisfy(Self.isClientByte) else {
            throw SessionError(reason: "invalid client name; use letters, digits, dot, dash and underscore")
        }
        return name
    }

    private static func isClientByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }

    /// A whole number, zero or more. Nil if it wasn't given.
    func count(_ name: String) throws -> Int? {
        guard let parameter = first(name) else { return nil }
        guard let value = parameter.value.flatMap(CommandValues.wholeNumber) else {
            throw Self.invalid(name, parameter.value)
        }
        return value
    }

    func ownerPIDs() throws -> [Int32] {
        try all("ownerpid").map { parameter in
            guard let pid = parameter.value.flatMap(CommandValues.wholeNumber).flatMap(Int32.init(exactly:)), pid > 0
            else { throw Self.invalid("ownerpid", parameter.value) }
            return pid
        }
    }

    /// Has to name a display that's on. Otherwise it's most likely a typo, and the session would turn off
    /// the monitor the tester meant to keep.
    func keepOn(in topology: Topology) throws -> [String] {
        try all("keepon").map { parameter in
            guard let value = parameter.value else { throw Self.invalid("keepon", nil) }
            guard topology.display(uuid: value)?.isOnline == true else {
                throw SessionError(reason: "-keepon display not found: \(value)")
            }
            return value
        }
    }

    static func invalid(_ name: String, _ value: String?) -> SessionError {
        SessionError(reason: "invalid \(name): \(value ?? "no value")")
    }
}

/// What a command asked a session's screen to look like. Nil means it didn't say. The limits are checked
/// by the session controller, with whatever fills those gaps.
private struct ShapeRequest {
    var looksLike: ScreenSize?
    var hiDPI: Bool?
    var hz: Int?
}

extension CommandDispatcher {
    private static let defaultLooksLike = ScreenSize(w: 1728, h: 1080)
    private static let defaultHiDPI = true
    private static let defaultHz = 60
    private static let startParameters: Set<String> = ["client", "lookslike", "hiDPI", "hz", "preset", "ownerpid", "keepon"]
    private static let endParameters: Set<String> = ["client", "force", "reason"]
    private static let resizeParameters: Set<String> = ["lookslike", "hiDPI", "hz", "preset"]
    private static let watchParameters: Set<String> = ["instance", "after", "wait"]
    private static let longestWatchWait = 60
    private static let defaultEndReason = "session end"
    /// `-preset=auto`: the size for the device that connected, by its address in `clients.json` or the
    /// screen size its client reported. A preset that is itself called `auto` can't be picked by
    /// `-preset=`, so the presets window refuses that name.
    private static let autoPreset = PresetRules.reservedName

    func runSession(_ words: [String], _ parameters: [CommandParameter]) async throws -> CommandResult {
        guard let word = words.first else {
            throw SessionError(reason: "session needs one of start, end, resize, status, watch or presets")
        }
        guard words.count == 1 else { throw Self.unknownSessionOperation(words.joined(separator: " ")) }
        switch word {
        case "start": return try await sessionStart(parameters)
        case "end": return try await sessionEnd(parameters)
        case "resize": return try await sessionResize(parameters)
        case "status":
            _ = try SessionParameters(parameters, allowed: [])
            return Self.answer(session.status())
        case "watch": return try await sessionWatch(parameters)
        case "presets":
            _ = try SessionParameters(parameters, allowed: [])
            return .success(presets.presets().map(\.line).joined(separator: "\n"))
        default:
            throw Self.unknownSessionOperation(word)
        }
    }

    private static func unknownSessionOperation(_ words: String) -> SessionError {
        SessionError(reason: "unknown session operation: \(words); use start, end, resize, status, watch or presets")
    }

    private func sessionStart(_ parameters: [CommandParameter]) async throws -> CommandResult {
        let parameters = try SessionParameters(parameters, allowed: Self.startParameters)
        let client = try parameters.client() ?? "default"
        let ownerPIDs = try parameters.ownerPIDs()
        let keepOn = try parameters.keepOn(in: backend.topology())
        // Last, so `-preset=auto` doesn't log a choice for a start with a bad parameter.
        let shape = try await requestedShape(parameters, startingFor: client)
        let request = SessionRequest(
            client: client,
            looksLike: shape.looksLike ?? Self.defaultLooksLike,
            hiDPI: shape.hiDPI ?? Self.defaultHiDPI,
            hz: shape.hz ?? Self.defaultHz,
            ownerPIDs: ownerPIDs,
            keepOn: keepOn
        )
        return Self.answer(try await session.start(request))
    }

    /// With no `-client`, the controller takes it to mean the default client. `-reason` is only logged,
    /// so nothing about it can stop an end.
    private func sessionEnd(_ parameters: [CommandParameter]) async throws -> CommandResult {
        let parameters = try SessionParameters(parameters, allowed: Self.endParameters)
        let client = try parameters.client()
        var force = false
        if let parameter = parameters.first("force") {
            guard let value = CommandValues.flag(parameter.value) else {
                throw SessionParameters.invalid("force", parameter.value)
            }
            force = value
        }
        let reason = parameters.first("reason")?.value ?? Self.defaultEndReason
        let outcome = try await session.end(client: client, force: force, reason: reason)
        return .success(json: session.status().asJSON, warning: outcome.warning)
    }

    /// The spec's defaults are for a start. A resize that names only a size changes only the size, so a
    /// 1x session stays 1x, and one that names only `-hz` keeps the size, as the status menu's refresh
    /// rate choice does. What it leaves out is filled in when it gets its turn, because a resize ahead
    /// of it in the line may be about to change those.
    private func sessionResize(_ parameters: [CommandParameter]) async throws -> CommandResult {
        let parameters = try SessionParameters(parameters, allowed: Self.resizeParameters)
        let shape = try await requestedShape(parameters)
        guard shape.looksLike != nil || shape.hz != nil else {
            throw SessionError(reason: "session resize needs -lookslike, -preset or -hz")
        }
        return Self.answer(try await session.resize(looksLike: shape.looksLike, hiDPI: shape.hiDPI, hz: shape.hz))
    }

    /// `--json` is the CLI's own business, so both forms always go back.
    private static func answer(_ status: SessionStatus) -> CommandResult {
        .success(status.statusLine, json: status.asJSON)
    }

    /// A long poll, so following changes needs no second socket. With no `-after`, or one meant for
    /// another run of the app, it answers at once with the status now. Otherwise it answers with the
    /// first change after that number, waiting up to `-wait` seconds for one, and with no change it
    /// answers with the same number. Takes no turn, because it changes nothing.
    private func sessionWatch(_ parameters: [CommandParameter]) async throws -> CommandResult {
        let parameters = try SessionParameters(parameters, allowed: Self.watchParameters)
        let after = try parameters.count("after")
        let wait = try parameters.count("wait") ?? 0
        guard wait <= Self.longestWatchWait else { throw SessionParameters.invalid("wait", String(wait)) }

        let feed = sessionChanges
        if let after, after <= feed.latest, parameters.first("instance")?.value == feed.instance,
            let change = await feed.change(after: after, waitingUpTo: Double(wait))
        {
            return Self.watchAnswer(change.status, change: change.number, instance: feed.instance)
        }
        return Self.watchAnswer(session.status(), change: feed.latest, instance: feed.instance)
    }

    private static func watchAnswer(_ status: SessionStatus, change: Int, instance: String) -> CommandResult {
        .success(
            status.statusLine,
            json: .object([
                "apiVersion": .number(Double(SessionAPI.version)),
                "instance": .string(instance),
                "change": .number(Double(change)),
                "status": status.asJSON,
            ])
        )
    }

    /// True if a start from `client` now would only add owners to its session and keep its size. A
    /// session that's still starting counts, because the start waits for it. One that's ending doesn't,
    /// because the start then begins a new session or fails.
    private static func keepsItsSize(_ status: SessionStatus, _ client: String) -> Bool {
        status.client == client && [.starting, .active, .degraded].contains(status.state)
    }

    /// `startingFor` is the client of a start, the only command `-preset=auto` is for. That choice can
    /// wait a few seconds for Parsec to save the client's size, so this is async: the main actor serves
    /// other commands meanwhile.
    private func requestedShape(
        _ parameters: SessionParameters,
        startingFor client: String? = nil
    ) async throws -> ShapeRequest {
        if let preset = parameters.first("preset") {
            guard parameters.first("lookslike") == nil, parameters.first("hiDPI") == nil, parameters.first("hz") == nil else {
                throw SessionError(reason: "-preset can't be combined with -lookslike, -hidpi or -hz")
            }
            guard let name = preset.value else { throw SessionParameters.invalid("preset", nil) }
            if name.lowercased() == Self.autoPreset {
                guard let client else { throw SessionError(reason: "-preset=auto is only for session start") }
                let chosen = await sizer.choose(client: client, sessionRunning: Self.keepsItsSize(session.status(), client))
                guard let size = ScreenSize(parsing: chosen.lookslike) else {
                    throw SessionError(reason: "unknown preset: \(chosen.name)")
                }
                return ShapeRequest(looksLike: size, hiDPI: chosen.hidpi, hz: chosen.hz)
            }
            guard let found = presets.preset(named: name), let size = ScreenSize(parsing: found.lookslike) else {
                throw SessionError(reason: "unknown preset: \(name)")
            }
            return ShapeRequest(looksLike: size, hiDPI: found.hidpi, hz: found.hz)
        }

        var shape = ShapeRequest()
        if let parameter = parameters.first("lookslike") {
            guard let size = parameter.value.flatMap(ScreenSize.init(parsing:)) else {
                throw SessionParameters.invalid("lookslike", parameter.value)
            }
            shape.looksLike = size
        }
        if let parameter = parameters.first("hiDPI") {
            guard let on = CommandValues.onOff(parameter.value) else {
                throw SessionParameters.invalid("hidpi", parameter.value)
            }
            shape.hiDPI = on
        }
        if let parameter = parameters.first("hz") {
            guard let hz = parameter.value.flatMap(CommandValues.wholeNumber) else {
                throw SessionParameters.invalid("hz", parameter.value)
            }
            shape.hz = hz
        }
        return shape
    }
}
