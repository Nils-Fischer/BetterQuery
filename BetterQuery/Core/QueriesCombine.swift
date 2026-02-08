import Foundation

private struct QueryResultFingerprint: Equatable, Sendable {
    let status: QueryStatus
    let fetchStatus: FetchStatus
    let dataUpdatedAt: Date?
    let errorUpdatedAt: Date?
    let failureCount: Int
    let isStale: Bool
    let isEnabled: Bool
    let hasData: Bool
    let hasError: Bool
    let isPaused: Bool

    init<Data: Sendable>(_ result: QueryResult<Data>) {
        status = result.status
        fetchStatus = result.fetchStatus
        dataUpdatedAt = result.dataUpdatedAt
        errorUpdatedAt = result.errorUpdatedAt
        failureCount = result.failureCount
        isStale = result.isStale
        isEnabled = result.isEnabled
        hasData = result.data != nil
        hasError = result.error != nil
        isPaused = result.isPaused
    }
}

private actor CombinedResultsStore<Data: Sendable, Combined: Sendable> {
    private var latest: [QueryResult<Data>?]
    private var fingerprints: [QueryResultFingerprint?]
    private let combine: @Sendable ([QueryResult<Data>]) -> Combined
    private let continuation: AsyncStream<Combined>.Continuation

    init(
        count: Int,
        continuation: AsyncStream<Combined>.Continuation,
        combine: @escaping @Sendable ([QueryResult<Data>]) -> Combined
    ) {
        self.latest = Array(repeating: nil, count: count)
        self.fingerprints = Array(repeating: nil, count: count)
        self.continuation = continuation
        self.combine = combine
    }

    func update(index: Int, result: QueryResult<Data>) {
        let nextFingerprint = QueryResultFingerprint(result)
        if fingerprints[index] == nextFingerprint {
            return
        }

        fingerprints[index] = nextFingerprint
        latest[index] = result
        let values = latest.compactMap { $0 }
        guard values.count == latest.count else {
            return
        }
        continuation.yield(combine(values))
    }
}

extension QueryClient {
    public func observeQueries<Data: Sendable>(
        _ options: [QueryOptions<Data>]
    ) -> AsyncStream<[QueryResult<Data>]> {
        observeQueries(options, combine: { $0 })
    }

    public func observeQueries<Data: Sendable, Combined: Sendable>(
        _ options: [QueryOptions<Data>],
        combine: @escaping @Sendable ([QueryResult<Data>]) -> Combined
    ) -> AsyncStream<Combined> {
        if options.isEmpty {
            return AsyncStream { continuation in
                continuation.yield(combine([]))
                continuation.finish()
            }
        }

        let client = self
        return AsyncStream { continuation in
            let store = CombinedResultsStore<Data, Combined>(
                count: options.count,
                continuation: continuation,
                combine: combine
            )

            var createdTasks: [Task<Void, Never>] = []
            createdTasks.reserveCapacity(options.count)

            for (index, option) in options.enumerated() {
                let task = Task {
                    let stream = await client.observeQuery(option)
                    for await result in stream {
                        await store.update(index: index, result: result)
                    }
                }
                createdTasks.append(task)
            }

            let tasks = createdTasks
            continuation.onTermination = { _ in
                tasks.forEach { $0.cancel() }
            }
        }
    }
}
