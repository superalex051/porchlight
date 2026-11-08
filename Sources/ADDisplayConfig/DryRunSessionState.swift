import ADDisplays
import ADSafety

/// A dry-run restore's copy of the Mac is made from the real one, where a dry-run session never turned
/// anything off. Left like that, the restore finds every monitor on, turns nothing on, and reports them
/// all back, which proves nothing. So this turns off in the copy what a live ledger says its session
/// turned off, as a crash leaves it, and the restore has to bring them back.
///
/// A rescued ledger says they're back already. No ledger, or one from another boot, says nothing about
/// what's off now, and the restore doesn't go by either. Those leave the copy as the real Mac is.
public enum DryRunSessionState {
    /// Returns how many of the copy's mutations this made, so a plan can leave them out. A recorded
    /// display that isn't on in the copy, say one that's unplugged, is skipped.
    @discardableResult
    public static func actOut(_ ledger: SafetyLedger?, on backend: SimulatedDisplayBackend, currentBoot: String) -> Int {
        guard let ledger, ledger.state != .rescued,
            !GuardianPolicy.isFromAnotherBoot(ledger, currentBoot: currentBoot)
        else { return 0 }

        let before = backend.mutations.count
        let online = Set(backend.topology().online.map(\.id))
        for record in ledger.physical where online.contains(record.id) {
            // A copy refuses nothing here, and a refusal would only leave that monitor on in the copy.
            try? backend.setEnabled(record.id, false)
        }
        return backend.mutations.count - before
    }
}
