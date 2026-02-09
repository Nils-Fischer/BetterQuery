# ``BetterQuery``

BetterQuery is a TanStack Query-inspired cache and observation library for Swift and SwiftUI.

## Overview

BetterQuery uses a hook-first API with throwing query functions:

- `QueryOptions<Data>` defines the query key, options, and `queryFn`.
- `QueryClient.fetchQuery` and `QueryClient.refetchQuery` are `async throws`.
- `QueryClient.observeQuery` emits `QueryResult<Data>`.
- SwiftUI wrappers (`QueryObservable`, `QueriesObservable`) expose loading/fetching/error state directly.

## Core Example

```swift
import BetterQuery

enum TodosError: Error {
    case network
}

let client = QueryClient()

let options = QueryOptions<[Todo]>(
    queryKey: [.string("todos")],
    queryFn: { _ in
        try await api.fetchTodos()
    },
    retry: .maxAttempts(2),
    staleTime: .milliseconds(60_000)
)

let data = try await client.fetchQuery(options)
let refreshed = try await client.refetchQuery(options)

let stream = await client.observeQuery(options)
for await state in stream {
    if state.isSuccess, let data = state.data {
        print("todos", data)
    }
}
```

## SwiftUI Observable Example

```swift
import BetterQuery
import Observation

@MainActor
@Observable
final class TodosModel {
    private let query: QueryObservable<[Todo]>

    init(client: QueryClient) {
        query = client.useQuery(
            QueryOptions<[Todo]>(
                queryKey: [.string("todos")],
                queryFn: { _ in try await api.fetchTodos() }
            )
        )
    }

    var data: [Todo]? { query.data }
    var isLoading: Bool { query.isLoading }
    var error: (any Error)? { query.error }

    func refetch() {
        _ = query.refetch()
    }
}
```

## Cache APIs

- ``QueryClient/getQueryData(queryKey:as:)``
- ``QueryClient/setQueryData(queryKey:data:)``
- ``QueryClient/setQueryData(queryKey:updater:)``
- ``QueryClient/invalidateQueries(filters:options:)``

## See Also

- ``QueryOptions``
- ``QueryResult``
- ``QueryObservable``
- ``QueriesObservable``
