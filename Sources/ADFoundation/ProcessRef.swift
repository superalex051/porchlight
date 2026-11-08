import Darwin
import Foundation
import Synchronization

/// A process identified by PID and start time, so a recycled PID doesn't look like the old process.
public struct ProcessRef: Codable, Sendable, Hashable {
    public var pid: Int32
    public var startTime: Double

    public init(pid: Int32, startTime: Double) {
        self.pid = pid
        self.startTime = startTime
    }
}

public protocol ProcessInspecting: Sendable {
    /// The running process with this PID, or nil if there is none.
    func reference(forPID pid: Int32) -> ProcessRef?
    /// True only if this PID is running and started at this exact time.
    func isAlive(_ ref: ProcessRef) -> Bool
    /// Sends `SIGKILL`, but only if the reference is still alive.
    func kill(_ ref: ProcessRef)
}

public struct LiveProcessInspector: ProcessInspecting {
    public init() {}

    public func reference(forPID pid: Int32) -> ProcessRef? {
        // PID 0 is the kernel, and kill(2) reads zero and negative PIDs as process groups, with -1
        // meaning every process. `kill` goes through here, so a corrupt ledger can't reach those.
        guard pid > 0 else { return nil }

        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }

        // A zombie has exited, and only its parent can remove it. It stays in this table until then.
        guard Int32(info.kp_proc.p_stat) != SZOMB else { return nil }

        let start = info.kp_proc.p_un.__p_starttime
        return ProcessRef(pid: pid, startTime: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    public func isAlive(_ ref: ProcessRef) -> Bool {
        reference(forPID: ref.pid) == ref
    }

    public func kill(_ ref: ProcessRef) {
        guard isAlive(ref) else { return }
        Darwin.kill(ref.pid, SIGKILL)
    }
}

/// A test double. Set `alive` to choose what is running, and read `killed` for every `kill` call,
/// including calls on references that weren't alive. A `kill` removes the reference from `alive`.
public final class FakeProcessInspector: ProcessInspecting {
    private struct State {
        var alive: Set<ProcessRef>
        var killed: [ProcessRef] = []
    }

    private let state: Mutex<State>

    public init(alive: Set<ProcessRef> = []) {
        state = Mutex(State(alive: alive))
    }

    public var alive: Set<ProcessRef> {
        get { state.withLock { $0.alive } }
        set { state.withLock { $0.alive = newValue } }
    }

    public var killed: [ProcessRef] {
        state.withLock { $0.killed }
    }

    public func reference(forPID pid: Int32) -> ProcessRef? {
        state.withLock { $0.alive.first { $0.pid == pid } }
    }

    public func isAlive(_ ref: ProcessRef) -> Bool {
        state.withLock { $0.alive.contains(ref) }
    }

    public func kill(_ ref: ProcessRef) {
        state.withLock {
            $0.killed.append(ref)
            $0.alive.remove(ref)
        }
    }
}
