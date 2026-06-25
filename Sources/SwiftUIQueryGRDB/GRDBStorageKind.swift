import Foundation
import SwiftUIQuery

extension CacheStorageKind {
    /// SQLite persistence via GRDB. GRDB types stay hidden behind this factory.
    ///
    /// ```swift
    /// import SwiftUIQueryGRDB
    /// try QueryClient(storage: .grdb(.persistent))
    /// ```
    public static func grdb(_ location: GRDBLocation) -> CacheStorageKind {
        .custom { try GRDBCacheStorage(configuration: location.configuration) }
    }

    /// Where a GRDB-backed cache database lives.
    public enum GRDBLocation: Sendable {
        /// System Caches directory (may be evicted by the OS).
        case ephemeral
        /// Application Support — survives launches, not OS-evicted.
        case persistent
        /// Documents directory (user-visible, backed up).
        case documents
        /// A unique temporary file (test/ephemeral).
        case inMemory
        /// An explicit database path.
        case custom(path: String, useWAL: Bool = true, maxSize: Int64? = nil)

        var configuration: CacheDatabaseConfiguration {
            switch self {
            case .ephemeral: return .ephemeral
            case .persistent: return .persistent
            case .documents: return .documents
            case .inMemory: return .inMemory
            case .custom(let path, let useWAL, let maxSize):
                return CacheDatabaseConfiguration(path: path, useWAL: useWAL, maxSize: maxSize)
            }
        }
    }
}
