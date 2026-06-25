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

struct UserQuery: QueryKey {
    typealias Response = User
    let userId: Int
    
    var cacheKey: String { "user:\(userId)" }
    var tags: Set<QueryTag> { [.users, .user(userId)] }
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
            await $user.refetch()
        }
    }
}
```

### 3. Invalidate on Mutation

```swift
struct UpdateUserView: View {
    @Mutation(invalidates: .users) { input in
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

### Query Keys

Query keys uniquely identify cached data and define invalidation relationships:

```swift
struct UserQuery: QueryKey {
    typealias Response = User
    let userId: Int
    
    // Unique identifier for this specific query
    var cacheKey: String { "user:\(userId)" }
    
    // Tags for hierarchical invalidation
    var tags: Set<QueryTag> { [.users, .user(userId)] }
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
await client.invalidate(tag: .users)  // Invalidates ALL user-related queries
await client.invalidate(tag: .user(123))  // Invalidates user 123 and their posts
```

Built-in tag factories:

```swift
QueryTag.users                    // ["users"]
QueryTag.user(123)               // ["users", "123"]
QueryTag.userPosts(123)          // ["users", "123", "posts"]
QueryTag.posts                   // ["posts"]
QueryTag.post(456)               // ["posts", "456"]
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
$query.refetch()      // Manual refetch
$query.invalidate()   // Invalidate and refetch
$query.setData(data)  // Update cache directly
$query.getData()      // Read from cache
```

#### `@Query` With Dynamic Parameters

When you need to build the key from initializer inputs (common for detail screens),
declare the wrapper and assign it in `init`:

```swift
struct UserDetailView: View {
    let api: APIClient
    @Query private var user: QueryObserver<UserQuery>

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
    mutationFn: (Input) async throws -> Output
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
    onMutate: { input in
        // Return any context needed for rollback
        ["optimisticId": UUID()]
    },
    onSuccess: { output, input in
        _ = (output, input)
    },
    onError: { error, input, context in
        _ = (error, input, context)
    },
    onSettled: { output, error, input in
        _ = (output, error, input)
    },
    mutationFn: { input in
        try await api.createPost(input)
    }
) var createPost
```

Note: `@Mutation` doesn’t receive `EnvironmentValues` like `@Query` does. Prefer passing
dependencies (e.g. API client) as captured values or view initializer parameters.

Note: when used in SwiftUI, `@Mutation` invalidates using the environment `queryClient` (via `QueryClientProvider`). If you use `MutationState` directly and configure invalidation tags, you must provide a `QueryClient`.

### QueryClient

Access the shared client or inject via environment:

```swift
// Shared instance
await QueryClient.shared.invalidate(tag: .users)

// Environment
@Environment(\.queryClient) var client
await client.prefetch(UserQuery(userId: id)) {
    try await api.fetchUser(id: id)
}
```

```swift
// Fetching
client.fetch(key, fetcher:)       // Fetch with cache
client.query(key, fetcher:)       // Create observable query
client.prefetch(key, fetcher:)    // Background prefetch

// Invalidation
client.invalidate(tag:)           // Invalidate by tag
client.invalidate(key:)           // Invalidate specific key

// Cache manipulation
client.setQueryData(key, data:)   // Write to cache
client.getQueryData(key)          // Read from cache
client.removeQueryData(key)       // Delete from cache
client.clear()                    // Clear all cache
```

### QueryOptions

```swift
QueryOptions(
    staleTime: .zero,           // When data becomes stale
    cacheTime: .minutes(5),     // When to garbage collect
    refetchOnFocus: false,      // Refetch when app becomes active
    refetchOnReconnect: true,   // Refetch when connectivity is restored
    retryCount: 3,              // Retry attempts on failure
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
        let previous = await $post.getData()
        
        // 2. Optimistic update
        await $post.setData(post.withLikeCount(post.likeCount + 1))
        
        do {
            // 3. Server mutation
            try await likePost.mutate(post.id)
        } catch {
            // 4. Rollback on error
            if let previous {
                await $post.setData(previous)
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
        await client.prefetch(UserQuery(userId: user.id)) {
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
    
    var cacheKey: String { "posts:page:\(page)" }
    var tags: Set<QueryTag> { [.posts] }
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

QueryClient()                                       // .inMemory (default, no disk)
QueryClient(storage: .inMemory)                     // process-lifetime, no disk
QueryClient(storage: .codable(directory: url))      // one JSON file per key
```

For SQLite persistence, add the `SwiftUIQueryGRDB` product and import it:

```swift
import SwiftUIQuery
import SwiftUIQueryGRDB

QueryClient(storage: .grdb(.persistent))            // SQLite, survives launches
QueryClient(storage: .grdb(.ephemeral))             // SQLite in Caches
```

You can also supply a fully custom backend via `.custom`:

```swift
QueryClient(storage: .custom { MyCacheStorage() })  // any `CacheStorage`
```

### Custom Cache Location

```swift
import SwiftUIQueryGRDB

QueryClientProvider(
    storage: .grdb(.custom(
        path: "/custom/path/cache.sqlite",
        useWAL: true,
        maxSize: 50_000_000  // 50MB
    ))
) {
    ContentView()
}
```

### In-Memory Cache (Testing)

```swift
let testClient = QueryClient(
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
