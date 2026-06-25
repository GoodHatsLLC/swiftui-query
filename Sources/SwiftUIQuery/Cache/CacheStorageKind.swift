import Foundation

/// Selects the persistence backend for a ``QueryCache`` / ``QueryClient``.
///
/// The core module ships GRDB-free backends. GRDB/SQLite persistence lives in the
/// separate `SwiftUIQueryGRDB` module, which adds a `.grdb(...)` factory:
///
/// ```swift
/// import SwiftUIQuery
/// QueryClient(storage: .inMemory)                 // process-lifetime dictionary
/// QueryClient(storage: .codable(directory: url))  // one JSON file per key
///
/// import SwiftUIQueryGRDB
/// QueryClient(storage: .grdb(.persistent))        // SQLite via GRDB
/// ```
///
/// `.custom` is the extension point: any ``CacheStorage`` can be supplied via a
/// factory closure (this is how `SwiftUIQueryGRDB` plugs in without the core
/// module depending on GRDB).
public enum CacheStorageKind: Sendable {
    /// Process-lifetime in-memory cache. Prefer the `inMemory` accessors.
    case inMemoryStore(maxEntries: Int?)

    /// One Codable JSON file per key under `directory`.
    case codable(directory: URL)

    /// A caller-provided backend, built lazily by the factory.
    case custom(@Sendable () throws -> any CacheStorage)

    // MARK: - In-memory accessors (a case can't share a name with a static member)

    /// Unbounded process-lifetime in-memory cache.
    public static var inMemory: CacheStorageKind { .inMemoryStore(maxEntries: nil) }

    /// In-memory cache with an approximate capacity cap (by entry count).
    public static func inMemory(maxEntries: Int?) -> CacheStorageKind {
        .inMemoryStore(maxEntries: maxEntries)
    }
}

// MARK: - Backend construction (internal)

extension CacheStorageKind {
    func makeStorage() throws -> any CacheStorage {
        switch self {
        case .inMemoryStore(let maxEntries):
            return InMemoryCacheStorage(maxEntries: maxEntries)
        case .codable(let directory):
            return try CodableFileCacheStorage(directory: directory)
        case .custom(let factory):
            return try factory()
        }
    }
}
