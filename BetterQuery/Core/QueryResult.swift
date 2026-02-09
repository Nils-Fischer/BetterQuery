import Foundation

public struct QueryResult<Data: Sendable>: @unchecked Sendable {
    public let status: QueryStatus
    public let fetchStatus: FetchStatus
    public let data: Data?
    public let dataUpdatedAt: Date?
    public let error: (any Error)?
    public let errorUpdatedAt: Date?
    public let failureCount: Int
    public let failureReason: (any Error)?
    public let isPending: Bool
    public let isSuccess: Bool
    public let isError: Bool
    public let isInitialLoading: Bool
    public let isLoading: Bool
    public let isFetching: Bool
    public let isRefetching: Bool
    public let isLoadingError: Bool
    public let isRefetchError: Bool
    public let isPaused: Bool
    public let isStale: Bool
    public let isEnabled: Bool

    public var result: Result<Data, any Error>? {
        switch status {
        case .pending:
            return nil
        case .success:
            guard let data else { return nil }
            return .success(data)
        case .error:
            guard let error else { return nil }
            return .failure(error)
        }
    }
}

public struct AnyQueryError: Error, @unchecked Sendable {
    public let error: any Error

    public init(_ error: any Error) {
        self.error = error
    }
}

public struct AnyQueryResult: Sendable {
    public let status: QueryStatus
    public let fetchStatus: FetchStatus
    public let data: AnySendableValue?
    public let dataUpdatedAt: Date?
    public let error: AnyQueryError?
    public let errorUpdatedAt: Date?
    public let failureCount: Int
    public let failureReason: AnyQueryError?
    public let isPending: Bool
    public let isSuccess: Bool
    public let isError: Bool
    public let isInitialLoading: Bool
    public let isLoading: Bool
    public let isFetching: Bool
    public let isRefetching: Bool
    public let isLoadingError: Bool
    public let isRefetchError: Bool
    public let isPaused: Bool
    public let isStale: Bool
    public let isEnabled: Bool
}

public struct AnySendableValue: @unchecked Sendable {
    public let rawValue: Any

    public init<T: Sendable>(_ value: T) {
        rawValue = value
    }

    public func decode<T>(_ type: T.Type = T.self) -> T? {
        return rawValue as? T
    }
}
