# SwiftUIQuery

A React Query-inspired data fetching library for Swift, featuring:

- 🏷️ **Tag-based hierarchical cache invalidation** — Invalidating `users` cascades to `users.123` and `users.123.posts`
- 💾 **Swappable storage** — GRDB/SQLite (survives restarts), in-memory, or raw-Codable (one file per key)
- 👁️ **Swift Observation framework** — Native reactivity (SwiftUI-friendly)
- 🎨 **SwiftUI-native APIs** — Property wrappers and environment integration
- ⚡ **Stale-while-revalidate** — Show cached data immediately, refresh in background

## Documentation

- DocC (CLI): `swift package generate-documentation --target SwiftUIQuery`
- DocC (static hosting): `swift package --allow-writing-to-directory ./docs generate-documentation --target SwiftUIQuery --output-path ./docs --transform-for-static-hosting`
- Xcode: Product → Build Documentation (when opened as a package/dependency)

## Requirements

- iOS 18.0+ / macOS 15.0+
- Swift 6.1+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/GoodHatsLLC/swift-query.git", from: "0.10.0")
]
```

The package vends two products — pick per the storage you need:

```swift
// GRDB-free: in-memory or Codable (one file per key) backends. No SQLite linked.
.product(name: "SwiftUIQuery", package: "swift-query")

// Adds the GRDB/SQLite backend (.grdb(...)). Pulls in GRDB + SQLite.
.product(name: "SwiftUIQueryGRDB", package: "swift-query")
```

`SwiftUIQueryGRDB` re-exports nothing magic — `import SwiftUIQuery` for the core
API, and additionally `import SwiftUIQueryGRDB` only where you select `.grdb(...)`.

Or in Xcode: File → Add Package Dependencies → paste the repository URL, then add
the `SwiftUIQuery` (and optionally `SwiftUIQueryGRDB`) library products.

## Example App

This package includes a small SwiftUI example target (`TestApp`) you can run on macOS:

```bash
swift run TestApp
```

## Quick Start

### 1. Define a Query

```swift
import SwiftUIQuery

extension QueryTag {
    static let users = QueryTag("users")
}

struct UserQuery: QueryKey {
    typealias Response = User
    let userId: Int

    var identity: QueryIdentity { QueryIdentity("users", userId) }
    var invalidationTags: Set<QueryTag> { [.users] }
}
```

### 2. Use in SwiftUI

```swift
struct UserView: View {
    let userId: Int
    
    @Query(UserQuery(userId: userId)) { _ in
        try await api.fetchUser(id: userId)
    } var user
    
    var body: some View {
        switch user.result {
        case .idle, .loading:
            ProgressView()
        case .success(let user):
            Text(user.name)
        case .error(let error):
            Text(error.localizedDescription)
        }
        .refreshable {
            _ = try? await $user.refetch()
        }
    }
}
```

### 3. Invalidate on Mutation

```swift
struct UpdateUserView: View {
    @Mutation(invalidates: .users) { input, _ in
        try await api.updateUser(input)
    } var updateUser
    
    var body: some View {
        Button("Update") {
            Task {
                try await updateUser.mutate(UpdateUserInput(...))
                // All user queries automatically refresh!
            }
        }
        .disabled(updateUser.isPending)
    }
}
```

## Core Concepts

### Query Identity

Query identities uniquely identify cached data. Invalidation tags define broader
relationships such as "all users" or "all posts":

```swift
struct UserQuery: QueryKey {
    typealias Response = User
    let userId: Int

    // Exact identity for this specific query instance.
    var identity: QueryIdentity { QueryIdentity("users", userId) }

    // Additional parent tags for broad invalidation.
    // The exact identity tag is included automatically.
    var invalidationTags: Set<QueryTag> { [.users] }
}
```

### Query Tags & Hierarchical Invalidation

Tags enable cascade invalidation — invalidating a parent tag invalidates all children:

```swift
// Define hierarchical tags
let usersTag = QueryTag("users")           // Parent
let user123 = QueryTag("users", "123")     // Child
let userPosts = QueryTag("users", "123", "posts")  // Grandchild

// Invalidation cascades down
try await client.invalidate(tag: usersTag)  // Invalidates ALL user-related queries
try await client.invalidate(tag: user123)   // Invalidates user 123 and their posts
```

You can define tag factories locally for your domain:

```swift
extension QueryTag {
    static let users = QueryTag("users")
    static func user(_ id: Int) -> QueryTag { QueryTag("users", id) }
    static func userPosts(_ id: Int) -> QueryTag { QueryTag("users", id, "posts") }
    static let posts = QueryTag("posts")
    static func post(_ id: Int) -> QueryTag { QueryTag("posts", id) }
}
```

### Query State

`QueryState` provides React Query-style status flags:

```swift
query.data          // The cached data (if any)
query.error         // The last error (if any)
query.status        // .idle | .pending | .success | .error

// Derived states
query.isLoading     // First load (no data yet)
query.isRefetching  // Background refresh (have stale data)
query.isFetching    // Any fetch in progress
query.isSuccess     // Have valid data
query.isError       // In error state

// Pattern matching
switch query.result {
case .idle: // Not started
case .loading: // First load
case .success(let data): // Have data
case .error(let error): // Failed
}
```

### Stale-While-Revalidate

Configure when data becomes stale:

```swift
// Data stays fresh for 5 minutes
@Query(UserQuery(userId: id), staleTime: .minutes(5)) { _ in
    try await api.fetchUser(id: id)
} var user
```

- **Fresh data**: Returned immediately, no refetch
- **Stale data**: Returned immediately; a background refresh may run for active queries
- **No data**: Show loading, fetch from network

## API Reference

### @Query Property Wrapper

```swift
@Query(
    QueryKey,
    options: QueryOptions = .default,
    fetch: (EnvironmentValues) async throws -> Response
) var query
```

Access via projected value:

```swift
try await $query.refetch()      // Manual refetch
try await $query.invalidate()   // Invalidate and refetch
try await $query.setData(data)  // Update cache directly
try await $query.getData()      // Read from cache
```

#### `@Query` With Dynamic Parameters

When you need to build the key from initializer inputs (common for detail screens),
declare the wrapper and assign it in `init`:

```swift
struct UserDetailView: View {
    let api: APIClient
    @Query<UserQuery> private var user: QueryState<User>

    init(userId: Int, api: APIClient) {
        self.api = api
        _user = Query(UserQuery(userId: userId)) { env in
            _ = env
            return try await api.fetchUser(id: userId)
        }
    }
}
```

### @Mutation Property Wrapper

```swift
@Mutation(
    invalidates: QueryTag...,
    mutationFn: (Input, EnvironmentValues) async throws -> Output
) var mutation

// Execute
try await mutation.mutate(input)

// State
mutation.isPending   // Currently executing
mutation.isSuccess   // Completed successfully
mutation.isError     // Failed
mutation.data        // Last result
mutation.error       // Last error
mutation.variables   // Input of current/last mutation
```

Actions are also available through the projected value:

```swift
try await $mutation.mutate(input)
$mutation.reset()
```

#### Mutation Callbacks

Use the callback initializer for optimistic UI, success/error side effects, and cleanup:

```swift
@Mutation(
    invalidates: [.posts],
    onMutate: { input, env in
        // Return any context needed for rollback
        _ = env
        ["optimisticId": UUID()]
    },
    onSuccess: { output, input, env in
        _ = (output, input, env)
    },
    onError: { error, input, context, env in
        _ = (error, input, context, env)
    },
    onSettled: { output, error, input, env in
        _ = (output, error, input, env)
    },
    mutationFn: { input, env in
        _ = env
        try await api.createPost(input)
    }
) var createPost
```

Note: `@Mutation` receives the latest SwiftUI `EnvironmentValues`, matching `@Query`.
Captured dependencies and view initializer parameters are still fine when they are clearer.

Note: when used in SwiftUI, `@Mutation` invalidates using the environment `queryClient` (via `QueryClientProvider`). If you use `MutationState` directly and configure invalidation tags, you must provide a `QueryClient`.

### QueryClient

Access the shared client or inject via environment:

```swift
// Shared instance
try await QueryClient.shared.invalidate(tag: .users)

// Environment
@Environment(\.queryClient) var client
try await client.prefetch(UserQuery(userId: id)) {
    try await api.fetchUser(id: id)
}
```

```swift
// Fetching
try await client.fetchWithResult(key, fetcher:)  // Fetch with cache result metadata
client.query(key, fetcher:)       // Create observable query
try await client.prefetch(key, fetcher:)         // Background prefetch

// Invalidation
try await client.invalidate(tag:) // Invalidate by tag
try await client.invalidate(key)  // Invalidate specific query

// Cache manipulation
try await client.setQueryData(key, data:)   // Write to cache
try await client.getQueryData(key)          // Read from cache
try await client.removeQueryData(key)       // Delete from cache
try await client.clear()                    // Clear all cache
```

### QueryOptions

```swift
QueryOptions(
    staleTime: .zero,           // When data becomes stale
    cacheTime: .minutes(5),     // When to garbage collect
    refetchOnFocus: false,      // Refetch when app becomes active
    refetchOnReconnect: true,   // Refetch when connectivity is restored
    retryAttempts: 3,              // Retry attempts on failure
    retryDelay: .seconds(1)     // Delay between retries
)
```

`refetchOnFocus` and `refetchOnReconnect` only apply to actively observed queries
(i.e. created via `@Query` / `queryClient.query(...)`).

Note: `staleTime: .zero` means queries become stale immediately, but `@Query` does not
automatically refetch *only* because the data is stale (to avoid continuous refetch loops).

## Common Patterns

### Dependent Queries

Use SwiftUI's view hierarchy for dependencies:

```swift
struct UserDashboard: View {
    @Query(CurrentUserQuery()) { _ in
        try await api.currentUser()
    } var user
    
    var body: some View {
        if let user = user.data {
            // Child query only created when user exists
            UserPostsView(userId: user.id)
        } else if user.isLoading {
            ProgressView()
        }
    }
}
```

### Optimistic Updates

```swift
Button("Like") {
    Task {
        // 1. Save previous state
        let previous = try await $post.getData()
        
        // 2. Optimistic update
        try await $post.setData(post.withLikeCount(post.likeCount + 1))
        
        do {
            // 3. Server mutation
            try await likePost.mutate(post.id)
        } catch {
            // 4. Rollback on error
            if let previous {
                try? await $post.setData(previous)
            }
        }
    }
}
```

### Prefetching

```swift
List(users) { user in
    NavigationLink {
        UserDetailView(userId: user.id)
    } label: {
        UserRow(user: user)
    }
    .task {
        // Prefetch on appear
        try? await client.prefetch(UserQuery(userId: user.id)) {
            try await api.fetchUser(id: user.id)
        }
    }
}
```

### Pagination

```swift
struct PostsQuery: QueryKey {
    typealias Response = PagedResult<Post>
    let page: Int

    var identity: QueryIdentity { QueryIdentity("posts", "page", page) }
    var invalidationTags: Set<QueryTag> { [.posts] }
}

struct InfinitePostsView: View {
    @State private var pages: [Int] = [0]
    @Environment(\.queryClient) var client
    
    var body: some View {
        List {
            ForEach(pages, id: \.self) { page in
                PostsPageView(page: page, onLoadMore: {
                    pages.append(page + 1)
                })
            }
        }
    }
}
```

## Configuration

Choose a storage backend with `CacheStorageKind`. The default is `.inMemory`.

```swift
import SwiftUIQuery

let memoryClient = try QueryClient(storage: .inMemory)
let fileClient = try QueryClient(storage: .codable(directory: url))
```

For SQLite persistence, add the `SwiftUIQueryGRDB` product and import it:

```swift
import SwiftUIQuery
import SwiftUIQueryGRDB

let persistentClient = try QueryClient(storage: .grdb(.persistent))
let ephemeralClient = try QueryClient(storage: .grdb(.ephemeral))
```

You can also supply a fully custom backend via `.custom`:

```swift
let customClient = try QueryClient(storage: .custom { MyCacheStorage() })
```

### Custom Cache Location

```swift
import SwiftUIQueryGRDB

let client = try QueryClient(
    storage: .grdb(.custom(
        path: "/custom/path/cache.sqlite",
        useWAL: true,
        maxSize: 50_000_000  // 50MB
    ))
)

QueryClientProvider(client: client) {
    ContentView()
}
```

### In-Memory Cache (Testing)

```swift
let testClient = try QueryClient(
    storage: .inMemory,
    defaultOptions: QueryOptions(staleTime: .zero)
)
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      SwiftUI View                        │
│  ┌─────────────────┐    ┌─────────────────────────────┐ │
│  │ @Query          │    │ @Mutation                   │ │
│  └────────┬────────┘    └─────────────┬───────────────┘ │
└───────────┼───────────────────────────┼─────────────────┘
            │                           │
            ▼                           ▼
┌───────────────────────────────────────────────────────┐
│                    QueryClient                         │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────────┐  │
│  │ Active      │  │ Invalidation│  │ Prefetch      │  │
│  │ Queries     │  │ Manager     │  │ Queue         │  │
│  └──────┬──────┘  └──────┬──────┘  └───────────────┘  │
└─────────┼────────────────┼────────────────────────────┘
          │                │
          ▼                ▼
┌───────────────────────────────────────────────────────┐
│                  QueryCache (actor)                    │
│  ┌─────────────────┐    ┌───────────────────────────┐ │
│  │ Memory L1 cache │    │ In-memory broadcaster     │ │
│  │ (Fast Access)   │    │ - per-key change events   │ │
│  └─────────────────┘    │ - per-subscriber de-dup   │ │
│           │             └───────────────────────────┘ │
│           ▼                                            │
│  ┌───────────────────────────────────────────────┐   │
│  │ CacheStorage (persistence only)               │   │
│  │   .grdb (SQLite) │ .inMemory │ .codable (files)│   │
│  └───────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────┘
```

Persistence is swappable behind the `CacheStorage` protocol; change-eventing is an
in-memory broadcaster owned by `QueryCache`, independent of the chosen backend.

## License

MIT License. See [LICENSE](LICENSE) for details.
