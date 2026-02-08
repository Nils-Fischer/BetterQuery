//
//  BetterQueryTests.swift
//  BetterQueryTests
//
//  Created by Nils Fischer on 07.02.26.
//

import Foundation
import Testing
@testable import BetterQuery
#if canImport(SwiftUI)
import SwiftUI
#endif

struct BetterQueryTests {
    actor Counter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    actor Flag {
        private(set) var value = false

        func set(_ value: Bool) {
            self.value = value
        }
    }

    final class IntRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func append(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [Int] {
            lock.lock()
            let copy = values
            lock.unlock()
            return copy
        }
    }

    final class BoolLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var valueStorage = false

        func set() {
            lock.lock()
            valueStorage = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            let value = valueStorage
            lock.unlock()
            return value
        }
    }

    private func waitUntil(
        timeoutMs: Int = 1500,
        pollMs: Int = 10,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
        }
        return false
    }

    private func waitUntilMainActor(
        timeoutMs: Int = 1500,
        pollMs: Int = 10,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
            let matched = await MainActor.run {
                condition()
            }
            if matched {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
        }
        return false
    }

    @Test func fetchQueryReadsFromCacheWhenFresh() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("cache"), .string("hit")]

        let options = QueryOptions<String>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return "data"
            },
            staleTime: .infinity
        )

        let first = try await client.fetchQuery(options)
        let second = try await client.fetchQuery(options)

        #expect(first == "data")
        #expect(second == "data")
        #expect(await counter.value == 1)
    }

    @Test func invalidateQueriesRefetchesActiveByDefault() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("invalidate"), .int(1)]

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return await counter.value
            },
            staleTime: .infinity
        )

        _ = try await client.fetchQuery(options)
        let stream = await client.observeQuery(options)
        let subscription = Task {
            for await _ in stream {}
        }

        try await client.invalidateQueries(filters: QueryFilters(queryKey: key))
        let done = await waitUntil {
            await counter.value == 2
        }

        subscription.cancel()
        #expect(done)
    }

    @Test func enabledFalsePreventsAutoFetchButRefetchStillWorks() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("enabled"), .bool(false)]

        let options = QueryOptions<String>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return "value"
            },
            enabled: .value(false)
        )

        let stream = await client.observeQuery(options)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        #expect(first?.status == .pending)
        #expect(first?.fetchStatus == .idle)
        #expect(await counter.value == 0)

        _ = try await client.refetchQuery(options)
        #expect(await counter.value == 1)
    }

    @Test func statusAndFetchStatusSplitMatchesPendingLoadingAndRefetching() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("status"), .string("split")]

        let options = QueryOptions<String>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                try await Task.sleep(nanoseconds: 20_000_000)
                return "ok"
            }
        )

        let stream = await client.observeQuery(options)
        var iterator = stream.makeAsyncIterator()

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()

        #expect(first?.status == .pending)
        #expect(first?.fetchStatus == .idle)
        #expect(second?.status == .pending)
        #expect(second?.fetchStatus == .fetching)
        #expect(second?.isLoading == true)
        #expect(third?.status == .success)
        #expect(third?.fetchStatus == .idle)
        #expect(third?.isRefetching == false)
    }

    @Test func combineReturnsAggregatedMultiQueryResult() async throws {
        let client = QueryClient()

        let firstKey: QueryKey = [.string("combine"), .int(1)]
        let secondKey: QueryKey = [.string("combine"), .int(2)]

        let first = QueryOptions<Int>(queryKey: firstKey, queryFn: { _ in 1 })
        let second = QueryOptions<Int>(queryKey: secondKey, queryFn: { _ in 2 })

        let stream = await client.observeQueries([first, second]) { results in
            results.compactMap(\.data).reduce(0, +)
        }

        var iterator = stream.makeAsyncIterator()
        var aggregated: Int?
        for _ in 0..<6 {
            if let value = await iterator.next() {
                aggregated = value
                if value == 3 {
                    break
                }
            }
        }
        #expect(aggregated == 3)
    }

    @Test func fetchQueryDoesNotRetryByDefault() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("retry"), .string("default")]

        let options = QueryOptions<String>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                struct SampleError: Error {}
                throw SampleError()
            }
        )

        do {
            _ = try await client.fetchQuery(options)
            Issue.record("Expected fetchQuery to throw")
        } catch {}

        #expect(await counter.value == 1)
    }

    @Test func observeQueryRetriesThreeTimesByDefault() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("retry"), .string("observer-default")]

        struct SampleError: Error {}

        let options = QueryOptions<String>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                let value = await counter.value
                if value < 4 {
                    throw SampleError()
                }
                return "ok"
            },
            retryDelay: .milliseconds(1)
        )

        let stream = await client.observeQuery(options)
        let subscription = Task {
            for await _ in stream {}
        }

        let succeeded = await waitUntil(timeoutMs: 1200) {
            let value: String? = await client.getQueryData(queryKey: key)
            return value == "ok"
        }

        subscription.cancel()
        #expect(succeeded)
        #expect(await counter.value == 4)
    }

    @Test func refetchQueriesWithStaleFilterTargetsOnlyStaleActiveQueries() async throws {
        let client = QueryClient()

        let staleCounter = Counter()
        let freshCounter = Counter()

        let staleKey: QueryKey = [.string("stale-filter"), .string("stale")]
        let freshKey: QueryKey = [.string("stale-filter"), .string("fresh")]

        let staleOptions = QueryOptions<Int>(
            queryKey: staleKey,
            queryFn: { _ in
                await staleCounter.increment()
                return await staleCounter.value
            },
            staleTime: .milliseconds(0)
        )

        let freshOptions = QueryOptions<Int>(
            queryKey: freshKey,
            queryFn: { _ in
                await freshCounter.increment()
                return await freshCounter.value
            },
            staleTime: .infinity
        )

        let staleStream = await client.observeQuery(staleOptions)
        let freshStream = await client.observeQuery(freshOptions)
        let staleSubscription = Task {
            for await _ in staleStream {}
        }
        let freshSubscription = Task {
            for await _ in freshStream {}
        }

        let primed = await waitUntil {
            let staleValue = await staleCounter.value
            let freshValue = await freshCounter.value
            return staleValue == 1 && freshValue == 1
        }
        #expect(primed)

        try await client.refetchQueries(
            filters: QueryFilters(type: .active, stale: true),
            options: RefetchOptions(cancelRefetch: true, throwOnError: true)
        )

        let staleRefetched = await waitUntil {
            let staleValue = await staleCounter.value
            let freshValue = await freshCounter.value
            return staleValue == 2 && freshValue == 1
        }

        staleSubscription.cancel()
        freshSubscription.cancel()
        #expect(staleRefetched)
    }

    @Test func inactiveQueriesAreOnlyStaleWhenInvalidated() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("stale-filter"), .string("inactive-rule")]

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return await counter.value
            },
            staleTime: .milliseconds(0)
        )

        _ = try await client.fetchQuery(options)
        #expect(await counter.value == 1)

        try await client.refetchQueries(
            filters: QueryFilters(type: .inactive, stale: true),
            options: RefetchOptions(cancelRefetch: true, throwOnError: true)
        )
        #expect(await counter.value == 1)

        try await client.invalidateQueries(
            filters: QueryFilters(queryKey: key),
            options: InvalidateOptions(refetchType: InvalidateRefetchType.none)
        )

        let invalidatedSnapshot = await client.getQueryResult(
            QueryOptions<Int>(
                queryKey: key,
                staleTime: .infinity
            )
        )
        #expect(invalidatedSnapshot.isStale)

        try await client.refetchQueries(
            filters: QueryFilters(type: .inactive, stale: true),
            options: RefetchOptions(cancelRefetch: true, throwOnError: true)
        )
        let invalidatedRefetched = await waitUntil {
            await counter.value == 2
        }
        #expect(invalidatedRefetched)

        if !invalidatedRefetched {
            let fallback = try? await client.refetchQuery(options)
            #expect(fallback == 2)
        }
    }

    @Test func refetchQueriesCanRefetchInactiveQueriesWithoutStaleFilter() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("refetch"), .string("inactive-all")]

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return await counter.value
            }
        )

        _ = try await client.fetchQuery(options)
        #expect(await counter.value == 1)

        try await client.refetchQueries(
            filters: QueryFilters(type: .inactive),
            options: RefetchOptions(cancelRefetch: true, throwOnError: true)
        )

        #expect(await counter.value == 2)
    }

    @Test func refetchQueryWithoutQueryFnUsesCachedQueryFunction() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("queryfn"), .string("retained")]

        let seeded = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return await counter.value
            }
        )

        _ = try await client.fetchQuery(seeded)
        #expect(await counter.value == 1)

        let refetched = try await client.refetchQuery(QueryOptions<Int>(queryKey: key))
        #expect(refetched == 2)
    }

    @Test func refetchQueryWithoutQueryFnWorksAfterInvalidationAndSnapshotRead() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("queryfn"), .string("after-invalidate")]

        let seeded = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return await counter.value
            },
            staleTime: .milliseconds(0)
        )

        _ = try await client.fetchQuery(seeded)
        try await client.invalidateQueries(
            filters: QueryFilters(queryKey: key),
            options: InvalidateOptions(refetchType: InvalidateRefetchType.none)
        )
        _ = await client.getQueryResult(
            QueryOptions<Int>(
                queryKey: key,
                staleTime: .infinity
            )
        )

        let refetched = try await client.refetchQuery(QueryOptions<Int>(queryKey: key))
        #expect(refetched == 2)
    }

    @Test func retryDelayResolverUsesZeroBasedFailureCount() async throws {
        let client = QueryClient()
        let key: QueryKey = [.string("retry"), .string("delay-index")]
        let counter = Counter()
        let recorder = IntRecorder()

        struct SampleError: Error {}

        let options = QueryOptions<String>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                throw SampleError()
            },
            retry: .maxAttempts(2),
            retryDelay: .resolver { failureCount, _ in
                recorder.append(failureCount)
                return 0
            }
        )

        do {
            _ = try await client.refetchQuery(options)
            Issue.record("Expected refetchQuery to throw")
        } catch {}

        let counts = recorder.snapshot()
        #expect(await counter.value == 3)
        #expect(counts == [0, 1, 2])
    }

    @Test func refetchQueryCancelRefetchFalseReusesInFlightFetch() async throws {
        let client = QueryClient()
        let key: QueryKey = [.string("refetch"), .string("dedupe-in-flight")]
        let counter = Counter()

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                let value = await counter.value
                if value > 1 {
                    try await Task.sleep(nanoseconds: 80_000_000)
                }
                return value
            }
        )

        _ = try await client.fetchQuery(options)

        let firstTask = Task {
            try await client.refetchQuery(options, cancelRefetch: false)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let secondTask = Task {
            try await client.refetchQuery(options, cancelRefetch: false)
        }

        let first = try await firstTask.value
        let second = try await secondTask.value

        #expect(first == 2)
        #expect(second == 2)
        #expect(await counter.value == 2)
    }

    @Test func refetchQueryCancelRefetchTrueCancelsAndStartsNewFetch() async throws {
        let client = QueryClient()
        let key: QueryKey = [.string("refetch"), .string("cancel-and-restart")]
        let counter = Counter()

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                let value = await counter.value
                if value > 1 {
                    try await Task.sleep(nanoseconds: 120_000_000)
                }
                return value
            }
        )

        _ = try await client.fetchQuery(options)

        let firstTask = Task {
            try await client.refetchQuery(options, cancelRefetch: true)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let secondTask = Task {
            try await client.refetchQuery(options, cancelRefetch: true)
        }

        let first = try await firstTask.value
        let second = try await secondTask.value

        #expect(first == 1)
        #expect(second == 3)
        #expect(await counter.value == 3)
    }

    @Test func cancellationTokenCancelsLongRunningQueryOnRefetchCancellation() async throws {
        let client = QueryClient()
        let key: QueryKey = [.string("cancel-token"), .string("refetch-cancel")]
        let counter = Counter()
        let callbackFired = BoolLatch()

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { context in
                await counter.increment()
                let attempt = await counter.value

                if attempt == 2 {
                    context.cancellationToken.onCancel {
                        callbackFired.set()
                    }
                    while !context.cancellationToken.isCancelled {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    throw QueryClientError.cancelled
                }

                return attempt
            },
            retry: .disabled
        )

        _ = try await client.fetchQuery(options)

        let firstTask = Task {
            try await client.refetchQuery(options, cancelRefetch: true)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let secondTask = Task {
            try await client.refetchQuery(options, cancelRefetch: true)
        }

        let first = try await firstTask.value
        let second = try await secondTask.value

        #expect(first == 1 || first == 3)
        #expect(second == 3)
        #expect(await counter.value == 3)
        #expect(callbackFired.value)
    }

    @Test func refetchQueriesThrowOnErrorTruePropagatesError() async throws {
        let client = QueryClient()
        let key: QueryKey = [.string("refetch"), .string("throw-on-error"), .string("single")]
        let counter = Counter()

        struct SampleError: Error {}

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                throw SampleError()
            },
            retry: .disabled
        )

        let stream = await client.observeQuery(options)
        let subscription = Task {
            for await _ in stream {}
        }

        let initialFailed = await waitUntil {
            let result = await client.getQueryResult(QueryOptions<Int>(queryKey: key))
            let count = await counter.value
            return result.fetchStatus == .idle && result.status == .error && count >= 1
        }
        #expect(initialFailed)

        do {
            try await client.refetchQueries(
                filters: QueryFilters(queryKey: key, exact: true, type: .active),
                options: RefetchOptions(cancelRefetch: true, throwOnError: true)
            )
            Issue.record("Expected refetchQueries to throw when throwOnError is true")
        } catch {}

        let retried = await waitUntil {
            await counter.value >= 2
        }
        #expect(retried)

        subscription.cancel()
    }

    @Test func refetchQueriesThrowOnErrorFalseContinuesOtherQueries() async throws {
        let client = QueryClient()
        let groupKey: QueryKey = [.string("refetch"), .string("throw-on-error"), .string("group")]
        let failKey: QueryKey = groupKey + [.string("fail")]
        let successKey: QueryKey = groupKey + [.string("success")]
        let failCounter = Counter()
        let successCounter = Counter()
        let shouldFail = Flag()

        struct SampleError: Error {}

        let failOptions = QueryOptions<Int>(
            queryKey: failKey,
            queryFn: { _ in
                await failCounter.increment()
                if await shouldFail.value {
                    throw SampleError()
                }
                return await failCounter.value
            },
            retry: .disabled
        )

        let successOptions = QueryOptions<Int>(
            queryKey: successKey,
            queryFn: { _ in
                await successCounter.increment()
                return await successCounter.value
            }
        )

        let failStream = await client.observeQuery(failOptions)
        let successStream = await client.observeQuery(successOptions)
        let failSubscription = Task {
            for await _ in failStream {}
        }
        let successSubscription = Task {
            for await _ in successStream {}
        }

        let primed = await waitUntil {
            let failCount = await failCounter.value
            let successCount = await successCounter.value
            return failCount == 1 && successCount == 1
        }
        #expect(primed)

        await shouldFail.set(true)
        try await client.refetchQueries(
            filters: QueryFilters(queryKey: groupKey, type: .active),
            options: RefetchOptions(cancelRefetch: true, throwOnError: false)
        )

        let bothAttempted = await waitUntil {
            let failCount = await failCounter.value
            let successCount = await successCounter.value
            return failCount == 2 && successCount == 2
        }
        #expect(bothAttempted)

        failSubscription.cancel()
        successSubscription.cancel()
    }

    @Test func focusRefetchesOnlyStaleActiveQueriesByDefault() async throws {
        let client = QueryClient()
        let staleCounter = Counter()
        let freshCounter = Counter()

        let staleOptions = QueryOptions<Int>(
            queryKey: [.string("focus"), .string("stale")],
            queryFn: { _ in
                await staleCounter.increment()
                return await staleCounter.value
            },
            staleTime: .milliseconds(0)
        )

        let freshOptions = QueryOptions<Int>(
            queryKey: [.string("focus"), .string("fresh")],
            queryFn: { _ in
                await freshCounter.increment()
                return await freshCounter.value
            },
            staleTime: .infinity
        )

        let staleStream = await client.observeQuery(staleOptions)
        let freshStream = await client.observeQuery(freshOptions)
        let staleSubscription = Task {
            for await _ in staleStream {}
        }
        let freshSubscription = Task {
            for await _ in freshStream {}
        }

        let primed = await waitUntil {
            let staleValue = await staleCounter.value
            let freshValue = await freshCounter.value
            return staleValue == 1 && freshValue == 1
        }
        #expect(primed)

        await client.setFocused(false)
        await client.setFocused(true)

        let refetched = await waitUntil {
            let staleValue = await staleCounter.value
            let freshValue = await freshCounter.value
            return staleValue == 2 && freshValue == 1
        }
        #expect(refetched)

        staleSubscription.cancel()
        freshSubscription.cancel()
    }

    @Test func reconnectRefetchesStaleQueriesExceptNetworkAlwaysDefault() async throws {
        let client = QueryClient()
        let staleCounter = Counter()
        let freshCounter = Counter()
        let alwaysCounter = Counter()

        let staleOptions = QueryOptions<Int>(
            queryKey: [.string("online"), .string("stale")],
            queryFn: { _ in
                await staleCounter.increment()
                return await staleCounter.value
            },
            staleTime: .milliseconds(0)
        )

        let freshOptions = QueryOptions<Int>(
            queryKey: [.string("online"), .string("fresh")],
            queryFn: { _ in
                await freshCounter.increment()
                return await freshCounter.value
            },
            staleTime: .infinity
        )

        let alwaysOptions = QueryOptions<Int>(
            queryKey: [.string("online"), .string("always-network")],
            queryFn: { _ in
                await alwaysCounter.increment()
                return await alwaysCounter.value
            },
            staleTime: .milliseconds(0),
            networkMode: .always
        )

        let staleStream = await client.observeQuery(staleOptions)
        let freshStream = await client.observeQuery(freshOptions)
        let alwaysStream = await client.observeQuery(alwaysOptions)
        let staleSubscription = Task {
            for await _ in staleStream {}
        }
        let freshSubscription = Task {
            for await _ in freshStream {}
        }
        let alwaysSubscription = Task {
            for await _ in alwaysStream {}
        }

        let primed = await waitUntil {
            let staleValue = await staleCounter.value
            let freshValue = await freshCounter.value
            let alwaysValue = await alwaysCounter.value
            return staleValue == 1 && freshValue == 1 && alwaysValue == 1
        }
        #expect(primed)

        await client.setOnline(false)
        await client.setOnline(true)

        let refetched = await waitUntil {
            let staleValue = await staleCounter.value
            let freshValue = await freshCounter.value
            let alwaysValue = await alwaysCounter.value
            return staleValue == 2 && freshValue == 1 && alwaysValue == 1
        }
        #expect(refetched)

        staleSubscription.cancel()
        freshSubscription.cancel()
        alwaysSubscription.cancel()
    }

    @Test func queryObservableAutoStartsAndRefetches() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("observable"), .string("single")]

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return await counter.value
            }
        )

        let observable = await MainActor.run {
            client.makeQueryObservable(options)
        }

        let loaded = await waitUntilMainActor {
            observable.status == .success && observable.data == 1
        }
        #expect(loaded)

        let refetchTask = await MainActor.run {
            observable.refetch()
        }
        await refetchTask.value

        let refetched = await waitUntilMainActor {
            observable.data == 2
        }
        #expect(refetched)

        await MainActor.run {
            observable.stop()
        }
    }

    @Test func queryObservableStopDetachesActiveObserver() async throws {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("observable"), .string("stop-detach")]

        let options = QueryOptions<Int>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                return await counter.value
            },
            staleTime: .milliseconds(0)
        )

        let observable = await MainActor.run {
            client.makeQueryObservable(options)
        }

        let loaded = await waitUntilMainActor {
            observable.status == .success && observable.data == 1
        }
        #expect(loaded)

        await MainActor.run {
            observable.stop()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        try await client.invalidateQueries(
            filters: QueryFilters(queryKey: key),
            options: InvalidateOptions()
        )

        #expect(await counter.value == 1)
    }

    @Test func queriesObservableCombineUpdatesOnRefetchAll() async throws {
        let client = QueryClient()
        let leftCounter = Counter()
        let rightCounter = Counter()

        let leftOptions = QueryOptions<Int>(
            queryKey: [.string("observable"), .string("combine-left")],
            queryFn: { _ in
                await leftCounter.increment()
                return await leftCounter.value
            }
        )

        let rightOptions = QueryOptions<Int>(
            queryKey: [.string("observable"), .string("combine-right")],
            queryFn: { _ in
                await rightCounter.increment()
                return await rightCounter.value
            }
        )

        let observable = await MainActor.run {
            client.makeQueriesObservable([leftOptions, rightOptions]) { results in
                results.compactMap(\.data).reduce(0, +)
            }
        }

        let loaded = await waitUntilMainActor {
            observable.hasValue && observable.value == 2
        }
        #expect(loaded)

        let refetchTask = await MainActor.run {
            observable.refetchAll()
        }
        await refetchTask.value

        let updated = await waitUntilMainActor {
            observable.value == 4
        }
        #expect(updated)

        await MainActor.run {
            observable.stop()
        }
    }

    @Test func swiftUIEnvironmentSupportsQueryClientReplacement() async throws {
#if canImport(SwiftUI)
        await MainActor.run {
            var values = EnvironmentValues()
            let first = QueryClient()
            let second = QueryClient()

            values.queryClient = first
            #expect(values.queryClient === first)

            values.queryClient = second
            #expect(values.queryClient === second)
        }
#endif
    }

}
