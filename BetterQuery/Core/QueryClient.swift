import Foundation

public enum QueryClientInfrastructureError: Error, Sendable {
    case missingQueryFunction(queryHash: String)
    case typeMismatch(queryHash: String)
    case cancelled
    case queryFailure(queryHash: String)
}

private enum QueryExecutionResult: Sendable {
    case success(AnySendableValue)
    case failure(AnySendableValue)
}

private enum FetchTaskOutput: Sendable {
    case success(AnySendableValue)
    case failure(AnySendableValue)
    case cancelled
}

public actor QueryClient {
    private struct QueryDefaultsEntry: Sendable {
        let keyHash: String
        let queryKey: QueryKey
        var options: QueryDefaultOptions
    }

    private struct AnyQueryOptions: Sendable {
        var queryKey: QueryKey
        var queryHash: String
        var dataType: ObjectIdentifier
        var failureType: ObjectIdentifier
        var query: (@Sendable (QueryFunctionContext) async -> QueryExecutionResult)?
        var staleTime: StaleTime
        var gcTime: Int?
        var retry: RetryOption?
        var retryDelay: RetryDelayOption?
        var networkMode: NetworkMode?
        var enabled: EnabledOption
        var refetchOnMount: RefetchOption
        var refetchOnWindowFocus: RefetchOption
        var refetchOnReconnect: RefetchOption
        var retryOnMount: Bool
        var suspense: Bool
        var throwOnError: Bool
    }

    private struct QueryRecord: Sendable {
        var queryKey: QueryKey
        var queryHash: String
        var dataType: ObjectIdentifier
        var failureType: ObjectIdentifier
        var options: AnyQueryOptions

        var data: AnySendableValue?
        var dataUpdateCount: Int
        var dataUpdatedAt: Date?

        var error: AnySendableValue?
        var errorUpdateCount: Int
        var errorUpdatedAt: Date?

        var fetchFailureCount: Int
        var fetchFailureReason: AnySendableValue?
        var isInvalidated: Bool
        var status: QueryStatus
        var fetchStatus: FetchStatus

        var observers: Set<UUID>
        var gcTime: Int
        var gcTask: Task<Void, Never>?
        var fetchTask: Task<FetchTaskOutput, Never>?
    }

    private struct ObserverRecord: Sendable {
        let id: UUID
        let queryHash: String
        let options: AnyQueryOptions
        let emit: @Sendable (AnyQueryState) -> Void
    }

    private let defaultGcTimeMs = 5 * 60 * 1000

    private var defaultOptions: QueryDefaultOptions
    private var queryDefaults: [QueryDefaultsEntry] = []
    private var queries: [String: QueryRecord] = [:]
    private var observers: [UUID: ObserverRecord] = [:]

    private var isOnline = true
    private var isFocused = true
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(options: QueryClientOptions = QueryClientOptions()) {
        self.defaultOptions = options.queries
    }

    public func getDefaultOptions() -> QueryClientOptions {
        QueryClientOptions(queries: defaultOptions)
    }

    public func setDefaultOptions(_ options: QueryClientOptions) {
        defaultOptions = options.queries
    }

    public func setQueryDefaults(queryKey: QueryKey, options: QueryDefaultOptions) {
        let keyHash = hashKey(queryKey)
        if let index = queryDefaults.firstIndex(where: { $0.keyHash == keyHash }) {
            queryDefaults[index] = QueryDefaultsEntry(keyHash: keyHash, queryKey: queryKey, options: options)
        } else {
            queryDefaults.append(QueryDefaultsEntry(keyHash: keyHash, queryKey: queryKey, options: options))
        }
    }

    public func getQueryDefaults(queryKey: QueryKey) -> QueryDefaultOptions {
        var result = QueryDefaultOptions()
        for entry in queryDefaults where partialMatchKey(queryKey, entry.queryKey) {
            result.merge(entry.options)
        }
        return result
    }

    public func setOnline(_ online: Bool) {
        let changed = isOnline != online
        isOnline = online
        guard changed else { return }

        if online {
            signalResumeWaiters()
            onOnline()
        }
    }

    public func setFocused(_ focused: Bool) {
        let changed = isFocused != focused
        isFocused = focused
        guard changed else { return }

        if focused {
            signalResumeWaiters()
            onFocus()
        }
    }

    public func isFetching(_ filters: QueryFilters = .all) -> Int {
        matchingQueryHashes(filters: QueryFilters(
            queryKey: filters.queryKey,
            exact: filters.exact,
            type: filters.type,
            stale: filters.stale,
            fetchStatus: .fetching
        )).count
    }

    public func fetch<Data: Sendable, Failure: Error & Sendable>(
        _ options: QueryOptions<Data, Failure>
    ) async -> Result<Data, Failure> {
        var defaultedOptions = defaultQueryOptions(options)
        if defaultedOptions.retry == nil {
            defaultedOptions.retry = .disabled
        }

        let query = ensureQuery(defaultedOptions)
        if !isStaleByTime(record: query, staleTime: defaultedOptions.staleTime),
           let cached: Data = query.data?.decode(Data.self) {
            return .success(cached)
        }

        let output = await fetchOutput(queryHash: defaultedOptions.queryHash, options: defaultedOptions, cancelRefetch: true)
        return decodeOutput(output, asData: Data.self, asFailure: Failure.self, queryHash: defaultedOptions.queryHash)
    }

    public func prefetch<Data: Sendable, Failure: Error & Sendable>(_ options: QueryOptions<Data, Failure>) async {
        _ = await fetch(options)
    }

    public func refetch<Data: Sendable, Failure: Error & Sendable>(
        _ options: QueryOptions<Data, Failure>,
        cancelRefetch: Bool = true
    ) async -> Result<Data, Failure> {
        let defaultedOptions = defaultQueryOptions(options)
        let output = await fetchOutput(queryHash: defaultedOptions.queryHash, options: defaultedOptions, cancelRefetch: cancelRefetch)
        return decodeOutput(output, asData: Data.self, asFailure: Failure.self, queryHash: defaultedOptions.queryHash)
    }

    public func getQueryData<Data>(queryKey: QueryKey, as: Data.Type = Data.self) -> Data? {
        let queryHash = hashKey(queryKey)
        return queries[queryHash]?.data?.decode(Data.self)
    }

    @discardableResult
    public func setQueryData<Data: Sendable>(queryKey: QueryKey, data: Data?) -> Data? {
        guard let data else {
            return nil
        }

        let queryHash = hashKey(queryKey)
        let existingDataType = queries[queryHash]?.dataType
        if let existingDataType {
            precondition(
                existingDataType == ObjectIdentifier(Data.self),
                "Query key \(queryHash) already exists with a different Data type"
            )
        }

        var defaultedOptions = defaultQueryOptions(QueryOptions<Data, QueryClientInfrastructureError>(queryKey: queryKey))
        if let existing = queries[queryHash]?.options.query {
            defaultedOptions.query = existing
        }

        var record = ensureQuery(defaultedOptions)
        record.data = AnySendableValue(data)
        record.dataUpdateCount += 1
        record.dataUpdatedAt = Date()
        record.error = nil
        record.errorUpdatedAt = nil
        record.fetchFailureCount = 0
        record.fetchFailureReason = nil
        record.isInvalidated = false
        record.status = .success
        record.fetchStatus = .idle
        queries[queryHash] = record
        notifyObservers(for: queryHash)
        scheduleGc(for: queryHash)
        return data
    }

    @discardableResult
    public func setQueryData<Data: Sendable>(
        queryKey: QueryKey,
        updater: @Sendable (Data?) -> Data?
    ) -> Data? {
        let current: Data? = getQueryData(queryKey: queryKey)
        guard let next = updater(current) else {
            return nil
        }
        return setQueryData(queryKey: queryKey, data: next)
    }

    public func invalidateQueries(
        filters: QueryFilters = .all,
        options: InvalidateOptions = InvalidateOptions()
    ) async throws {
        let hashes = matchingQueryHashes(filters: filters)
        for hash in hashes {
            guard var record = queries[hash] else { continue }
            if !record.isInvalidated {
                record.isInvalidated = true
                queries[hash] = record
                notifyObservers(for: hash)
            }
        }

        let refetchType = options.refetchType ?? .active
        guard refetchType != .none else {
            return
        }

        var refetchFilters = filters
        switch refetchType {
        case .none:
            break
        case .active:
            refetchFilters.type = .active
        case .inactive:
            refetchFilters.type = .inactive
        case .all:
            refetchFilters.type = .all
        }

        try await refetchQueries(
            filters: refetchFilters,
            options: RefetchOptions(cancelRefetch: options.cancelRefetch, throwOnError: options.throwOnError)
        )
    }

    public func refetchQueries(
        filters: QueryFilters = .all,
        options: RefetchOptions = RefetchOptions()
    ) async throws {
        let hashes = matchingQueryHashes(filters: filters)
        for hash in hashes {
            guard var record = queries[hash] else { continue }
            if isDisabled(record) || isStatic(record) {
                continue
            }

            if record.options.query == nil {
                for observerID in record.observers {
                    if let observerQuery = observers[observerID]?.options.query {
                        record.options.query = observerQuery
                        break
                    }
                }
                queries[hash] = record
            }

            let output = await fetchOutput(
                queryHash: hash,
                options: record.options,
                cancelRefetch: options.cancelRefetch
            )
            if options.throwOnError {
                if case .failure = output {
                    throw QueryClientInfrastructureError.queryFailure(queryHash: hash)
                }
            }
        }
    }

    public func observe<Data: Sendable, Failure: Error & Sendable>(
        _ options: QueryOptions<Data, Failure>
    ) -> AsyncStream<QueryState<Data, Failure>> {
        let defaulted = defaultQueryOptions(options)
        let observerID = UUID()

        return AsyncStream { continuation in
            let emit: @Sendable (AnyQueryState) -> Void = { anyState in
                continuation.yield(Self.castState(anyState, asData: Data.self, asFailure: Failure.self, queryHash: defaulted.queryHash))
            }

            Task {
                self.addObserver(id: observerID, options: defaulted, emit: emit)
            }

            continuation.onTermination = { _ in
                Task {
                    await self.removeObserver(id: observerID)
                }
            }
        }
    }

    public func getQueryState<Data: Sendable, Failure: Error & Sendable>(
        _ options: QueryOptions<Data, Failure>
    ) -> QueryState<Data, Failure> {
        let defaulted = defaultQueryOptions(options)
        let record = ensureQuery(defaulted)
        let anyState = makeAnyState(record: record, options: defaulted)
        return Self.castState(anyState, asData: Data.self, asFailure: Failure.self, queryHash: defaulted.queryHash)
    }

    private func decodeOutput<Data: Sendable, Failure: Error & Sendable>(
        _ output: FetchTaskOutput,
        asData: Data.Type,
        asFailure: Failure.Type,
        queryHash: String
    ) -> Result<Data, Failure> {
        switch output {
        case let .success(value):
            guard let typed = value.decode(Data.self) else {
                preconditionFailure("Query data type mismatch for hash \(queryHash)")
            }
            return .success(typed)
        case let .failure(value):
            guard let typed = value.decode(Failure.self) else {
                preconditionFailure("Query failure type mismatch for hash \(queryHash)")
            }
            return .failure(typed)
        case .cancelled:
            preconditionFailure("Fetch for query \(queryHash) was cancelled without cached data")
        }
    }

    private static func castState<Data: Sendable, Failure: Error & Sendable>(
        _ anyState: AnyQueryState,
        asData: Data.Type,
        asFailure: Failure.Type,
        queryHash: String
    ) -> QueryState<Data, Failure> {
        let typedError: Failure?
        if let error = anyState.error {
            guard let cast = error.decode(Failure.self) else {
                preconditionFailure("Query failure type mismatch for hash \(queryHash)")
            }
            typedError = cast
        } else {
            typedError = nil
        }

        let typedFailureReason: Failure?
        if let reason = anyState.failureReason {
            guard let cast = reason.decode(Failure.self) else {
                preconditionFailure("Query failure type mismatch for hash \(queryHash)")
            }
            typedFailureReason = cast
        } else {
            typedFailureReason = nil
        }

        return QueryState<Data, Failure>(
            status: anyState.status,
            fetchStatus: anyState.fetchStatus,
            data: anyState.data?.decode(Data.self),
            dataUpdatedAt: anyState.dataUpdatedAt,
            error: typedError,
            errorUpdatedAt: anyState.errorUpdatedAt,
            failureCount: anyState.failureCount,
            failureReason: typedFailureReason,
            isPending: anyState.isPending,
            isSuccess: anyState.isSuccess,
            isError: anyState.isError,
            isInitialLoading: anyState.isInitialLoading,
            isLoading: anyState.isLoading,
            isFetching: anyState.isFetching,
            isRefetching: anyState.isRefetching,
            isLoadingError: anyState.isLoadingError,
            isRefetchError: anyState.isRefetchError,
            isPaused: anyState.isPaused,
            isStale: anyState.isStale,
            isEnabled: anyState.isEnabled
        )
    }

    private func addObserver(id: UUID, options: AnyQueryOptions, emit: @escaping @Sendable (AnyQueryState) -> Void) {
        var record = ensureQuery(options)
        record.observers.insert(id)
        record.gcTask?.cancel()
        record.gcTask = nil
        queries[record.queryHash] = record

        observers[id] = ObserverRecord(id: id, queryHash: record.queryHash, options: options, emit: emit)
        emit(makeAnyState(record: record, options: options))

        if shouldFetchOnMount(record: record, options: options) {
            Task {
                _ = await self.fetchOutput(queryHash: record.queryHash, options: options, cancelRefetch: true)
            }
        }
    }

    private func removeObserver(id: UUID) {
        guard let observer = observers.removeValue(forKey: id) else {
            return
        }

        guard var record = queries[observer.queryHash] else {
            return
        }

        record.observers.remove(id)
        queries[observer.queryHash] = record
        if record.observers.isEmpty {
            scheduleGc(for: observer.queryHash)
        }
    }

    private func defaultQueryOptions<Data: Sendable, Failure: Error & Sendable>(
        _ options: QueryOptions<Data, Failure>
    ) -> AnyQueryOptions {
        var mergedDefaults = defaultOptions
        mergedDefaults.merge(getQueryDefaults(queryKey: options.queryKey))

        var callsiteDefaults = QueryDefaultOptions()
        callsiteDefaults.staleTime = options.staleTime
        callsiteDefaults.gcTime = options.gcTime
        callsiteDefaults.retry = options.retry
        callsiteDefaults.retryDelay = options.retryDelay
        callsiteDefaults.networkMode = options.networkMode
        callsiteDefaults.enabled = options.enabled
        callsiteDefaults.refetchOnMount = options.refetchOnMount
        callsiteDefaults.refetchOnWindowFocus = options.refetchOnWindowFocus
        callsiteDefaults.refetchOnReconnect = options.refetchOnReconnect
        callsiteDefaults.retryOnMount = options.retryOnMount
        callsiteDefaults.suspense = options.suspense
        callsiteDefaults.throwOnError = options.throwOnError
        mergedDefaults.merge(callsiteDefaults)

        let suspense = mergedDefaults.suspense ?? false
        let throwOnError = mergedDefaults.throwOnError ?? suspense
        let networkMode = mergedDefaults.networkMode
        let refetchOnReconnect = mergedDefaults.refetchOnReconnect ?? (networkMode == .always ? .never : .stale)

        let wrappedQuery: (@Sendable (QueryFunctionContext) async -> QueryExecutionResult)?
        if let query = options.query {
            wrappedQuery = { context in
                let result = await query(context)
                switch result {
                case let .success(value):
                    return .success(AnySendableValue(value))
                case let .failure(error):
                    return .failure(AnySendableValue(error))
                }
            }
        } else {
            wrappedQuery = nil
        }

        return AnyQueryOptions(
            queryKey: options.queryKey,
            queryHash: options.queryHash ?? hashKey(options.queryKey),
            dataType: ObjectIdentifier(Data.self),
            failureType: ObjectIdentifier(Failure.self),
            query: wrappedQuery,
            staleTime: mergedDefaults.staleTime ?? .milliseconds(0),
            gcTime: mergedDefaults.gcTime,
            retry: mergedDefaults.retry,
            retryDelay: mergedDefaults.retryDelay,
            networkMode: networkMode,
            enabled: mergedDefaults.enabled ?? .value(true),
            refetchOnMount: mergedDefaults.refetchOnMount ?? .stale,
            refetchOnWindowFocus: mergedDefaults.refetchOnWindowFocus ?? .stale,
            refetchOnReconnect: refetchOnReconnect,
            retryOnMount: mergedDefaults.retryOnMount ?? true,
            suspense: suspense,
            throwOnError: throwOnError
        )
    }

    private func ensureQuery(_ options: AnyQueryOptions) -> QueryRecord {
        let hash = options.queryHash
        if var existing = queries[hash] {
            precondition(existing.dataType == options.dataType, "Query hash \(hash) is already bound to a different Data type")
            precondition(existing.failureType == options.failureType, "Query hash \(hash) is already bound to a different Failure type")
            existing.options = mergeQueryOptions(existing.options, options)
            existing.gcTime = max(existing.gcTime, options.gcTime ?? defaultGcTimeMs)
            queries[hash] = existing
            return existing
        }

        let record = QueryRecord(
            queryKey: options.queryKey,
            queryHash: hash,
            dataType: options.dataType,
            failureType: options.failureType,
            options: options,
            data: nil,
            dataUpdateCount: 0,
            dataUpdatedAt: nil,
            error: nil,
            errorUpdateCount: 0,
            errorUpdatedAt: nil,
            fetchFailureCount: 0,
            fetchFailureReason: nil,
            isInvalidated: false,
            status: .pending,
            fetchStatus: .idle,
            observers: [],
            gcTime: options.gcTime ?? defaultGcTimeMs,
            gcTask: nil,
            fetchTask: nil
        )
        queries[hash] = record
        scheduleGc(for: hash)
        return record
    }

    private func mergeQueryOptions(_ old: AnyQueryOptions, _ new: AnyQueryOptions) -> AnyQueryOptions {
        AnyQueryOptions(
            queryKey: new.queryKey,
            queryHash: new.queryHash,
            dataType: new.dataType,
            failureType: new.failureType,
            query: new.query ?? old.query,
            staleTime: new.staleTime,
            gcTime: new.gcTime ?? old.gcTime,
            retry: new.retry ?? old.retry,
            retryDelay: new.retryDelay ?? old.retryDelay,
            networkMode: new.networkMode ?? old.networkMode,
            enabled: new.enabled,
            refetchOnMount: new.refetchOnMount,
            refetchOnWindowFocus: new.refetchOnWindowFocus,
            refetchOnReconnect: new.refetchOnReconnect,
            retryOnMount: new.retryOnMount,
            suspense: new.suspense,
            throwOnError: new.throwOnError
        )
    }

    private func fetchOutput(
        queryHash: String,
        options: AnyQueryOptions,
        cancelRefetch: Bool
    ) async -> FetchTaskOutput {
        var record = ensureQuery(options)
        record.options = mergeQueryOptions(record.options, options)

        if record.fetchStatus != .idle, let inFlight = record.fetchTask {
            if record.data != nil, cancelRefetch {
                inFlight.cancel()
                record.fetchTask = nil
                queries[queryHash] = record
            } else {
                queries[queryHash] = record
                return await inFlight.value
            }
        }

        if record.options.query == nil {
            for observerID in record.observers {
                if let observerQuery = observers[observerID]?.options.query {
                    record.options.query = observerQuery
                    break
                }
            }
        }
        queries[queryHash] = record

        guard let query = record.options.query else {
            preconditionFailure("Missing query function for hash \(queryHash)")
        }

        record.fetchFailureCount = 0
        record.fetchFailureReason = nil
        record.fetchStatus = canFetch(record.options.networkMode) ? .fetching : .paused
        if record.data == nil {
            record.error = nil
            record.status = .pending
        }
        queries[queryHash] = record
        notifyObservers(for: queryHash)

        let task = Task<FetchTaskOutput, Never> {
            let cancellationToken = QueryCancellationToken()
            let context = QueryFunctionContext(
                queryKey: options.queryKey,
                queryHash: options.queryHash,
                cancellationToken: cancellationToken
            )
            var failureCount = 0

            while true {
                if Task.isCancelled {
                    cancellationToken.cancel()
                    return .cancelled
                }

                if !self.canFetch(options.networkMode) {
                    self.setFetchStatus(.paused, for: queryHash)
                    await self.waitUntilCanFetch(options.networkMode)
                    self.setFetchStatus(.fetching, for: queryHash)
                }

                let result = await withTaskCancellationHandler {
                    await query(context)
                } onCancel: {
                    cancellationToken.cancel()
                }

                switch result {
                case let .success(value):
                    return .success(value)
                case let .failure(errorValue):
                    let error = self.errorForRetry(errorValue)
                    let retry = options.retry ?? .maxAttempts(3)
                    let retryDelay = options.retryDelay ?? .resolver { attempt, _ in
                        min(1000 * Int(pow(2, Double(attempt))), 30000)
                    }
                    let delayMs = self.resolveDelay(retryDelay, failureCount: failureCount, error: error)
                    let shouldRetry = retry.shouldRetry(failureCount: failureCount, error: error)
                    if !shouldRetry {
                        return .failure(errorValue)
                    }

                    failureCount += 1
                    self.setFetchFailure(count: failureCount, error: errorValue, for: queryHash)

                    if delayMs > 0 {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                        } catch {
                            cancellationToken.cancel()
                            return .cancelled
                        }
                    }
                    if Task.isCancelled {
                        cancellationToken.cancel()
                        return .cancelled
                    }

                    if !self.canContinue(options.networkMode) {
                        self.setFetchStatus(.paused, for: queryHash)
                        await self.waitUntilCanContinue(options.networkMode)
                        self.setFetchStatus(.fetching, for: queryHash)
                    }
                }
            }
        }

        record = queries[queryHash] ?? record
        record.fetchTask = task
        queries[queryHash] = record

        let output = await task.value
        switch output {
        case let .success(value):
            var latest = queries[queryHash] ?? record
            latest.fetchTask = nil
            latest.data = value
            latest.dataUpdateCount += 1
            latest.dataUpdatedAt = Date()
            latest.error = nil
            latest.errorUpdatedAt = nil
            latest.fetchFailureCount = 0
            latest.fetchFailureReason = nil
            latest.isInvalidated = false
            latest.status = .success
            latest.fetchStatus = .idle
            queries[queryHash] = latest
            notifyObservers(for: queryHash)
            scheduleGc(for: queryHash)
            return .success(value)
        case let .failure(errorValue):
            var latest = queries[queryHash] ?? record
            latest.fetchTask = nil
            latest.fetchStatus = .idle
            latest.error = errorValue
            latest.errorUpdateCount += 1
            latest.errorUpdatedAt = Date()
            latest.fetchFailureCount += 1
            latest.fetchFailureReason = errorValue
            latest.status = .error
            latest.isInvalidated = true
            queries[queryHash] = latest
            notifyObservers(for: queryHash)
            scheduleGc(for: queryHash)
            return .failure(errorValue)
        case .cancelled:
            var latest = queries[queryHash] ?? record
            latest.fetchTask = nil
            latest.fetchStatus = .idle
            queries[queryHash] = latest
            notifyObservers(for: queryHash)
            if let data = latest.data {
                return .success(data)
            }
            return .cancelled
        }
    }

    private func errorForRetry(_ value: AnySendableValue) -> any Error {
        if let error = value.rawValue as? any Error {
            return error
        }
        return QueryClientInfrastructureError.queryFailure(queryHash: "unknown")
    }

    private func matchingQueryHashes(filters: QueryFilters) -> [String] {
        queries.values.filter { matchQuery(filters: filters, record: $0) }.map(\.queryHash)
    }

    private func matchQuery(filters: QueryFilters, record: QueryRecord) -> Bool {
        if let queryKey = filters.queryKey {
            if filters.exact {
                if hashKey(queryKey) != record.queryHash {
                    return false
                }
            } else if !partialMatchKey(record.queryKey, queryKey) {
                return false
            }
        }

        switch filters.type {
        case .all:
            break
        case .active:
            if !isActive(record) {
                return false
            }
        case .inactive:
            if isActive(record) {
                return false
            }
        }

        if let stale = filters.stale, isStale(record: record) != stale {
            return false
        }

        if let fetchStatus = filters.fetchStatus, record.fetchStatus != fetchStatus {
            return false
        }

        return true
    }

    private func isActive(_ record: QueryRecord) -> Bool {
        guard !record.observers.isEmpty else {
            return false
        }

        for observerID in record.observers {
            guard let observer = observers[observerID] else { continue }
            let summary = stateSummary(for: record)
            if observer.options.enabled.resolve(summary) {
                return true
            }
        }
        return false
    }

    private func isDisabled(_ record: QueryRecord) -> Bool {
        if !record.observers.isEmpty {
            return !isActive(record)
        }

        return record.options.query == nil || (record.dataUpdateCount + record.errorUpdateCount == 0)
    }

    private func isStatic(_ record: QueryRecord) -> Bool {
        if record.observers.isEmpty {
            return false
        }

        for observerID in record.observers {
            guard let observer = observers[observerID] else { continue }
            if observer.options.staleTime == .static {
                return true
            }
        }
        return false
    }

    private func isStale(record: QueryRecord) -> Bool {
        if !record.observers.isEmpty {
            for observerID in record.observers {
                guard let observer = observers[observerID] else { continue }
                let enabled = observer.options.enabled.resolve(stateSummary(for: record))
                if enabled && isStaleByTime(record: record, staleTime: observer.options.staleTime) {
                    return true
                }
            }
            return false
        }

        return record.data == nil || record.isInvalidated
    }

    private func isStaleByTime(record: QueryRecord, staleTime: StaleTime) -> Bool {
        if record.data == nil {
            return true
        }
        if staleTime == .static {
            return false
        }
        if record.isInvalidated {
            return true
        }

        switch staleTime {
        case .milliseconds(let value):
            guard let updatedAt = record.dataUpdatedAt else {
                return true
            }
            return Date().timeIntervalSince(updatedAt) * 1000 >= Double(value)
        case .infinity:
            return false
        case .static:
            return false
        }
    }

    private func shouldFetchOnMount(record: QueryRecord, options: AnyQueryOptions) -> Bool {
        let enabled = options.enabled.resolve(stateSummary(for: record))
        if !enabled {
            return false
        }

        let shouldLoad = record.data == nil && !(record.status == .error && !options.retryOnMount)
        if shouldLoad {
            return true
        }

        if record.data != nil {
            return shouldFetchOn(record: record, options: options, refetch: options.refetchOnMount)
        }

        return false
    }

    private func shouldFetchOn(record: QueryRecord, options: AnyQueryOptions, refetch: RefetchOption) -> Bool {
        let enabled = options.enabled.resolve(stateSummary(for: record))
        if !enabled || options.staleTime == .static {
            return false
        }

        switch refetch {
        case .always:
            return true
        case .never:
            return false
        case .stale:
            return isStaleByTime(record: record, staleTime: options.staleTime)
        }
    }

    private func makeAnyState(record: QueryRecord, options: AnyQueryOptions) -> AnyQueryState {
        let isFetching = record.fetchStatus == .fetching
        let isPending = record.status == .pending
        let isError = record.status == .error
        let hasData = record.data != nil
        let isEnabled = options.enabled.resolve(stateSummary(for: record))
        let stale = isEnabled && isStaleByTime(record: record, staleTime: options.staleTime)

        return AnyQueryState(
            status: record.status,
            fetchStatus: record.fetchStatus,
            data: record.data,
            dataUpdatedAt: record.dataUpdatedAt,
            error: record.error,
            errorUpdatedAt: record.errorUpdatedAt,
            failureCount: record.fetchFailureCount,
            failureReason: record.fetchFailureReason,
            isPending: isPending,
            isSuccess: record.status == .success,
            isError: isError,
            isInitialLoading: isPending && isFetching,
            isLoading: isPending && isFetching,
            isFetching: isFetching,
            isRefetching: isFetching && !isPending,
            isLoadingError: isError && !hasData,
            isRefetchError: isError && hasData,
            isPaused: record.fetchStatus == .paused,
            isStale: stale,
            isEnabled: isEnabled
        )
    }

    private func notifyObservers(for queryHash: String) {
        guard let record = queries[queryHash] else {
            return
        }

        for observerID in record.observers {
            guard let observer = observers[observerID] else { continue }
            observer.emit(makeAnyState(record: record, options: observer.options))
        }
    }

    private func scheduleGc(for queryHash: String) {
        guard var record = queries[queryHash] else {
            return
        }

        record.gcTask?.cancel()
        record.gcTask = nil

        guard record.observers.isEmpty, record.fetchStatus == .idle else {
            queries[queryHash] = record
            return
        }

        let gcTime = record.gcTime
        if gcTime < 0 || gcTime == .max {
            queries[queryHash] = record
            return
        }

        record.gcTask = Task {
            if gcTime > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(gcTime) * 1_000_000)
                } catch {
                    return
                }
            }
            if Task.isCancelled {
                return
            }
            self.optionalRemove(queryHash: queryHash)
        }
        queries[queryHash] = record
    }

    private func optionalRemove(queryHash: String) {
        guard let record = queries[queryHash] else {
            return
        }

        if record.observers.isEmpty && record.fetchStatus == .idle {
            queries[queryHash] = nil
        }
    }

    private func onFocus() {
        for record in queries.values {
            guard let observer = record.observers.compactMap({ observers[$0] }).first(where: {
                shouldFetchOn(record: record, options: $0.options, refetch: $0.options.refetchOnWindowFocus)
            }) else {
                continue
            }

            Task {
                _ = await self.fetchOutput(queryHash: record.queryHash, options: observer.options, cancelRefetch: false)
            }
        }
    }

    private func onOnline() {
        for record in queries.values {
            guard let observer = record.observers.compactMap({ observers[$0] }).first(where: {
                shouldFetchOn(record: record, options: $0.options, refetch: $0.options.refetchOnReconnect)
            }) else {
                continue
            }

            Task {
                _ = await self.fetchOutput(queryHash: record.queryHash, options: observer.options, cancelRefetch: false)
            }
        }
    }

    private func stateSummary(for record: QueryRecord) -> QueryStateSummary {
        QueryStateSummary(
            queryKey: record.queryKey,
            queryHash: record.queryHash,
            status: record.status,
            fetchStatus: record.fetchStatus,
            hasData: record.data != nil,
            isInvalidated: record.isInvalidated
        )
    }

    private func setFetchStatus(_ status: FetchStatus, for queryHash: String) {
        guard var record = queries[queryHash] else { return }
        record.fetchStatus = status
        queries[queryHash] = record
        notifyObservers(for: queryHash)
    }

    private func setFetchFailure(count: Int, error: AnySendableValue, for queryHash: String) {
        guard var record = queries[queryHash] else { return }
        record.fetchFailureCount = count
        record.fetchFailureReason = error
        queries[queryHash] = record
        notifyObservers(for: queryHash)
    }

    private func resolveDelay(_ option: RetryDelayOption, failureCount: Int, error: any Error) -> Int {
        switch option {
        case .milliseconds(let value):
            return value
        case .resolver(let resolver):
            return resolver(failureCount, error)
        }
    }

    private func canFetch(_ networkMode: NetworkMode?) -> Bool {
        let mode = networkMode ?? .online
        if mode == .online {
            return isOnline
        }
        return true
    }

    private func canContinue(_ networkMode: NetworkMode?) -> Bool {
        let mode = networkMode ?? .online
        return isFocused && (mode == .always || isOnline)
    }

    private func waitUntilCanFetch(_ networkMode: NetworkMode?) async {
        while !canFetch(networkMode) {
            await waitForResumeSignal()
        }
    }

    private func waitUntilCanContinue(_ networkMode: NetworkMode?) async {
        while !canContinue(networkMode) {
            await waitForResumeSignal()
        }
    }

    private func waitForResumeSignal() async {
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    private func signalResumeWaiters() {
        let waiters = resumeWaiters
        resumeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
