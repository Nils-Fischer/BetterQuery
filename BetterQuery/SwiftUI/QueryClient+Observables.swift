import Foundation

@MainActor
public extension QueryClient {
    func makeQueryObservable<Data: Sendable, Failure: Error & Sendable>(
        _ options: QueryOptions<Data, Failure>
    ) -> QueryObservable<Data, Failure> {
        QueryObservable(client: self, options: options)
    }

    func makeQueriesObservable<Data: Sendable, Failure: Error & Sendable, Combined: Sendable>(
        _ options: [QueryOptions<Data, Failure>],
        combine: @escaping @Sendable ([QueryState<Data, Failure>]) -> Combined
    ) -> QueriesObservable<Data, Failure, Combined> {
        QueriesObservable(client: self, options: options, combine: combine)
    }
}
