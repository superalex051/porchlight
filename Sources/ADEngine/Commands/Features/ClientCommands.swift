import ADModel
import Foundation

/// A `clients` command's parameters, checked before anything is read or written. Names ignore case,
/// as everywhere in the CLI, and none may repeat.
private struct ClientParameters {
    private var byName: [String: CommandParameter] = [:]

    init(_ parameters: [CommandParameter], allowed: Set<String>) throws {
        for parameter in parameters {
            let name = parameter.name.lowercased()
            guard allowed.contains(name) else { throw CommandRefusal(reason: "unknown parameter: \(parameter.name)") }
            guard byName[name] == nil else { throw CommandRefusal(reason: "repeated parameter: \(parameter.name)") }
            byName[name] = parameter
        }
    }

    var count: Int { byName.count }

    subscript(_ name: String) -> CommandParameter? { byName[name] }
}

/// `clients list|set|remove|auto|match|notch|room`: the devices that `session start -preset=auto` knows,
/// and its settings, in `clients.json`. They never touch a display, so they take no turn with the
/// session controller. The dispatcher runs on the main actor and these don't wait, so two of them can't
/// interleave their read and write.
extension CommandDispatcher {
    private static let clientOperations = "list, set, remove, auto, match, notch or room"
    private static let longestClientName = 64

    func runClients(_ words: [String], _ parameters: [CommandParameter]) throws -> CommandResult {
        guard let word = words.first else {
            throw CommandRefusal(reason: "clients needs one of \(Self.clientOperations)")
        }
        guard words.count == 1 else { throw Self.unknownClientsOperation(words.joined(separator: " ")) }
        switch word {
        case "list":
            _ = try ClientParameters(parameters, allowed: [])
            return .success(clientLines(try readClients()))
        case "set": return try clientsSet(ClientParameters(parameters, allowed: ["name", "address", "preset"]))
        case "remove": return try clientsRemove(ClientParameters(parameters, allowed: ["name"]))
        case "auto": return try clientsSwitch("auto", \.autoSize, ClientParameters(parameters, allowed: ["on", "off"]))
        case "match": return try clientsSwitch("match", \.matchClient, ClientParameters(parameters, allowed: ["on", "off"]))
        case "notch": return try clientsSwitch("notch", \.clearOfNotch, ClientParameters(parameters, allowed: ["on", "off"]))
        case "room": return try clientsRoom(ClientParameters(parameters, allowed: ["factor"]))
        default: throw Self.unknownClientsOperation(word)
        }
    }

    private static func unknownClientsOperation(_ words: String) -> CommandRefusal {
        CommandRefusal(reason: "unknown clients operation: \(words); use \(clientOperations)")
    }

    /// The settings, a line each, then a line per client, with what a hand edit may have broken.
    private func clientLines(_ mapping: ClientMapping) -> String {
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        var lines = [
            "autoSize=\(onOff(mapping.autoSize))",
            "matchClient=\(onOff(mapping.matchClient))",
            "clearOfNotch=\(onOff(mapping.clearOfNotch))",
            "phoneRoom=\(mapping.phoneRoom)",
        ]
        for client in mapping.clients {
            var line = "\(client.name): address=\(client.match.address) preset=\(client.preset)"
            if presets.preset(named: client.preset) == nil { line += " (no such preset)" }
            if ClientAddress.normalized(client.match.address) == nil { line += " (not an IP address)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Adds the client, or changes the one with that name where it is.
    private func clientsSet(_ parameters: ClientParameters) throws -> CommandResult {
        guard let name = parameters["name"], let address = parameters["address"], let preset = parameters["preset"] else {
            throw CommandRefusal(reason: "clients set needs -name, -address and -preset")
        }
        let clientName = (name.value ?? "").trimmingCharacters(in: .whitespaces)
        guard (1...Self.longestClientName).contains(clientName.count),
            !clientName.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw CommandRefusal(reason: "a client needs a name of 1 to \(Self.longestClientName) characters")
        }
        guard let plainAddress = ClientAddress.normalized(address.value ?? "") else {
            throw CommandRefusal(reason: "not an IP address: \(address.value ?? "")")
        }
        guard let saved = presets.preset(named: preset.value ?? "") else {
            throw CommandRefusal(reason: "unknown preset: \(preset.value ?? "")")
        }

        var mapping = try readClients()
        let index = mapping.clients.firstIndex { $0.name.lowercased() == clientName.lowercased() }
        if let other = mapping.clients.enumerated().first(where: { offset, client in
            offset != index && ClientAddress.normalized(client.match.address) == plainAddress
        }) {
            throw CommandRefusal(reason: "\(plainAddress) is already client \(other.element.name)")
        }
        let rule = ClientRule(name: index.map { mapping.clients[$0].name } ?? clientName, address: plainAddress, preset: saved.name)
        if let index { mapping.clients[index] = rule } else { mapping.clients.append(rule) }
        try writeClients(mapping)
        return .success()
    }

    private func clientsRemove(_ parameters: ClientParameters) throws -> CommandResult {
        guard let name = parameters["name"]?.value else { throw CommandRefusal(reason: "clients remove needs -name") }
        var mapping = try readClients()
        guard let index = mapping.clients.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw CommandRefusal(reason: "no client named \(name)")
        }
        mapping.clients.remove(at: index)
        try writeClients(mapping)
        return .success()
    }

    /// `clients auto`, `match` and `notch`: each turns one setting on or off.
    private func clientsSwitch(
        _ operation: String,
        _ setting: WritableKeyPath<ClientMapping, Bool>,
        _ parameters: ClientParameters
    ) throws -> CommandResult {
        let choice: (parameter: CommandParameter, on: Bool)? =
            if let on = parameters["on"] { (on, true) } else if let off = parameters["off"] { (off, false) } else { nil }
        guard parameters.count == 1, let choice else {
            throw CommandRefusal(reason: "clients \(operation) needs -on or -off")
        }
        guard choice.parameter.value == nil else {
            throw CommandRefusal(reason: "-\(choice.parameter.name.lowercased()) takes no value")
        }
        var mapping = try readClients()
        mapping[keyPath: setting] = choice.on
        try writeClients(mapping)
        return .success()
    }

    /// `clients room -factor=4/3`: how much more room a phone's matched screen has. 1/1 is pixel for pixel.
    private func clientsRoom(_ parameters: ClientParameters) throws -> CommandResult {
        guard let parameter = parameters["factor"] else { throw CommandRefusal(reason: "clients room needs -factor") }
        guard let factor = parameter.value.flatMap(RoomFactor.init(parsing:)) else {
            throw CommandRefusal(reason: "-factor must be a fraction from 1/1 to 2/1, such as 4/3")
        }
        var mapping = try readClients()
        mapping.phoneRoom = factor
        try writeClients(mapping)
        return .success()
    }

    private func readClients() throws -> ClientMapping {
        do {
            return try sizer.clients.read()
        } catch {
            throw CommandRefusal(reason: "\(error.reason); fix it or delete it")
        }
    }

    private func writeClients(_ mapping: ClientMapping) throws {
        do {
            try sizer.clients.write(mapping)
        } catch {
            throw CommandRefusal(reason: "can't write \(sizer.clients.url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
