#if canImport(SwiftUI)
import SwiftUI

/// Property wrapper for declarative data fetching in SwiftUI.
///
/// `@Query` provides React Query-style data fetching with automatic caching,
/// background refetching, and SwiftUI integration.
///
/// ```swift
/// struct UserView: View {
///     let userId: Int
///
///     @Query(UserQuery(userId: userId)) { _ in
///         try await api.fetchUser(id: userId)
///     } var user
///
///     var body: some View {
///         switch user.result {
///         case .loading:
///             ProgressView()
///         case .success(let user):
///             Text(user.name)
///         case .error(let error):
///             Text(error.localizedDescription)
///         case .idle:
///             EmptyView()
///         }
///     }
/// }
/// ```
@MainActor
@propertyWrapper
public struct Query<K: QueryKey>: @preconcurrency DynamicProperty, Sendable {
    @Environment(\.queryClient) private var client
    @State private var observer: Synchronized<QueryObserver<K>?> = .init(nil)
    @State private var observerKey: Synchronized<K?> = .init(nil)
    @State private var observerClientIdentity: Synchronized<Int?> = .init(nil)
    @State private var observerOptions: Synchronized<QueryOptions?> = .init(nil)
    @State private var environmentSnapshot: Synchronized<Transferring<EnvironmentValues>?> = .init(nil)
    @Environment(\.self) private var env
    private let key: K
    private let options: QueryOptions
    private let fetcher: @MainActor (_ env: EnvironmentValues) async throws -> K.Response

    /// Initialize with a query key and fetcher
    public nonisolated init(
        _ key: K,
        options: QueryOptions = .default,
        fetch: @escaping @MainActor (_ env: EnvironmentValues) async throws -> K.Response
    ) {
        self.key = key
        self.options = options
        self.fetcher = fetch
    }
    
    /// Initialize with a query key, stale time, and fetcher (convenience)
    public nonisolated init(
        _ key: K,
        staleTime: Duration,
        fetch: @escaping @MainActor (_ env: EnvironmentValues) async throws -> K.Response
    ) {
        self.key = key
        self.options = QueryOptions(staleTime: staleTime)
        self.fetcher = fetch
    }
    
    public var wrappedValue: QueryState<K.Response> {
        ensureObserver().state
    }

    @MainActor
    public var projectedValue: QueryActions<K> {
        QueryActions(observer: ensureObserver(), client: client, key: key)
    }
    
    public func update() {
        _ = ensureObserver()
    }

    private func ensureObserver() -> QueryObserver<K> {
        let currentEnvironment = Transferring(env)
        let currentClientIdentity = clientIdentity(client)
        environmentSnapshot.withLock { $0 = currentEnvironment }

        // Recreate the observer when the key, the client, or the options change.
        // (The fetcher closure can't be compared for identity, so a fetcher-only
        // change with an unchanged key/options/client is not detected — #13.)
        if observerKey.withLock({ $0 }) != key ||
            observerClientIdentity.withLock({ $0 }) != currentClientIdentity ||
            observerOptions.withLock({ $0 }) != options {
            observer.withLock({ $0 })?.stopObserving()
            observer.withLock { $0 = nil }
            observerKey.withLock { $0 = key }
            observerClientIdentity.withLock { $0 = currentClientIdentity }
            observerOptions.withLock { $0 = options }
        }

        if let existing = observer.withLock({ $0 }) {
            return existing
        }

        let environmentSnapshot = self.environmentSnapshot
        let fetch = self.fetcher
        let newObserver = client.query(
            key,
            options: options,
            fetcher: {
                let environment = environmentSnapshot.withLock { $0 }?.value ?? currentEnvironment.value
                return try await fetch(environment)
            }
        )
        self.observer.withLock { $0 = newObserver }
        self.observerKey.withLock { $0 = key }
        self.observerClientIdentity.withLock { $0 = currentClientIdentity }
        self.observerOptions.withLock { $0 = options }
        newObserver.startObserving()
        return newObserver
    }

    private func clientIdentity(_ client: QueryClient) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(client).toOpaque())
    }
}
#endif
