# BetterQuery

TanStack Query-inspired query caching and observation for Swift and SwiftUI.

## Installation

Add BetterQuery via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/Nils-Fischer/BetterQuery.git", from: "0.3.0")
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
    @State private var query: QueryObservable<String>?

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
                query = client.useQuery(
                    QueryOptions<String>(
                        queryKey: [.string("hello")],
                        queryFn: { _ in "Hello BetterQuery" },
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
let q = client.useQuery(
    QueryOptions<Content>(
        queryKey: [.string("enrichedContent"), .string(sharedContent.url)],
        queryFn: { _ in try await resolveContent(sharedContent.url) },
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

## Core API

- `fetchQuery(_:)` / `refetchQuery(_:cancelRefetch:)` for imperative loads
- `observeQuery(_:)` for state streaming
- `invalidateQueries` / `refetchQueries` for cache orchestration
- `getQueryData` / `setQueryData` for cache access

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
