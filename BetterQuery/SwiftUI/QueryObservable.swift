import Foundation
import Observation

@MainActor
@Observable
public final class QueryObservable<Data: Sendable, Failure: Error & Sendable> {
    public private(set) var status: QueryStatus = .pending
    public private(set) var fetchStatus: FetchStatus = .idle
    public private(set) var data: Data?
    public private(set) var error: Failure?
    public private(set) var isPending = true
    public private(set) var isSuccess = false
    public private(set) var isError = false
    public private(set) var isLoading = false
    public private(set) var isRefetching = false
    public private(set) var isFetching = false
    public private(set) var isStale = true
    public private(set) var isEnabled = true

    private let client: QueryClient
    private let options: QueryOptions<Data, Failure>
    private var observationTask: Task<Void, Never>?

    public init(client: QueryClient, options: QueryOptions<Data, Failure>) {
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
            let stream = await client.observe(options)
            for await state in stream {
                self.apply(state)
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    @discardableResult
    public func refetch(cancelRefetch: Bool = true) -> Task<Result<Data, Failure>, Never> {
        let task = Task { [options, client] in
            await client.refetch(options, cancelRefetch: cancelRefetch)
        }
        return task
    }

    private func apply(_ state: QueryState<Data, Failure>) {
        status = state.status
        fetchStatus = state.fetchStatus
        data = state.data
        error = state.error
        isPending = state.isPending
        isSuccess = state.isSuccess
        isError = state.isError
        isLoading = state.isLoading
        isRefetching = state.isRefetching
        isFetching = state.isFetching
        isStale = state.isStale
        isEnabled = state.isEnabled
    }
}
