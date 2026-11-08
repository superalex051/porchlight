import ADModel
import Darwin
import Foundation

public enum IPCError: Error, Equatable {
    /// Nothing is listening: the socket file is missing or stale. Nothing was sent.
    case notRunning
    /// No full answer before the deadline. The request may have run.
    case timedOut
    /// Anything else, including a server socket that can't be set up. The request may have run.
    case protocolError(String)
}

enum IPCWire {
    static let version = 1
    static let busyStarting = "starting"
}

// MARK: - Messages

/// `{"v":1,"id","operations","parameters":[[name,value|null]...],"client"}`
struct IPCRequest: Codable, Equatable, Sendable {
    /// `[name, value|null]`. A list of pairs, so order and duplicates survive.
    struct Parameter: Codable, Equatable, Sendable {
        var name: String
        var value: String?

        init(name: String, value: String?) {
            self.name = name
            self.value = value
        }

        init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            guard pair.count == 2 else {
                throw DecodingError.dataCorruptedError(in: pair, debugDescription: "Not a [name, value] pair")
            }
            name = try pair.decode(String.self)
            value = try pair.decode(String?.self)
        }

        func encode(to encoder: Encoder) throws {
            var pair = encoder.unkeyedContainer()
            try pair.encode(name)
            try pair.encode(value)
        }
    }

    var v = IPCWire.version
    var id: String
    var operations: [String]
    var parameters: [Parameter]
    var client: String

    init(id: String, command: CommandRequest, client: String) {
        self.id = id
        operations = command.operations
        parameters = command.parameters.map { Parameter(name: $0.name, value: $0.value) }
        self.client = client
    }

    var command: CommandRequest {
        CommandRequest(
            operations: operations,
            parameters: parameters.map { CommandParameter(name: $0.name, value: $0.value) }
        )
    }
}

/// `{"v":1,"id","ok","payload","reason","warning","json","busy"}`. Fields with no value are left out,
/// so a top-level `json` of `.null` comes back as nil, which `OutputFormatter` renders the same way.
struct IPCReply: Codable, Equatable, Sendable {
    var v = IPCWire.version
    /// Nil only when the request line was too broken to have an ID.
    var id: String?
    var ok: Bool
    var payload: String?
    var reason: String?
    var warning: String?
    var json: JSONValue?
    var busy: String?

    init(id: String?, result: CommandResult) {
        self.id = id
        ok = result.ok
        payload = result.payload
        reason = result.reason
        warning = result.warning
        json = result.json
    }

    static func failure(id: String?, reason: String) -> IPCReply {
        IPCReply(id: id, result: .failure(reason))
    }

    static func busy(id: String) -> IPCReply {
        var reply = IPCReply(id: id, result: CommandResult(ok: false))
        reply.busy = IPCWire.busyStarting
        return reply
    }

    var result: CommandResult {
        CommandResult(
            ok: ok,
            payload: payload,
            reason: reason ?? busy.map { "busy: \($0)" },
            warning: warning,
            json: json
        )
    }
}

/// One JSON object and a newline. `JSONEncoder` escapes newlines in strings, so the only one is the last.
func encodeLine(_ message: some Encodable) throws -> Data {
    var line = try JSONEncoder().encode(message)
    line.append(0x0A)
    return line
}

// MARK: - Sockets

/// Deadlines are on this clock, which doesn't jump when the wall clock is set.
func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
}

/// A path as `bind` and `connect` want it.
struct IPCSocketAddress {
    private var storage = sockaddr_un()

    /// A path that doesn't fit throws: truncated, it would name a different socket.
    init(path: String) throws {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: storage.sun_path) - 1
        guard !bytes.isEmpty, bytes.count <= capacity, !bytes.contains(0) else {
            throw IPCError.protocolError("not a usable socket path: \(path)")
        }
        storage.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        storage.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &storage.sun_path) { $0.copyBytes(from: bytes) }
    }

    func call(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        withUnsafePointer(to: storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

enum IPCSocket {
    /// The current `errno` as an error. Call it before anything else can change `errno`.
    static func failure(_ call: String) -> IPCError {
        .protocolError("\(call): \(String(cString: strerror(errno)))")
    }

    static func make() throws -> Int32 {
        let file = socket(AF_UNIX, SOCK_STREAM, 0)
        guard file >= 0 else { throw failure("socket") }
        do {
            try prepare(file)
        } catch {
            close(file)
            throw error
        }
        return file
    }

    /// For every socket, including accepted ones, which don't reliably inherit all of this.
    /// A child that inherited a listener would keep a dead server looking alive. A peer hanging
    /// up must not raise SIGPIPE, which would kill the process that's holding the monitors off.
    static func prepare(_ file: Int32) throws {
        var on: Int32 = 1
        let flags = fcntl(file, F_GETFL)
        guard
            flags >= 0,
            fcntl(file, F_SETFL, flags | O_NONBLOCK) == 0,
            fcntl(file, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(file, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw failure("socket options") }
    }

    /// A connected socket, or `notRunning` if nothing is listening at the address. On a Unix socket
    /// `connect` finishes at once, so this doesn't wait.
    static func connected(to address: IPCSocketAddress) throws -> Int32 {
        let file = try make()
        guard address.call({ connect(file, $0, $1) }) == 0 else {
            defer { close(file) }
            switch errno {
            case ENOENT, ECONNREFUSED, ENOTSOCK:
                throw IPCError.notRunning
            default:
                throw failure("connect")
            }
        }
        return file
    }
}

/// The line was longer than the reader's limit.
struct IPCLineTooLong: Error {}

/// Line-framed reads and writes on a non-blocking socket, waiting in `poll` up to a deadline.
/// These block the calling thread, so never call them from the cooperative pool.
struct IPCStream {
    let file: Int32
    private var buffered: [UInt8] = []
    /// The newline search resumes here, so a long line isn't rescanned for every chunk.
    private var scanned = 0

    init(file: Int32) {
        self.file = file
    }

    /// The next line without its newline, or nil at the end of the stream.
    mutating func readLine(deadline: Double = .infinity, maxBytes: Int = .max) throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = buffered[scanned...].firstIndex(of: 0x0A) {
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                scanned = 0
                return line
            }
            scanned = buffered.count
            guard buffered.count <= maxBytes else { throw IPCLineTooLong() }

            let count = read(file, &chunk, chunk.count)
            if count > 0 {
                buffered.append(contentsOf: chunk[..<count])
            } else if count == 0 {
                return nil
            } else if errno == EAGAIN {
                try wait(for: POLLIN, deadline: deadline)
            } else if errno != EINTR {
                throw IPCSocket.failure("read")
            }
        }
    }

    func write(_ bytes: Data, deadline: Double = .infinity) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(file, buffer.baseAddress.map { $0 + offset }, buffer.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count == 0 {
                // Writing nothing sets no errno, and retrying could loop forever.
                throw IPCError.protocolError("write: wrote nothing")
            } else if errno == EAGAIN {
                try wait(for: POLLOUT, deadline: deadline)
            } else if errno != EINTR {
                throw IPCSocket.failure("write")
            }
        }
    }

    private func wait(for event: Int32, deadline: Double) throws {
        var descriptor = pollfd(fd: file, events: Int16(event), revents: 0)
        while true {
            // Also false for a NaN deadline.
            let remaining = deadline - monotonicSeconds()
            guard remaining > 0 else { throw IPCError.timedOut }
            // Capped, because an infinite deadline has no millisecond count.
            let ready = poll(&descriptor, 1, Int32((min(remaining, 60) * 1000).rounded(.up)))
            // A hang-up counts as ready, and the next read or write reports it.
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw IPCSocket.failure("poll") }
        }
    }
}
