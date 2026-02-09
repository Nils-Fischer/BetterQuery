import Foundation
import Observation

@MainActor
@Observable
public final class QueriesObservable<Data: Sendable, Failure: Error & Sendable, Combined: Sendable> {
    public private(set) var value: Combined?
    public private(set) var hasValue = false

    private let client: QueryClient
    private let options: [QueryOptions<Data, Failure>]
    private let combine: @Sendable ([QueryState<Data, Failure>]) -> Combined
    private var observationTask: Task<Void, Never>?

    public init(
        client: QueryClient,
        options: [QueryOptions<Data, Failure>],
        combine: @escaping @Sendable ([QueryState<Data, Failure>]) -> Combined
    ) {
        self.client = client
        self.options = options
        self.combine = combine
        start()
    }

    @MainActor deinit {
        observationTask?.cancel()
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await client.observeQueries(options, combine: combine)
            for await next in stream {
                self.value = next
                self.hasValue = true
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    @discardableResult
    public func refetchAll(cancelRefetch: Bool = true) -> Task<[Result<Data, Failure>], Never> {
        let task = Task { [options, client] in
            var results: [Result<Data, Failure>] = []
            results.reserveCapacity(options.count)
            for option in options {
                results.append(await client.refetch(option, cancelRefetch: cancelRefetch))
            }
            return results
        }
        return task
    }
}
