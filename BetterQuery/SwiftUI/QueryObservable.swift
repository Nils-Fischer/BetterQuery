import Foundation
import Observation

@MainActor
@Observable
public final class QueryObservable<Data: Sendable> {
    public private(set) var status: QueryStatus = .pending
    public private(set) var fetchStatus: FetchStatus = .idle
    public private(set) var data: Data?
    public private(set) var error: QueryError?
    public private(set) var isPending = true
    public private(set) var isLoading = false
    public private(set) var isRefetching = false
    public private(set) var isFetching = false
    public private(set) var isStale = true
    public private(set) var isEnabled = true

    private let client: QueryClient
    private let options: QueryOptions<Data>
    private var observationTask: Task<Void, Never>?

    public init(client: QueryClient, options: QueryOptions<Data>) {
        self.client = client
        self.options = options
        start()
    }

    @MainActor deinit {
        observationTask?.cancel()
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await client.observeQuery(options)
            for await result in stream {
                self.apply(result)
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    @discardableResult
    public func refetch() -> Task<Void, Never> {
        let task = Task { [options, client] in
            _ = try? await client.refetchQuery(options)
        }
        return task
    }

    private func apply(_ result: QueryResult<Data>) {
        status = result.status
        fetchStatus = result.fetchStatus
        data = result.data
        error = result.error
        isPending = result.isPending
        isLoading = result.isLoading
        isRefetching = result.isRefetching
        isFetching = result.isFetching
        isStale = result.isStale
        isEnabled = result.isEnabled
    }
}
