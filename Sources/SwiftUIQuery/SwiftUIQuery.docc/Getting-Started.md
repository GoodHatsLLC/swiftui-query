# Getting Started

SwiftUIQuery is a small, SwiftUI-first data fetching layer inspired by React Query.

## Define a Query Key

Create a type that conforms to ``QueryKey``. The key provides a stable cache identifier and
the tags used for invalidation.

```swift
import SwiftUIQuery

struct UserQuery: QueryKey {
    typealias Response = User
    let id: Int

    var cacheKey: String { "users:\(id)" }
    var tags: Set<QueryTag> { [.users, .user(id)] }
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
    var body: some Scene {
        WindowGroup {
            QueryClientProvider(storage: .grdb(.persistent)) {
                ContentView()
            }
        }
    }
}
```

## Next Steps

- Learn how to model invalidation with ``QueryTag``.
- Customize behavior with ``QueryOptions`` (stale time, retries, focus/reconnect refetch).
