# ``BetterQuery``

BetterQuery is a TanStack Query-inspired cache and observation library for Swift and SwiftUI.

## Overview

BetterQuery uses a Result-first API with typed failures:

- `QueryOptions<Data, Failure>` defines the query key, options, and `query` function.
- `QueryClient.fetch` and `QueryClient.refetch` return `Result<Data, Failure>`.
- `QueryClient.observe` emits `QueryState<Data, Failure>`.
- SwiftUI wrappers (`QueryObservable`, `QueriesObservable`) expose typed errors directly.

## Core Example

```swift
import BetterQuery

enum TodosError: Error, Sendable {
    case network
}

let client = QueryClient()

let options = QueryOptions<[Todo], TodosError>(
    queryKey: [.string("todos")],
    query: { _ in
        await api.fetchTodos()
    },
    retry: .maxAttempts(2),
    staleTime: .milliseconds(60_000)
)

let fetchResult = await client.fetch(options)
let refetchResult = await client.refetch(options)

let stream = await client.observe(options)
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
    private let query: QueryObservable<[Todo], TodosError>

    init(client: QueryClient) {
        query = client.makeQueryObservable(
            QueryOptions<[Todo], TodosError>(
                queryKey: [.string("todos")],
                query: { _ in await api.fetchTodos() }
            )
        )
    }

    var data: [Todo]? { query.data }
    var isLoading: Bool { query.isLoading }
    var error: TodosError? { query.error }

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
- ``QueryState``
- ``QueryObservable``
- ``QueriesObservable``
