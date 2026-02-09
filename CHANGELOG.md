# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Changed

- Breaking API refactor to Result-first typed failures.
- Replaced `QueryOptions<Data>` (`queryFn`) with `QueryOptions<Data, Failure>` (`query` returning `Result<Data, Failure>`).
- Replaced `QueryResult<Data>` with `QueryState<Data, Failure>`.
- Replaced primary APIs:
  - `fetch(_:)`
  - `prefetch(_:)`
  - `refetch(_:cancelRefetch:)`
  - `observe(_:)`
- SwiftUI observables are now typed on failure:
  - `QueryObservable<Data, Failure>`
  - `QueriesObservable<Data, Failure, Combined>`

### Verified

- Test suite passing (`11` tests) after migration.

## 0.1.0 - 2026-02-08

### Added

- Core query client with cache, stale state, invalidation, refetching, and retries.
- Query state model split into `status` and `fetchStatus` with derived flags.
- Query APIs:
  - `fetchQuery`, `prefetchQuery`, `refetchQuery`
  - `refetchQueries`, `invalidateQueries`
  - `getQueryData`, `setQueryData`
- SwiftUI integration:
  - `QueryObservable`, `QueriesObservable`
  - Environment injection via `.queryClient(_:)`
  - Observable factory helpers on `QueryClient`
- Query cancellation token in `QueryFunctionContext`.
- Swift Package Manager support (`Package.swift`).
- Documentation:
  - DocC overview and usage examples
  - Implementation roadmap (`docs/swift-query-port-plan.md`)
  - Parity matrix (`docs/tanstack-parity-matrix.md`)

### Verified

- Test suite passing (`24` tests).
