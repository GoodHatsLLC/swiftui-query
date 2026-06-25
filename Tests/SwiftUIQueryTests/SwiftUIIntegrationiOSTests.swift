#if canImport(UIKit) && canImport(SwiftUI)

import SwiftUI
import UIKit
import XCTest
@testable import SwiftUIQuery

@MainActor
final class SwiftUIIntegrationiOSTests: XCTestCase {
    func testQueryPropertyWrapperRefetchesOnUIApplicationDidBecomeActiveWhenEnabled() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: true)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )
        let counter = Counter()

        await lifecycle.ensureSystemObserversInstalledForTesting()

        struct TestView: View {
            @Query
            private var user: QueryObserver<TestUserQuery>

            init(counter: Counter) {
                _user = Query(
                    TestUserQuery(userId: 123),
                    options: .init(
                        staleTime: .hours(1),
                        cacheTime: .hours(1),
                        refetchOnFocus: true,
                        refetchOnReconnect: false,
                        retryCount: 1
                    ),
                    fetch: { _ in
                        let n = await counter.incrementAndGet()
                        return TestUser(id: 123, name: "Fetch \(n)")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
            }
        }

        let window = UIWindow(frame: UIScreen.main.bounds)
        let host = UIHostingController(
            rootView: QueryClientProvider(client: client) {
                TestView(counter: counter)
            }
        )

        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await eventually(timeout: 3.0) {
            let cached = try? await cache.get(key: "user:123", as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        try await eventually(timeout: 3.0) {
            let cached = try? await cache.get(key: "user:123", as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }
    }

    func testQueryObserverRefetchesOnReconnectTransitionOnIOS() async throws {
        let cache = try QueryCache(storage: .inMemory)
        let lifecycle = AppLifecycleMonitor(observeSystemNotifications: false)
        let connectivity = ConnectivityMonitor(startMonitoring: false, initialStatus: .satisfied)
        let client = QueryClient(
            cache: cache,
            lifecycleMonitor: lifecycle,
            connectivityMonitor: connectivity
        )
        let counter = Counter()

        let key = TestUserQuery(userId: 999)
        let observer = client.query(
            key,
            options: .init(
                staleTime: .hours(1),
                cacheTime: .hours(1),
                refetchOnFocus: false,
                refetchOnReconnect: true,
                retryCount: 1
            ),
            fetcher: {
                let n = await counter.incrementAndGet()
                return TestUser(id: 999, name: "Fetch \(n)")
            }
        )
        observer.startObserving()

        try await eventually(timeout: 3.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        await connectivity.setStatusForTesting(.unsatisfied)
        await connectivity.setStatusForTesting(.satisfied)

        try await eventually(timeout: 3.0) {
            let cached = try? await cache.get(key: key.cacheKey, as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }
    }
}

private actor Counter {
    private var count = 0

    func incrementAndGet() -> Int {
        count += 1
        return count
    }
}

@MainActor
private func eventually(timeout: TimeInterval, _ predicate: @escaping () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        await MainActor.run {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("Condition not met before timeout")
}

#endif
