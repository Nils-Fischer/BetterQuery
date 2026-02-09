import Foundation

@MainActor
public extension QueryClient {
    func useQuery<Data: Sendable>(
        _ options: QueryOptions<Data>
    ) -> QueryObservable<Data> {
        QueryObservable(client: self, options: options)
    }

    func useQueries<Data: Sendable, Combined: Sendable>(
        _ options: [QueryOptions<Data>],
        combine: @escaping @Sendable ([QueryResult<Data>]) -> Combined
    ) -> QueriesObservable<Data, Combined> {
        QueriesObservable(client: self, options: options, combine: combine)
    }
}
