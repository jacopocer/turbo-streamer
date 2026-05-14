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
    func terminate(id: UUID) {
        lock.lock()
        let p = table[id]
        table[id] = nil
        lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }

    /// Remove only if it matches the expected process instance (called from termination handler).
    func remove(id: UUID, ifMatches process: Process) {
        lock.lock(); defer { lock.unlock() }
        if table[id] === process { table[id] = nil }
    }
}
