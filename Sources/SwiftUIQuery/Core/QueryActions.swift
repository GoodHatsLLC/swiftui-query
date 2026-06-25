import Foundation

/// Actions available via the projected value of a query property wrapper.
///
/// This type is intentionally SwiftUI-free so it can be reused by
/// testing harnesses on platforms where SwiftUI isn't available.
@MainActor
public struct QueryActions<K: QueryKey> {
    fileprivate weak var observer: QueryObserver<K>?
    fileprivate let client: QueryClient
    fileprivate let key: K

    public init(observer: QueryObserver<K>?, client: QueryClient, key: K) {
        self.observer = observer
        self.client = client
        self.key = key
    }

    /// Trigger a manual refetch
    public func refetch() async {
        await observer?.refetch()
    }

    /// Invalidate and refetch the query
    ///
    /// Routes through QueryClient to ensure proper cycle detection.
    public func invalidate() async {
        await client.invalidate(key: key, source: "QueryActions<\(K.self)>")
    }

    /// Set data directly in the cache
    public func setData(_ data: K.Response) async {
        await client.setQueryData(key, data: data)
    }

    /// Get the current cached data
    public func getData() async -> K.Response? {
        await client.getQueryData(key)
    }
}
