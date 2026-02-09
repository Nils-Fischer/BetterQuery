import Foundation
import Observation

@MainActor
@Observable
public final class QueryObservable<Data: Sendable> {
    public private(set) var status: QueryStatus = .pending
    public private(set) var fetchStatus: FetchStatus = .idle
    public private(set) var data: Data?
    public private(set) var error: (any Error)?
    public private(set) var isPending = true
    public private(set) var isSuccess = false
    public private(set) var isError = false
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
    public func refetch(cancelRefetch: Bool = true) -> Task<Result<Data, any Error>, Never> {
        let task = Task { [options, client] in
            do {
                let value = try await client.refetchQuery(options, cancelRefetch: cancelRefetch)
                return Result<Data, any Error>.success(value)
            } catch {
                return Result<Data, any Error>.failure(error)
            }
        }
        return task
    }

    private func apply(_ state: QueryResult<Data>) {
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
