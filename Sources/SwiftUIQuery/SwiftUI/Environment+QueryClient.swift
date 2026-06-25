#if canImport(SwiftUI)
import SwiftUI

// MARK: - Environment Key

@MainActor
private struct QueryClientKey: @preconcurrency EnvironmentKey {
    static let defaultValue: QueryClient = .shared
}

extension EnvironmentValues {
    /// The query client for this environment
    public var queryClient: QueryClient {
        get { self[QueryClientKey.self] }
        set { self[QueryClientKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    /// Provides a custom query client to the view hierarchy
    public func queryClient(_ client: QueryClient) -> some View {
        environment(\.queryClient, client)
    }
}

// MARK: - Query Client Provider

/// A view that provides a QueryClient to its content
@MainActor
public struct QueryClientProvider<Content: View>: View {
    @State private var client: QueryClient
    private let content: Content

    public init(
        client: QueryClient,
        @ViewBuilder content: () -> Content
    ) {
        self._client = State(initialValue: client)
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.queryClient, client)
    }
}
#endif
