# ``BetterQuery``

Swift query caching and observation primitives inspired by TanStack Query defaults.

## Overview

BetterQuery provides a cache-first query client with explicit stale handling, invalidation,
retry behavior, and async observation APIs.

For implementation parity details against TanStack Query, see
`/Users/nilsfischer/Code/BetterQuery/docs/tanstack-parity-matrix.md`.

## Installation

Use Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/BetterQuery.git", from: "0.1.0")
]
```

The core model keeps two independent dimensions:

- `status`: query data state (`pending`, `success`, `error`)
- `fetchStatus`: transport state (`idle`, `fetching`, `paused`)

This matches TanStack Query's distinction between data and transport lifecycles and makes
loading/refetch states predictable.

## Defaults

Key defaults in this library:

- `staleTime` defaults to `0` (`.milliseconds(0)`).
- Observer-driven fetching retries up to 3 times by default.
- `fetchQuery` disables retries by default (imperative fetch behavior).
- Retry delay uses exponential backoff from `1000ms`, capped at `30000ms`.
- `gcTime` defaults to 5 minutes for inactive queries.
- `refetchOnMount` and `refetchOnWindowFocus` default to stale-only.
- `refetchOnReconnect` defaults to stale-only unless `networkMode == .always`
  (then it defaults to never).

## Core Example

```swift
import BetterQuery

let client = QueryClient()

let todosOptions = QueryOptions<[Todo]>(
    queryKey: [.string("todos")],
    queryFn: { _ in try await api.fetchTodos() }
)

// Imperative fetch (cache-aware, retry disabled by default).
let todos = try await client.fetchQuery(todosOptions)

// Live observation stream (observer defaults apply, including retry behavior).
let stream = await client.observeQuery(todosOptions)
for await result in stream {
    if result.isSuccess {
        print(result.data ?? [])
    }
}
```

## Invalidation And Refetch

`invalidateQueries` marks matching queries stale/invalidated first, then optionally refetches.

```swift
try await client.invalidateQueries(
    filters: QueryFilters(queryKey: [.string("todos")]),
    options: InvalidateOptions(
        refetchType: .active,
        cancelRefetch: true,
        throwOnError: true
    )
)
```

`refetchQueries` can target by key, active/inactive type, staleness, and fetch status.

`throwOnError` behavior:
- `false` (default): per-query refetch errors are swallowed and refetch continues.
- `true`: first refetch error is thrown to the caller.

## Cancellation Token

Query functions receive a cancellation token via ``QueryFunctionContext/cancellationToken``.
Use it to cancel underlying transport work when a query/refetch gets cancelled.

```swift
let options = QueryOptions<Data>(
    queryKey: [.string("resource"), .int(id)],
    queryFn: { context in
        let task = api.startRequest(id: id)
        context.cancellationToken.onCancel {
            task.cancel()
        }
        return try await task.value
    }
)
```

## SwiftUI Integration

Use the environment key for app-wide client injection:

```swift
import SwiftUI
import BetterQuery

@main
struct MyApp: App {
    let client = QueryClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .queryClient(client)
        }
    }
}
```

Create observable wrappers directly from the client:

```swift
@MainActor
func makeModel(client: QueryClient) -> QueryObservable<[Todo]> {
    client.makeQueryObservable(
        QueryOptions(
            queryKey: [.string("todos")],
            queryFn: { _ in try await api.fetchTodos() }
        )
    )
}
```

For multi-query aggregation, use:
- ``QueryClient/makeQueriesObservable(_:combine:)``
- ``QueriesObservable``

## Topics

### Core

- ``QueryClient``
- ``QueryOptions``
- ``QueryFunctionContext``
- ``QueryResult``
- ``QueryFilters``
- ``InvalidateOptions``
- ``RefetchOptions``
- ``QueryValue``
- ``QueryCancellationToken``

### SwiftUI

- ``QueryObservable``
- ``QueriesObservable``
