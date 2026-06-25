# Getting Started

SwiftUIQuery is a small, SwiftUI-first data fetching layer inspired by React Query.

## Define a Query Key

Create a type that conforms to ``QueryKey``. The key provides a structured
``QueryIdentity`` and any broader tags used for invalidation.

```swift
import SwiftUIQuery

extension QueryTag {
    static let users = QueryTag("users")
    static func user(_ id: Int) -> QueryTag { QueryTag("users", id) }
}

struct UserQuery: QueryKey {
    typealias Response = User
    let id: Int

    var identity: QueryIdentity { QueryIdentity("users", id) }
    var invalidationTags: Set<QueryTag> { [.users] }
}
```

## Fetch In SwiftUI

Use ``Query`` to fetch and observe data, and use ``QueryActions`` through the projected value
to refetch or invalidate.

```swift
import SwiftUI
import SwiftUIQuery

struct UserView: View {
    let api: APIClient
    let userId: Int

    @Query(UserQuery(id: userId)) { _ in
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
    }
}
```

## Configure A Shared Client

SwiftUIQuery ships with an environment default (`.inMemory`), but wrapping your app
in ``QueryClientProvider`` makes configuration explicit (and is the recommended
approach for apps). For SQLite persistence, add the `SwiftUIQueryGRDB` product and
`import SwiftUIQueryGRDB` to unlock `.grdb(...)`.

```swift
import SwiftUI
import SwiftUIQuery
import SwiftUIQueryGRDB   // only needed for the .grdb backend

@main
struct MyApp: App {
    private static let queryClient = try! QueryClient(storage: .grdb(.persistent))

    var body: some Scene {
        WindowGroup {
            QueryClientProvider(client: Self.queryClient) {
                ContentView()
            }
        }
    }
}
```

## Next Steps

- Learn how to model invalidation with ``QueryTag``.
- Customize behavior with ``QueryOptions`` (stale time, retries, focus/reconnect refetch).
