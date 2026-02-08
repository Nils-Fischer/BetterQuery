import Foundation
import Observation

@MainActor
@Observable
public final class QueriesObservable<Data: Sendable, Combined: Sendable> {
    public private(set) var value: Combined?
    public private(set) var hasValue = false

    private let client: QueryClient
    private let options: [QueryOptions<Data>]
    private let combine: @Sendable ([QueryResult<Data>]) -> Combined
    private var observationTask: Task<Void, Never>?

    public init(
        client: QueryClient,
        options: [QueryOptions<Data>],
        combine: @escaping @Sendable ([QueryResult<Data>]) -> Combined
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
    public func refetchAll(cancelRefetch: Bool = true) -> Task<Void, Never> {
        let task = Task { [options, client] in
            for option in options {
                _ = try? await client.refetchQuery(option, cancelRefetch: cancelRefetch)
            }
        }
        return task
    }
}
