import SwiftUI

private struct MockServerKey: EnvironmentKey {
    static let defaultValue: MockServer = MockServer()
}

extension EnvironmentValues {
    var mockServer: MockServer {
        get { self[MockServerKey.self] }
        set { self[MockServerKey.self] = newValue }
    }
}

extension View {
    func mockServer(_ server: MockServer) -> some View {
        environment(\.mockServer, server)
    }
}
