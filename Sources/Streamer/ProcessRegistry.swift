import Foundation

/// Thread-safe registry for ffmpeg Process objects.
/// Accessed from both the main actor (to terminate) and background threads (termination handlers).
final class ProcessRegistry: @unchecked Sendable {
    private var lock = NSLock()
    private var table: [UUID: Process] = [:]

    func store(_ process: Process, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        table[id] = process
    }

    /// Terminate and remove the process for `id`.
    /// Sends one SIGTERM (ffmpeg finalizes the file/RTMP on the first signal), then
    /// escalates to SIGKILL after `killAfter` seconds if it hasn't exited — so a hung
    /// ffmpeg can never wedge shutdown.
    func terminate(id: UUID, killAfter: TimeInterval = 6) {
        lock.lock()
        let p = table[id]
        table[id] = nil
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()                                   // SIGTERM (sent once)
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) { [weak p] in
            if p?.isRunning == true { kill(pid, SIGKILL) }   // last-resort force kill
        }
    }

    /// Terminate only if the stored process is still the expected instance.
    /// Prevents a stale watchdog from killing a freshly-relaunched successor process.
    func terminate(id: UUID, ifMatches process: Process, killAfter: TimeInterval = 6) {
        lock.lock()
        let matches = table[id] === process
        if matches { table[id] = nil }
        lock.unlock()
        guard matches, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) { [weak process] in
            if process?.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    /// Remove only if it matches the expected process instance (called from termination handler).
    func remove(id: UUID, ifMatches process: Process) {
        lock.lock(); defer { lock.unlock() }
        if table[id] === process { table[id] = nil }
    }

    /// Force-kill every tracked process immediately (used on app quit so no ffmpeg orphans).
    func killAll() {
        lock.lock(); let procs = Array(table.values); table.removeAll(); lock.unlock()
        for p in procs where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}
