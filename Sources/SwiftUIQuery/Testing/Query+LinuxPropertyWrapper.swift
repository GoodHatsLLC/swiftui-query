#if !canImport(SwiftUI)
import Foundation
#if canImport(Observation)
import Observation
#endif

/// Minimal SwiftUI-free stand-in for the `@Query` property wrapper.
///
/// This wrapper makes it possible to exercise query lifecycle logic from
/// Linux tests while preserving the same call-site shape developers use in
/// SwiftUI views. The wrapper spins up a `QueryObserver` immediately and uses
/// the shared `QueryClient` by default, mirroring SwiftUI's environment-based
/// injection.
@propertyWrapper
@MainActor
public struct Query<K: QueryKey> {
    private let key: K
    private let options: QueryOptions
    private let client: QueryClient
    private let fetcher: @Sendable () async throws -> K.Response

    private var observer: QueryObserver<K>?

    public init(
        _ key: K,
        client: QueryClient = .shared,
        options: QueryOptions = .default,
        fetcher: @escaping @Sendable () async throws -> K.Response
    ) {
        self.key = key
        self.options = options
        self.client = client
        self.fetcher = fetcher
    }

    public var wrappedValue: QueryObserver<K> {
        mutating get {
            if let observer { return observer }

            let created = client.query(key, options: options, fetcher: fetcher)
            created.startObserving()
            observer = created
            return created
        }
    }

    public var projectedValue: QueryActions<K> {
        mutating get {
            QueryActions(observer: observer ?? wrappedValue, client: client, key: key)
        }
    }

    /// Explicitly start observing. Useful for tests that want a deterministic
    /// lifecycle comparable to SwiftUI's `update()` call.
    public mutating func start() {
        _ = wrappedValue
    }

    /// Stop observing and tear down the current observer.
    public mutating func stop() {
        observer?.stopObserving()
        observer = nil
    }
}
#endif
