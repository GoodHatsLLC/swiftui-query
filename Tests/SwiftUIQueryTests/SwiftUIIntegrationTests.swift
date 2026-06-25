#if canImport(SwiftUI) && canImport(AppKit)

import AppKit
import SwiftUI
import XCTest
@testable import SwiftUIQuery

@MainActor
final class SwiftUIIntegrationTests: XCTestCase {
    func testQueryPropertyWrapperFetchesUsingEnvironmentClient() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = FetchCounter()

        struct TestView: View {
            @Query
            private var user: QueryObserver<TestUserQuery>

            init(counter: FetchCounter) {
                _user = Query(
                    TestUserQuery(userId: 1),
                    options: .init(staleTime: .seconds(0)),
                    fetch: { env in
                        _ = env
                        await counter.increment()
                        return TestUser(id: 1, name: "User 1")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
            }
        }

        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                TestView(counter: counter)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 2.0) {
            let cached = try? await cache.get(key: "user:1", as: TestUser.self)
            return cached?.data.name == "User 1"
        }
    }

    func testQueryPropertyWrapperReplacesObserverWhenKeyChanges() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = FetchCounter()

        final class Model: ObservableObject {
            @Published var userId: Int = 1
        }

        struct QueryView: View {
            @Query
            private var user: QueryObserver<TestUserQuery>

            init(userId: Int, counter: FetchCounter) {
                _user = Query(
                    TestUserQuery(userId: userId),
                    options: .init(staleTime: .seconds(0)),
                    fetch: { [userId] env in
                        _ = env
                        await counter.increment()
                        return TestUser(id: userId, name: "User \(userId)")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
            }
        }

        struct ContainerView: View {
            @ObservedObject var model: Model
            let counter: FetchCounter

            var body: some View {
                QueryView(userId: model.userId, counter: counter)
            }
        }

        let model = Model()

        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                ContainerView(model: model, counter: counter)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 2.0) {
            await counter.value == 1
        }

        model.userId = 2

        try await eventually(timeout: 3.0) {
            let cached2 = try? await cache.get(key: "user:2", as: TestUser.self)
            return cached2?.data.name == "User 2"
        }
    }

    // #13: changing `options` (not just the key/client) must recreate the observer.
    func testQueryPropertyWrapperReplacesObserverWhenOptionsChange() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = FetchCounter()

        final class Model: ObservableObject {
            @Published var staleSeconds: Int = 0
        }

        struct QueryView: View {
            @Query
            private var user: QueryObserver<TestUserQuery>

            init(staleSeconds: Int, counter: FetchCounter) {
                _user = Query(
                    TestUserQuery(userId: 1),
                    options: .init(staleTime: .seconds(staleSeconds)),
                    fetch: { env in
                        _ = env
                        await counter.increment()
                        return TestUser(id: 1, name: "User 1")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
            }
        }

        struct ContainerView: View {
            @ObservedObject var model: Model
            let counter: FetchCounter
            var body: some View {
                QueryView(staleSeconds: model.staleSeconds, counter: counter)
            }
        }

        let model = Model()
        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                ContainerView(model: model, counter: counter)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 2.0) { await counter.value == 1 }

        // Changing the options must recreate the observer, which re-loads from
        // cache; the first entry was written with staleTime 0 (already stale) so
        // the new observer refetches -> the counter advances to 2.
        model.staleSeconds = 60

        try await eventually(timeout: 3.0) { await counter.value >= 2 }
    }

    func testQueryProjectedValueInvalidateTriggersRefetch() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)
        let counter = FetchCounter()

        @MainActor
        final class Sink: ObservableObject {
            var invalidate: (() async -> Void)?
        }

        struct TestView: View {
            @ObservedObject var sink: Sink

            @Query
            private var user: QueryObserver<TestUserQuery>

            init(sink: Sink, counter: FetchCounter) {
                self.sink = sink
                _user = Query(
                    TestUserQuery(userId: 99),
                    options: .init(staleTime: .seconds(0)),
                    fetch: { env in
                        _ = env
                        let count = await counter.incrementAndGet()
                        return TestUser(id: 99, name: "Fetch \(count)")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
                    .onAppear {
                        sink.invalidate = { await $user.invalidate() }
                    }
            }
        }

        let sink = await MainActor.run { Sink() }

        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                TestView(sink: sink, counter: counter)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 5.0) {
            let cached = try? await cache.get(key: "user:99", as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        try await eventually(timeout: 5.0) {
            sink.invalidate != nil
        }

        await sink.invalidate?()

        try await eventually(timeout: 5.0) {
            let cached = try? await cache.get(key: "user:99", as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }
    }

    func testQueryPropertyWrapperReplacesObserverWhenEnvironmentClientChanges() async throws {
        _ = NSApplication.shared
        let cache1 = try QueryCache(storage: .inMemory)
        let cache2 = try QueryCache(storage: .inMemory)
        let client1 = QueryClient(cache: cache1)
        let client2 = QueryClient(cache: cache2)
        let counter = FetchCounter()

        final class Model: ObservableObject {
            @Published var useSecondClient = false
        }

        struct QueryView: View {
            @Query
            private var user: QueryObserver<TestUserQuery>

            init(counter: FetchCounter) {
                _user = Query(
                    TestUserQuery(userId: 500),
                    options: .init(staleTime: .hours(1), cacheTime: .hours(1)),
                    fetch: { _ in
                        let n = await counter.incrementAndGet()
                        return TestUser(id: 500, name: "Fetch \(n)")
                    }
                )
            }

            var body: some View {
                Text(user.state.data?.name ?? "Loading")
            }
        }

        struct ContainerView: View {
            @ObservedObject var model: Model
            let counter: FetchCounter
            let client1: QueryClient
            let client2: QueryClient

            var body: some View {
                QueryView(counter: counter)
                    .queryClient(model.useSecondClient ? client2 : client1)
            }
        }

        let model = Model()
        let hosting = NSHostingController(
            rootView: ContainerView(
                model: model,
                counter: counter,
                client1: client1,
                client2: client2
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 3.0) {
            let cached = try? await cache1.get(key: "user:500", as: TestUser.self)
            return cached?.data.name == "Fetch 1"
        }

        model.useSecondClient = true

        try await eventually(timeout: 3.0) {
            let cached = try? await cache2.get(key: "user:500", as: TestUser.self)
            return cached?.data.name == "Fetch 2"
        }
    }

    func testQueryPropertyWrapperUsesLatestEnvironmentOnRefetch() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)

        struct LocaleQuery: QueryKey {
            typealias Response = String

            var cacheKey: String { "locale:probe" }
            var tags: Set<QueryTag> { [QueryTag("locale")] }
        }

        @MainActor
        final class LocaleModel: ObservableObject {
            @Published var locale = Locale(identifier: "en_US")
        }

        @MainActor
        final class Sink: ObservableObject {
            var refetch: (() async -> Void)?
        }

        struct LocaleQueryView: View {
            @ObservedObject var sink: Sink

            @Query
            private var localeValue: QueryObserver<LocaleQuery>

            init(sink: Sink) {
                self.sink = sink
                _localeValue = Query(
                    LocaleQuery(),
                    options: .init(staleTime: .hours(1), cacheTime: .hours(1)),
                    fetch: { env in
                        env.locale.identifier
                    }
                )
            }

            var body: some View {
                Text(localeValue.state.data ?? "Loading")
                    .onAppear {
                        sink.refetch = { await $localeValue.refetch() }
                    }
            }
        }

        struct ContainerView: View {
            @ObservedObject var model: LocaleModel
            @ObservedObject var sink: Sink
            let client: QueryClient

            var body: some View {
                LocaleQueryView(sink: sink)
                    .environment(\.locale, model.locale)
                    .queryClient(client)
            }
        }

        let model = await MainActor.run { LocaleModel() }
        let sink = await MainActor.run { Sink() }
        let hosting = NSHostingController(
            rootView: ContainerView(model: model, sink: sink, client: client)
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        try await eventually(timeout: 3.0) {
            let cached = try? await cache.get(key: "locale:probe", as: String.self)
            return cached?.data == "en_US"
        }

        try await eventually(timeout: 2.0) {
            sink.refetch != nil
        }

        model.locale = Locale(identifier: "fr_FR")
        await sink.refetch?()

        try await eventually(timeout: 3.0) {
            let cached = try? await cache.get(key: "locale:probe", as: String.self)
            return cached?.data == "fr_FR"
        }
    }

    func testMutationPropertyWrapperInvalidatesUsingEnvironmentClient() async throws {
        _ = NSApplication.shared
        let cache = try QueryCache(storage: .inMemory)
        let client = QueryClient(cache: cache)

        let key = TestUserQuery(userId: 10)
        try await cache.set(
            key: key.cacheKey,
            data: TestUser(id: 10, name: "Cached"),
            tags: key.tags,
            staleTime: .hours(1),
            cacheTime: .hours(1)
        )

        @MainActor
        final class Sink: ObservableObject {
            var run: (() async throws -> Void)?
        }

        struct MutationView: View {
            @ObservedObject var sink: Sink

            @Mutation(
                invalidates: QueryTag("users"),
                mutationFn: { () async throws -> Void in () }
            )
            var mutation

            var body: some View {
                Color.clear
                    .task {
                        sink.run = { try await mutation.mutate() }
                    }
            }
        }

        let sink = await MainActor.run { Sink() }
        let hosting = NSHostingController(
            rootView: QueryClientProvider(client: client) {
                MutationView(sink: sink)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        try await eventually(timeout: 2.0) {
            sink.run != nil
        }

        defer { window.close() }
        try await sink.run?() ?? XCTFail("Expected mutation runner")

        let cached = try await cache.get(key: key.cacheKey, as: TestUser.self)
        XCTAssertEqual(cached?.isStale, true)
    }
}

// MARK: - Helpers

private actor FetchCounter {
    private var count = 0

    func increment() { count += 1 }

    func incrementAndGet() -> Int {
        count += 1
        return count
    }

    var value: Int { count }
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
