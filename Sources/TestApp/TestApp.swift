import SwiftUI
import SwiftUIQuery

@main
struct TestApp: App {
    private static let queryClient = try! QueryClient(
        storage: .inMemory,
        defaultOptions: QueryOptions(
            staleTime: .seconds(30),
            retryAttempts: 2,
            retryDelay: .seconds(1)
        )
    )

    @State private var server = MockServer(configuration: .init(latencyRange: 300...800))

    var body: some Scene {
        WindowGroup {
            QueryClientProvider(client: Self.queryClient) {
                ContentView()
            }
            .mockServer(server)
        }
    }
}

struct ContentView: View {
    @Environment(\.mockServer) private var server

    var body: some View {
        TabView {
            UsersTab()
                .tabItem {
                    Label("Users", systemImage: "person.3")
                }

            PostsTab()
                .tabItem {
                    Label("Posts", systemImage: "doc.text")
                }

            ServerControlsTab()
                .tabItem {
                    Label("Server", systemImage: "server.rack")
                }
        }
    }
}
