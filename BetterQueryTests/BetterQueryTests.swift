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

    @Test func fetchReadsFromCacheWhenFresh() async {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("cache"), .string("hit")]

        let options = QueryOptions<String, SampleError>(
            queryKey: key,
            query: { _ in
                await counter.increment()
                return .success("data")
            },
            staleTime: .infinity
        )

        let first = await client.fetch(options)
        let second = await client.fetch(options)

        #expect(first == .success("data"))
        #expect(second == .success("data"))
        #expect(await counter.value == 1)
    }

    @Test func typedFailurePropagatesFromFetchAndRefetch() async {
        let client = QueryClient()
        let options = QueryOptions<String, SampleError>(
            queryKey: [.string("typed"), .string("fetch")],
            query: { _ in .failure(.failed(7)) },
            retry: .disabled
        )

        let fetchResult = await client.fetch(options)
        let refetchResult = await client.refetch(options)

        #expect(fetchResult == .failure(.failed(7)))
        #expect(refetchResult == .failure(.failed(7)))
    }

    @Test func observeEmitsTypedError() async {
        let client = QueryClient()
        let options = QueryOptions<String, SampleError>(
            queryKey: [.string("typed"), .string("observe")],
            query: { _ in .failure(.failed(1)) },
            retry: .disabled
        )

        let stream = await client.observe(options)
        var iterator = stream.makeAsyncIterator()

        var failed: QueryState<String, SampleError>?
        for _ in 0..<4 {
            guard let next = await iterator.next() else { break }
            if next.isError {
                failed = next
                break
            }
        }

        #expect(failed?.isError == true)
        #expect(failed?.error == .failed(1))
    }

    @Test func fetchDefaultRetryIsDisabled() async {
        let client = QueryClient()
        let counter = Counter()

        let options = QueryOptions<String, SampleError>(
            queryKey: [.string("retry"), .string("fetch-default")],
            query: { _ in
                await counter.increment()
                return .failure(.failed(1))
            }
        )

        let result = await client.fetch(options)
        #expect(result == .failure(.failed(1)))
        #expect(await counter.value == 1)
    }

    @Test func observeDefaultRetryIsThreeAttempts() async {
        let client = QueryClient()
        let counter = Counter()
        let key: QueryKey = [.string("retry"), .string("observe-default")]

        let options = QueryOptions<String, SampleError>(
            queryKey: key,
            query: { _ in
                await counter.increment()
                let value = await counter.value
                if value < 4 {
                    return .failure(.failed(value))
                }
                return .success("ok")
            },
            retryDelay: .milliseconds(1)
        )

        let stream = await client.observe(options)
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

        let options = QueryOptions<String, SampleError>(
            queryKey: [.string("retry"), .string("delay-index")],
            query: { _ in
                await counter.increment()
                return .failure(.failed(9))
            },
            retry: .maxAttempts(2),
            retryDelay: .resolver { failureCount, _ in
                recorder.append(failureCount)
                return 0
            }
        )

        let result = await client.refetch(options)
        #expect(result == .failure(.failed(9)))
        #expect(await counter.value == 3)
        #expect(recorder.snapshot() == [0, 1, 2])
    }

    @Test func statusAndFetchStatusSplitMatchesPendingLoadingAndRefetching() async {
        let client = QueryClient()
        let counter = Counter()

        let options = QueryOptions<String, SampleError>(
            queryKey: [.string("status"), .string("split")],
            query: { _ in
                await counter.increment()
                try? await Task.sleep(nanoseconds: 20_000_000)
                return .success("ok")
            }
        )

        let stream = await client.observe(options)
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

        let options = QueryOptions<Int, SampleError>(
            queryKey: key,
            query: { _ in
                await counter.increment()
                return .success(await counter.value)
            },
            staleTime: .infinity
        )

        _ = await client.fetch(options)
        let stream = await client.observe(options)
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

    @Test func queryObservableTypedErrorAndRefetch() async {
        let client = QueryClient()
        let counter = Counter()

        let options = QueryOptions<Int, SampleError>(
            queryKey: [.string("observable"), .string("single")],
            query: { _ in
                await counter.increment()
                let value = await counter.value
                if value == 1 {
                    return .failure(.failed(value))
                }
                return .success(value)
            },
            retry: .disabled
        )

        let observable = await MainActor.run {
            client.makeQueryObservable(options)
        }

        let firstFailed = await waitUntilMainActor {
            observable.isError && observable.error == .failed(1)
        }
        #expect(firstFailed)

        let task = await MainActor.run {
            observable.refetch()
        }
        let result = await task.value

        #expect(result == .success(2))

        let recovered = await waitUntilMainActor {
            observable.isSuccess && observable.data == 2
        }
        #expect(recovered)

        await MainActor.run {
            observable.stop()
        }
    }

    @Test func queriesObservableCombineUsesTypedStates() async {
        let client = QueryClient()

        let left = QueryOptions<Int, SampleError>(
            queryKey: [.string("combine"), .string("left")],
            query: { _ in .success(1) }
        )

        let right = QueryOptions<Int, SampleError>(
            queryKey: [.string("combine"), .string("right")],
            query: { _ in .success(2) }
        )

        let observable = await MainActor.run {
            client.makeQueriesObservable([left, right]) { states in
                states.compactMap(\.data).reduce(0, +)
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
