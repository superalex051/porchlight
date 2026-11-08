import ADModel
import Foundation

/// Why a reply to `session watch` couldn't be used. `reason` reads well after `Failed. `.
public struct SessionWatchError: Error, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// Why `SessionWatch.follow` stopped.
public enum SessionWatchEnding: Equatable, Sendable {
    /// Nothing listens on the socket any more: the app quit, or died and wasn't relaunched in time.
    case appGone
    /// The app answered with a failure, or with something that isn't a watch answer.
    case failed(String)
    case cancelled
}

/// The client half of `session watch`, shared by the CLI and `PorchLightClient`: a long poll on the
/// control socket, so following changes needs no second socket. The wire format is section 9 of
/// `docs/session-api.md`. Send `request`, give the answer to `take`, show what it
/// returns, and repeat; or let `follow` do all of that.
public struct SessionWatch: Sendable {
    /// How long the app holds a request open when nothing changes.
    public static let waitSeconds = 15
    /// One request's socket timeout: the wait, and room for a slow answer.
    public static let requestTimeout = Double(waitSeconds) + 10
    /// Between attempts while the app is busy or a connection dropped, so a quitting app isn't hammered.
    static let retryPause = Duration.milliseconds(200)

    private static let unreadable = SessionWatchError(reason: "the app's answer to session watch could not be read")

    private var instance: String?
    private var change: Int?
    private var shown: JSONValue?

    public init() {}

    /// The first asks for the status now. Each one after that waits for a change after the last one seen.
    public var request: CommandRequest {
        guard let instance, let change else { return CommandRequest(operations: ["session", "watch"]) }
        return CommandRequest(
            operations: ["session", "watch"],
            parameters: [
                CommandParameter(name: "instance", value: instance),
                CommandParameter(name: "after", value: String(change)),
                CommandParameter(name: "wait", value: String(Self.waitSeconds)),
            ]
        )
    }

    /// Reads the answer to `request`. Returns the status to show, the way `session status` answers it:
    /// the line in `payload` and the status object in `json`. Nil if there's nothing new to show, which
    /// includes a change that left the status exactly as last shown.
    public mutating func take(_ reply: CommandResult) throws(SessionWatchError) -> CommandResult? {
        guard reply.ok else { throw SessionWatchError(reason: reply.reason ?? "session watch failed") }
        guard case .object(let fields)? = reply.json,
            case .string(let instance)? = fields["instance"],
            case .number(let number)? = fields["change"],
            let change = Int(exactly: number),
            let status = fields["status"]
        else { throw Self.unreadable }

        // Another run of the app numbers its changes from 0 again, so its first answer is news.
        let isNew = instance != self.instance || change != self.change
        self.instance = instance
        self.change = change
        guard isNew, status != shown else { return nil }
        shown = status
        return .success(reply.payload, json: status)
    }

    /// Asks again and again, giving each status to show to `onStatus`, until the app goes away, it
    /// answers with a failure, `onStatus` throws, or the task is cancelled. A busy app (starting or
    /// quitting), a timeout and a dropped connection are all asked again, which is safe because
    /// watching changes nothing. A cancel takes effect when the request in flight comes back.
    public mutating func follow(
        send: (CommandRequest, Double) async throws -> CommandResult,
        onStatus: (CommandResult) async throws -> Void
    ) async -> SessionWatchEnding {
        while !Task.isCancelled {
            let reply: CommandResult
            do {
                reply = try await send(request, Self.requestTimeout)
            } catch IPCError.notRunning {
                return .appGone
            } catch {
                guard await Self.pause() else { return .cancelled }
                continue
            }
            if !reply.ok, reply.reason == IPCClient.busyReason {
                guard await Self.pause() else { return .cancelled }
                continue
            }
            do {
                if let status = try take(reply) { try await onStatus(status) }
            } catch let error as SessionWatchError {
                return .failed(error.reason)
            } catch {
                return Task.isCancelled ? .cancelled : .failed(String(describing: error))
            }
        }
        return .cancelled
    }

    /// False if the task was cancelled.
    private static func pause() async -> Bool {
        (try? await Task.sleep(for: retryPause)) != nil
    }
}
