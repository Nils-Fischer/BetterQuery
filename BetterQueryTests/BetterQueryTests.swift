import Foundation
import Testing
@testable import BetterQuery
#if canImport(SwiftUI)
import SwiftUI
#endif

struct BetterQueryTests {
    enum SampleError: Error, Sendable, Equatable {
        case failed(Int)
    }

    actor Counter {
        private(set) var value = 0

        func increment() {
            value += 1
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

    private func castSampleError(_ error: (any Error)?) -> SampleError? {
        guard let error else { return nil }
        return error as? SampleError
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

    @Test func throwingFailurePropagatesFromFetchAndRefetch() async {
        let client = QueryClient()
        let options = QueryOptions<String>(
            queryKey: [.string("typed"), .string("fetch")],
            queryFn: { _ in throw SampleError.failed(7) },
            retry: .disabled
        )

        do {
            _ = try await client.fetchQuery(options)
            #expect(Bool(false))
        } catch let error as SampleError {
            #expect(error == .failed(7))
        } catch {
            #expect(Bool(false))
        }

        do {
            _ = try await client.refetchQuery(options)
            #expect(Bool(false))
        } catch let error as SampleError {
            #expect(error == .failed(7))
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func observeQueryEmitsErrorAndResultFailure() async {
        let client = QueryClient()
        let options = QueryOptions<String>(
            queryKey: [.string("typed"), .string("observe")],
            queryFn: { _ in throw SampleError.failed(1) },
            retry: .disabled
        )

        let stream = await client.observeQuery(options)
        var iterator = stream.makeAsyncIterator()

        var failed: QueryResult<String>?
        for _ in 0..<4 {
            guard let next = await iterator.next() else { break }
            if next.isError {
                failed = next
                break
            }
        }

        #expect(failed?.isError == true)
        #expect(castSampleError(failed?.error) == .failed(1))

        switch failed?.result {
        case let .failure(error):
            #expect((error as? SampleError) == .failed(1))
        default:
            #expect(Bool(false))
        }
    }

    @Test func queryResultComputedResultSuccessAndFailureMappings() async throws {
        let client = QueryClient()

        let successOptions = QueryOptions<String>(
            queryKey: [.string("result"), .string("success")],
            queryFn: { _ in "ok" }
        )
        _ = try await client.fetchQuery(successOptions)
        let successState = await client.getQueryResult(successOptions)
        switch successState.result {
        case let .success(value):
            #expect(value == "ok")
        default:
            #expect(Bool(false))
        }

        let failureOptions = QueryOptions<String>(
            queryKey: [.string("result"), .string("failure")],
            queryFn: { _ in throw SampleError.failed(4) },
            retry: .disabled
        )
        _ = try? await client.fetchQuery(failureOptions)
        let failureState = await client.getQueryResult(failureOptions)
        switch failureState.result {
        case let .failure(error):
            #expect((error as? SampleError) == .failed(4))
        default:
            #expect(Bool(false))
        }
    }

    @Test func fetchQueryDefaultRetryIsDisabled() async {
        let client = QueryClient()
        let counter = Counter()

        let options = QueryOptions<String>(
            queryKey: [.string("retry"), .string("fetch-default")],
            queryFn: { _ in
                await counter.increment()
                throw SampleError.failed(1)
            }
        )

        do {
            _ = try await client.fetchQuery(options)
            #expect(Bool(false))
        } catch let error as SampleError {
            #expect(error == .failed(1))
        } catch {
            #expect(Bool(false))
        }

        #expect(await counter.value == 1)
    }

    @Test func observeQueryDefaultRetryIsThreeAttempts() async {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("retry"), .string("observe-default")]

        let options = QueryOptions<String>(
            queryKey: key,
            queryFn: { _ in
                await counter.increment()
                let value = await counter.value
                if value < 4 {
                    throw SampleError.failed(value)
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

    @Test func retryDelayResolverUsesZeroBasedFailureCount() async {
        let client = QueryClient()
        let counter = Counter()
        let recorder = IntRecorder()

        let options = QueryOptions<String>(
            queryKey: [.string("retry"), .string("delay-index")],
            queryFn: { _ in
                await counter.increment()
                throw SampleError.failed(9)
            },
            retry: .maxAttempts(2),
            retryDelay: .resolver { failureCount, _ in
                recorder.append(failureCount)
                return 0
            }
        )

        do {
            _ = try await client.refetchQuery(options)
            #expect(Bool(false))
        } catch let error as SampleError {
            #expect(error == .failed(9))
        } catch {
            #expect(Bool(false))
        }

        #expect(await counter.value == 3)
        #expect(recorder.snapshot() == [0, 1, 2])
    }

    @Test func statusAndFetchStatusSplitMatchesPendingLoadingAndRefetching() async {
        let client = QueryClient()
        let counter = Counter()

        let options = QueryOptions<String>(
            queryKey: [.string("status"), .string("split")],
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

    @Test func refetchCancelRefetchFalseReusesInFlightFetch() async throws {
        let client = QueryClient()
        let counter = Counter()

        let options = QueryOptions<Int>(
            queryKey: [.string("refetch"), .string("reuse")],
            queryFn: { _ in
                await counter.increment()
                try await Task.sleep(nanoseconds: 120_000_000)
                return await counter.value
            },
            retry: .disabled
        )

        async let first: Int = client.refetchQuery(options, cancelRefetch: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        async let second: Int = client.refetchQuery(options, cancelRefetch: false)

        let (a, b) = try await (first, second)
        #expect(a == 1)
        #expect(b == 1)
        #expect(await counter.value == 1)
    }

    @Test func refetchCancelRefetchTrueCancelsAndRestartsFetch() async {
        let client = QueryClient()
        let counter = Counter()

        let options = QueryOptions<Int>(
            queryKey: [.string("refetch"), .string("restart")],
            queryFn: { _ in
                await counter.increment()
                try await Task.sleep(nanoseconds: 120_000_000)
                return await counter.value
            },
            retry: .disabled
        )

        _ = try? await client.fetchQuery(options)

        async let first: Int = client.refetchQuery(options, cancelRefetch: true)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let secondResult: Int
        do {
            secondResult = try await client.refetchQuery(options, cancelRefetch: true)
        } catch {
            #expect(Bool(false))
            return
        }

        do {
            let firstResult = try await first
            #expect(firstResult == 1)
        } catch {
            // If cancellation is observed as an error, that's also valid here.
            #expect(error is CancellationError || error is QueryClientInfrastructureError)
        }

        #expect(secondResult == 3)
        #expect(await counter.value == 3)
    }

    @Test func useQueryFactoryTransitionsAndRefetches() async {
        let client = QueryClient()
        let counter = Counter()

        let options = QueryOptions<Int>(
            queryKey: [.string("observable"), .string("single")],
            queryFn: { _ in
                await counter.increment()
                let value = await counter.value
                if value == 1 {
                    throw SampleError.failed(value)
                }
                return value
            },
            retry: .disabled
        )

        let observable = await MainActor.run {
            client.useQuery(options)
        }

        let firstFailed = await waitUntilMainActor {
            observable.isError && castSampleError(observable.error) == .failed(1)
        }
        #expect(firstFailed)

        let task = await MainActor.run {
            observable.refetch()
        }
        let result = await task.value

        switch result {
        case let .success(value):
            #expect(value == 2)
        default:
            #expect(Bool(false))
        }

        let recovered = await waitUntilMainActor {
            observable.isSuccess && observable.data == 2
        }
        #expect(recovered)

        await MainActor.run {
            observable.stop()
        }
    }

    @Test func useQueriesCombineConsumesQueryResults() async {
        let client = QueryClient()

        let left = QueryOptions<Int>(
            queryKey: [.string("combine"), .string("left")],
            queryFn: { _ in 1 }
        )

        let right = QueryOptions<Int>(
            queryKey: [.string("combine"), .string("right")],
            queryFn: { _ in 2 }
        )

        let observable = await MainActor.run {
            client.useQueries([left, right]) { results in
                results.compactMap(\.data).reduce(0, +)
            }
        }

        let loaded = await waitUntilMainActor {
            observable.hasValue && observable.value == 3
        }
        #expect(loaded)

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
