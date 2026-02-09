import Foundation

public enum QueryStatus: String, Sendable {
    case pending
    case success
    case error
}

public enum FetchStatus: String, Sendable {
    case idle
    case fetching
    case paused
}

public enum NetworkMode: Sendable {
    case online
    case always
    case offlineFirst
}

public enum StaleTime: Sendable, Equatable {
    case milliseconds(Int)
    case infinity
    case `static`
}

public enum EnabledOption: Sendable {
    case value(Bool)
    case resolver(@Sendable (QueryStateSummary) -> Bool)

    func resolve(_ state: QueryStateSummary) -> Bool {
        switch self {
        case let .value(value):
            return value
        case let .resolver(resolver):
            return resolver(state)
        }
    }
}

public enum RetryOption: Sendable {
    case disabled
    case indefinitely
    case maxAttempts(Int)
    case resolver(@Sendable (_ failureCount: Int, _ error: any Error) -> Bool)

    func shouldRetry(failureCount: Int, error: any Error) -> Bool {
        switch self {
        case .disabled:
            return false
        case .indefinitely:
            return true
        case let .maxAttempts(maxAttempts):
            return failureCount < maxAttempts
        case let .resolver(resolver):
            return resolver(failureCount, error)
        }
    }
}

public enum RetryDelayOption: Sendable {
    case milliseconds(Int)
    case resolver(@Sendable (_ failureCount: Int, _ error: any Error) -> Int)
}

public enum RefetchOption: Sendable {
    case stale
    case never
    case always
}

public struct QueryStateSummary: Sendable {
    public let queryKey: QueryKey
    public let queryHash: String
    public let status: QueryStatus
    public let fetchStatus: FetchStatus
    public let hasData: Bool
    public let isInvalidated: Bool
}

public struct QueryDefaultOptions: Sendable {
    public var staleTime: StaleTime? = nil
    public var gcTime: Int? = nil
    public var retry: RetryOption? = nil
    public var retryDelay: RetryDelayOption? = nil
    public var networkMode: NetworkMode? = nil
    public var enabled: EnabledOption? = nil
    public var refetchOnMount: RefetchOption? = nil
    public var refetchOnWindowFocus: RefetchOption? = nil
    public var refetchOnReconnect: RefetchOption? = nil
    public var retryOnMount: Bool? = nil
    public var suspense: Bool? = nil
    public var throwOnError: Bool? = nil

    public init() {}

    mutating func merge(_ other: QueryDefaultOptions) {
        staleTime = other.staleTime ?? staleTime
        gcTime = other.gcTime ?? gcTime
        retry = other.retry ?? retry
        retryDelay = other.retryDelay ?? retryDelay
        networkMode = other.networkMode ?? networkMode
        enabled = other.enabled ?? enabled
        refetchOnMount = other.refetchOnMount ?? refetchOnMount
        refetchOnWindowFocus = other.refetchOnWindowFocus ?? refetchOnWindowFocus
        refetchOnReconnect = other.refetchOnReconnect ?? refetchOnReconnect
        retryOnMount = other.retryOnMount ?? retryOnMount
        suspense = other.suspense ?? suspense
        throwOnError = other.throwOnError ?? throwOnError
    }
}

public struct QueryClientOptions: Sendable {
    public var queries: QueryDefaultOptions

    public init(queries: QueryDefaultOptions = QueryDefaultOptions()) {
        self.queries = queries
    }
}

public struct QueryOptions<Data: Sendable, Failure: Error & Sendable>: Sendable {
    public let queryKey: QueryKey
    public var queryHash: String?
    public var query: (@Sendable (QueryFunctionContext) async -> Result<Data, Failure>)?
    public var staleTime: StaleTime?
    public var gcTime: Int?
    public var retry: RetryOption?
    public var retryDelay: RetryDelayOption?
    public var networkMode: NetworkMode?
    public var enabled: EnabledOption?
    public var refetchOnMount: RefetchOption?
    public var refetchOnWindowFocus: RefetchOption?
    public var refetchOnReconnect: RefetchOption?
    public var retryOnMount: Bool?
    public var suspense: Bool?
    public var throwOnError: Bool?

    public init(
        queryKey: QueryKey,
        queryHash: String? = nil,
        query: (@Sendable (QueryFunctionContext) async -> Result<Data, Failure>)? = nil,
        staleTime: StaleTime? = nil,
        gcTime: Int? = nil,
        retry: RetryOption? = nil,
        retryDelay: RetryDelayOption? = nil,
        networkMode: NetworkMode? = nil,
        enabled: EnabledOption? = nil,
        refetchOnMount: RefetchOption? = nil,
        refetchOnWindowFocus: RefetchOption? = nil,
        refetchOnReconnect: RefetchOption? = nil,
        retryOnMount: Bool? = nil,
        suspense: Bool? = nil,
        throwOnError: Bool? = nil
    ) {
        self.queryKey = queryKey
        self.queryHash = queryHash
        self.query = query
        self.staleTime = staleTime
        self.gcTime = gcTime
        self.retry = retry
        self.retryDelay = retryDelay
        self.networkMode = networkMode
        self.enabled = enabled
        self.refetchOnMount = refetchOnMount
        self.refetchOnWindowFocus = refetchOnWindowFocus
        self.refetchOnReconnect = refetchOnReconnect
        self.retryOnMount = retryOnMount
        self.suspense = suspense
        self.throwOnError = throwOnError
    }
}

public struct QueryFunctionContext: Sendable {
    public let queryKey: QueryKey
    public let queryHash: String
    public let cancellationToken: QueryCancellationToken

    public init(
        queryKey: QueryKey,
        queryHash: String,
        cancellationToken: QueryCancellationToken = QueryCancellationToken()
    ) {
        self.queryKey = queryKey
        self.queryHash = queryHash
        self.cancellationToken = cancellationToken
    }
}

public final class QueryCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelledStorage = false
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        let value = isCancelledStorage
        lock.unlock()
        return value
    }

    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let shouldInvokeImmediately: Bool
        lock.lock()
        if isCancelledStorage {
            shouldInvokeImmediately = true
        } else {
            shouldInvokeImmediately = false
            handlers.append(handler)
        }
        lock.unlock()

        if shouldInvokeImmediately {
            handler()
        }
    }

    func cancel() {
        let callbacks: [@Sendable () -> Void]

        lock.lock()
        guard !isCancelledStorage else {
            lock.unlock()
            return
        }
        isCancelledStorage = true
        callbacks = handlers
        handlers.removeAll(keepingCapacity: false)
        lock.unlock()

        for callback in callbacks {
            callback()
        }
    }
}

public enum QueryTypeFilter: Sendable {
    case all
    case active
    case inactive
}

public struct QueryFilters: Sendable {
    public var queryKey: QueryKey?
    public var exact: Bool
    public var type: QueryTypeFilter
    public var stale: Bool?
    public var fetchStatus: FetchStatus?

    public init(
        queryKey: QueryKey? = nil,
        exact: Bool = false,
        type: QueryTypeFilter = .all,
        stale: Bool? = nil,
        fetchStatus: FetchStatus? = nil
    ) {
        self.queryKey = queryKey
        self.exact = exact
        self.type = type
        self.stale = stale
        self.fetchStatus = fetchStatus
    }

    public static let all = QueryFilters()
}

public enum InvalidateRefetchType: Sendable {
    case none
    case active
    case inactive
    case all
}

public struct InvalidateOptions: Sendable {
    public var refetchType: InvalidateRefetchType?
    public var cancelRefetch: Bool
    public var throwOnError: Bool

    public init(
        refetchType: InvalidateRefetchType? = nil,
        cancelRefetch: Bool = true,
        throwOnError: Bool = false
    ) {
        self.refetchType = refetchType
        self.cancelRefetch = cancelRefetch
        self.throwOnError = throwOnError
    }
}

public struct RefetchOptions: Sendable {
    public var cancelRefetch: Bool
    public var throwOnError: Bool

    public init(cancelRefetch: Bool = true, throwOnError: Bool = false) {
        self.cancelRefetch = cancelRefetch
        self.throwOnError = throwOnError
    }
}
