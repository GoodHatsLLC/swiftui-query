import Dispatch
import Foundation

#if canImport(Network)
import Network
#endif

/// Emits network connectivity changes used for automatic refetch behavior.
actor ConnectivityMonitor: Sendable {
    enum Status: Sendable, Equatable {
        case satisfied
        case unsatisfied
    }

    static let shared = ConnectivityMonitor()

    private var status: Status
    private var continuations: [UUID: AsyncStream<Status>.Continuation] = [:]

    /// Single ordered pipe from the off-actor path callback into the actor.
    /// Fixes event reordering (#3): the previous code spawned an independent
    /// `Task` per callback, so status updates could be applied out of order and
    /// corrupt the unsatisfied→satisfied edge detection in `QueryObserver`.
    private let rawContinuation: AsyncStream<Status>.Continuation

    #if canImport(Network)
    nonisolated private let monitor: NWPathMonitor?
    #endif

    init(startMonitoring: Bool = true, initialStatus: Status = .satisfied) {
        self.status = initialStatus

        let (rawStream, rawContinuation) = AsyncStream<Status>.makeStream()
        self.rawContinuation = rawContinuation

        #if canImport(Network)
        if startMonitoring {
            let monitor = NWPathMonitor()
            self.monitor = monitor

            // NWPathMonitor delivers on a single serial queue; yielding (which is
            // thread-safe and order-preserving) instead of spawning a Task keeps
            // status updates strictly ordered.
            monitor.pathUpdateHandler = { path in
                let mapped: Status = (path.status == .satisfied) ? .satisfied : .unsatisfied
                rawContinuation.yield(mapped)
            }

            monitor.start(queue: DispatchQueue(label: "SwiftUIQuery.ConnectivityMonitor"))
        } else {
            self.monitor = nil
        }
        #endif

        // One long-lived consumer applies updates in arrival order. Not stored:
        // finishing `rawContinuation` (in deinit, or when this monitor is freed)
        // ends the stream and lets the task complete. `self` is captured weakly.
        Task { [weak self] in
            for await status in rawStream {
                await self?.updateStatus(status)
            }
        }
    }

    deinit {
        #if canImport(Network)
        monitor?.cancel()
        #endif
        rawContinuation.finish()
    }

    func statuses() -> AsyncStream<Status> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation

            // Yield the current status immediately so consumers can track transitions.
            continuation.yield(status)

            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func currentStatus() -> Status {
        status
    }

    internal func setStatusForTesting(_ newStatus: Status) {
        updateStatus(newStatus)
    }

    private func updateStatus(_ newStatus: Status) {
        guard newStatus != status else { return }
        status = newStatus

        for continuation in continuations.values {
            continuation.yield(newStatus)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
