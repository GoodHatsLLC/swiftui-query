import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Emits app lifecycle events used for automatic refetch behavior.
///
/// This is intentionally SwiftUI-free so it can be used by `QueryObserver` and
/// tests without requiring SwiftUI.
actor AppLifecycleMonitor: Sendable {
    enum Event: Sendable, Equatable {
        case didBecomeActive
    }

    static let shared = AppLifecycleMonitor()

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private let observerBag = ObserverBag()
    private let shouldObserveSystemNotifications: Bool
    /// Guards against installing duplicate NotificationCenter observers (#6).
    private var didInstallObservers = false

    init(observeSystemNotifications: Bool = true) {
        self.shouldObserveSystemNotifications = observeSystemNotifications

        if observeSystemNotifications {
            Task { await installSystemObserversIfNeeded() }
        }
    }

    func events() -> AsyncStream<Event> {
        // `.bufferingNewest(1)` (#4): focus events are idempotent ("app active,
        // consider refetch"), so a suspended consumer should resume to a single
        // pending signal rather than replaying a backlog of `didBecomeActive`.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuations[id] = continuation

            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    internal func emitForTesting(_ event: Event) {
        emit(event)
    }

    internal func ensureSystemObserversInstalledForTesting() async {
        await installSystemObserversIfNeeded()
    }

    private func emit(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func installSystemObserversIfNeeded() async {
        guard shouldObserveSystemNotifications else { return }
        // Idempotency (#6): init and `ensureSystemObserversInstalledForTesting`
        // can both call this; without the guard each call registers another
        // NotificationCenter observer, double-emitting `didBecomeActive`.
        guard !didInstallObservers else { return }
        didInstallObservers = true

        let center = NotificationCenter.default

        #if canImport(UIKit)
        observerBag.add(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.emit(.didBecomeActive) }
            }
        )
        #endif

        #if canImport(AppKit)
        observerBag.add(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.emit(.didBecomeActive) }
            }
        )
        #endif
    }
}

private final class ObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
