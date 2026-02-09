import Foundation

public struct QueryState<Data: Sendable, Failure: Error & Sendable>: Sendable {
    public let status: QueryStatus
    public let fetchStatus: FetchStatus
    public let data: Data?
    public let dataUpdatedAt: Date?
    public let error: Failure?
    public let errorUpdatedAt: Date?
    public let failureCount: Int
    public let failureReason: Failure?
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

public struct AnyQueryState: Sendable {
    public let status: QueryStatus
    public let fetchStatus: FetchStatus
    public let data: AnySendableValue?
    public let dataUpdatedAt: Date?
    public let error: AnySendableValue?
    public let errorUpdatedAt: Date?
    public let failureCount: Int
    public let failureReason: AnySendableValue?
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
