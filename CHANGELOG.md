# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Changed

- Breaking API simplification to hook-first, throwing query functions.
- Replaced `QueryOptions<Data, Failure>` with `QueryOptions<Data>` and `queryFn`.
- Replaced `QueryState<Data, Failure>` with `QueryResult<Data>` (erased errors).
- Added `QueryResult.result` computed value (`Result<Data, any Error>?`).
- Renamed primary APIs:
  - `fetch` -> `fetchQuery`
  - `prefetch` -> `prefetchQuery`
  - `refetch` -> `refetchQuery`
  - `observe` -> `observeQuery`
- SwiftUI observables now use erased errors:
  - `QueryObservable<Data>`
  - `QueriesObservable<Data, Combined>`
- Renamed SwiftUI factory helpers:
  - `makeQueryObservable` -> `useQuery`
  - `makeQueriesObservable` -> `useQueries`

### Verified

- Test suite passing (`14` tests) after migration.

## 0.2.0 - 2026-02-09

### Changed

- Breaking API refactor to Result-first typed failures.
- Replaced throw-based query functions with `QueryOptions<Data, Failure>` (`query` returning `Result`).
- Replaced `QueryResult<Data>` with typed `QueryState<Data, Failure>`.
- SwiftUI observables moved to typed failure generics.

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
