# BetterQuery

TanStack Query-inspired query caching and observation for Swift and SwiftUI.

## Installation

Add BetterQuery via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/Nils-Fischer/BetterQuery.git", from: "0.1.0")
]
```

Then add the product dependency:

```swift
.product(name: "BetterQuery", package: "BetterQuery")
```

## Quick Start (SwiftUI Observable)

```swift
import SwiftUI
import BetterQuery

@main
struct DemoApp: App {
    let queryClient = QueryClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .queryClient(queryClient)
        }
    }
}

struct ContentView: View {
    @Environment(\.queryClient) private var client
    enum QueryFailure: Error, Sendable {
        case network
    }

    @State private var query: QueryObservable<String, QueryFailure>?

    var body: some View {
        Group {
            if let query {
                if query.isError {
                    VStack {
                        Text("Failed to load")
                        Button("Retry") { _ = query.refetch() }
                    }
                } else if query.isLoading || query.data == nil {
                    ProgressView()
                } else {
                    Text(query.data ?? "")
                }
            } else {
                ProgressView()
            }
        }
        .task {
            if query == nil {
                query = client.makeQueryObservable(
                    QueryOptions<String, QueryFailure>(
                        queryKey: [.string("hello")],
                        query: { _ in .success("Hello BetterQuery") },
                        retry: .maxAttempts(2),
                        staleTime: .milliseconds(24 * 60 * 60 * 1000)
                    )
                )
            }
        }
        .onDisappear {
            query?.stop()
        }
    }
}
```

## Equivalent to `useQuery`

```swift
let q = client.makeQueryObservable(
    QueryOptions<Content, ContentResolverError>(
        queryKey: [.string("enrichedContent"), .string(sharedContent.url)],
        query: { _ in await resolveContent(sharedContent.url) },
        retry: .maxAttempts(2),
        staleTime: .milliseconds(24 * 60 * 60 * 1000)
    )
)

let content = q.data
let isLoading = q.isLoading
let isError = q.isError
let error = q.error
_ = q.refetch()
```

## Highlights

- Cache keyed by stable query keys with partial-key filtering
- Stale-time and invalidation semantics
- Retry and retry-delay defaults aligned to TanStack-style behavior
- Refetch controls (`cancelRefetch`, `throwOnError`)
- SwiftUI observation wrappers (`QueryObservable`, `QueriesObservable`)
- Query cancellation token in `QueryFunctionContext`

## Status

- SPM package + tests are passing.
- Core parity matrix: `docs/tanstack-parity-matrix.md`
- Detailed roadmap: `docs/swift-query-port-plan.md`
