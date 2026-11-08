public struct CommandParameter: Codable, Sendable, Equatable {
    public var name: String
    public var value: String?

    public init(name: String, value: String? = nil) {
        self.name = name
        self.value = value
    }
}

public struct CommandRequest: Codable, Sendable, Equatable {
    public var operations: [String]
    public var parameters: [CommandParameter]

    public init(operations: [String], parameters: [CommandParameter] = []) {
        self.operations = operations
        self.parameters = parameters
    }
}

public struct CommandResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var payload: String?
    public var reason: String?
    public var warning: String?
    public var json: JSONValue?

    public init(
        ok: Bool,
        payload: String? = nil,
        reason: String? = nil,
        warning: String? = nil,
        json: JSONValue? = nil
    ) {
        self.ok = ok
        self.payload = payload
        self.reason = reason
        self.warning = warning
        self.json = json
    }

    public static func success(
        _ payload: String? = nil,
        json: JSONValue? = nil,
        warning: String? = nil
    ) -> CommandResult {
        CommandResult(ok: true, payload: payload, warning: warning, json: json)
    }

    /// With no reason, the CLI prints a bare `Failed.`.
    public static func failure(_ reason: String? = nil) -> CommandResult {
        CommandResult(ok: false, reason: reason)
    }
}
