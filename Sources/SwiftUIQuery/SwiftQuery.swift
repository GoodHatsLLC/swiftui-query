// SwiftUIQuery - React Query-inspired data fetching for Swift
//
// A declarative data fetching library with:
// - Tag-based hierarchical cache invalidation
// - GRDB-backed persistent storage
// - Swift Observation framework integration
// - SwiftUI-native APIs

// MARK: - Module Imports

@_exported import Foundation

// All public types are declared in their respective files:
// - Core/QueryKey.swift: QueryKey, AnyQueryKey, QueryOptions
// - Core/QueryTag.swift: QueryTag
// - Core/QueryState.swift: QueryStatus, FetchStatus, QueryResult, QueryState
// - Core/QueryClient.swift: QueryClient
// - Core/MutationState.swift: MutationStatus, MutationState, MutationBuilder
// - Cache/QueryCache.swift: CacheResult, QueryCache, CacheStats
// - Cache/Migrations.swift: CacheDatabaseConfiguration
// - Observation/QueryObserver.swift: QueryObserver
