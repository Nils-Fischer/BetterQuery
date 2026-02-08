#if canImport(SwiftUI)
import SwiftUI

private struct QueryClientEnvironmentKey: EnvironmentKey {
    static let defaultValue = QueryClient()
}

public extension EnvironmentValues {
    var queryClient: QueryClient {
        get { self[QueryClientEnvironmentKey.self] }
        set { self[QueryClientEnvironmentKey.self] = newValue }
    }
}

public extension View {
    func queryClient(_ client: QueryClient) -> some View {
        environment(\.queryClient, client)
    }
}
#endif
