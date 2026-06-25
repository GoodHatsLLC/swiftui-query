#if canImport(Observation)
import Observation
import Foundation

private final class ObservationTrackingCallbacks<T>: @unchecked Sendable {
    let read: () -> T
    let onChange: () -> Void

    init(read: @escaping () -> T, onChange: @escaping () -> Void) {
        self.read = read
        self.onChange = onChange
    }
}

extension QueryObserver {
    /// Register an Observation listener for a derived value of this observer.
    ///
    /// - Parameters:
    ///   - read: Closure that reads observable state. This will be executed
    ///     immediately to register dependencies.
    ///   - onChange: Called whenever any of the read properties change.
    /// - Returns: The value returned by `read` for convenience.
    @discardableResult
    public func track<T>(
        _ read: @escaping () -> T,
        onChange: @escaping () -> Void
    ) -> T {
        let callbacks = ObservationTrackingCallbacks(read: read, onChange: onChange)
        return withObservationTracking(callbacks.read, onChange: { [weak self, callbacks] in
            // Observation tracking is one-shot; re-arm so future changes are
            // delivered as well.
            guard let self else { return }
            MainActor.assumeIsolated {
                callbacks.onChange()
                _ = self.track(callbacks.read, onChange: callbacks.onChange)
            }
        })
    }
}
#endif
