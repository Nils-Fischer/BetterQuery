# BetterQuery Swift Port Plan (TanStack Query-Inspired)

Last updated: 2026-02-07 (progress checkpoint)

## Goal

Build a Swift-first query library for SwiftUI and observable models, inspired by TanStack Query defaults and behavior, while focusing on a practical core feature set:

- Query caching and lookup by key
- Staleness and invalidation
- Retry behavior and fetch status/state modeling
- `enabled` gating
- Multi-query `combine`
- Core client API (`fetch`, `prefetch`, `refetch`, `get/set data`)
- SwiftUI observable integration

## Scope: V1 Feature Suite

### 1) Query key + cache model

- Canonical query key hashing with stable equality semantics.
- Query cache entries store:
  - data + `dataUpdatedAt`
  - error + `errorUpdatedAt`
  - status (`pending` / `success` / `error`)
  - fetch status (`idle` / `fetching` / `paused`)
  - invalidated flag
  - observer count and GC metadata
- Key-based APIs:
  - exact match
  - partial match filters for invalidate/refetch operations.

TanStack references:
- `tanstack-query/packages/query-core/src/queryCache.ts`
- `tanstack-query/packages/query-core/src/query.ts`
- `tanstack-query/packages/query-core/src/utils.ts`

### 2) Client defaults and option layering

- Client-level defaults with per-query overrides.
- Preserve TanStack-like defaults for V1 where applicable:
  - stale default (`staleTime = 0`)
  - retry default (`retry = 3`) for observer-driven queries
  - fetchQuery-style direct fetch default (`retry = false`)
  - cache/gc timing default parity where supported
  - network mode defaults (online assumptions initially)
- Merge precedence:
  1. library defaults
  2. client defaults
  3. per-call options

TanStack references:
- `tanstack-query/packages/query-core/src/queryClient.ts`
- `tanstack-query/packages/query-core/src/types.ts`

### 3) Fetch lifecycle and retryer behavior

- Query function execution with:
  - deduplication of in-flight fetches per key
  - cancellation wiring capability (follow-up expansion)
  - exponential/backoff retry scheduling using configured retry policy
  - retry stop conditions and terminal error propagation
- State transitions:
  - initial `pending + idle`
  - fetch start `pending/success/error + fetching`
  - completion `success/error + idle`
- Data-on-error behavior:
  - preserve last successful data while surfacing latest error.

TanStack references:
- `tanstack-query/packages/query-core/src/retryer.ts`
- `tanstack-query/packages/query-core/src/query.ts`
- `tanstack-query/packages/query-core/src/queryObserver.ts`

### 4) Staleness and invalidation

- `staleTime`-based freshness checks (`isStale`).
- Explicit invalidation (`invalidateQueries`) marks matching entries stale immediately.
- Optional refetch on invalidation with filter options:
  - active / inactive / all
  - exact / partial key filtering
- Refetch APIs:
  - `refetchQuery`
  - `refetchQueries(filters)`

TanStack references:
- `tanstack-query/packages/query-core/src/queryClient.ts`
- `tanstack-query/packages/query-core/src/query.ts`
- `tanstack-query/packages/query-core/src/queryObserver.ts`

### 5) `enabled` behavior

- Disabled queries do not auto-fetch.
- They can still expose cached data if present.
- Transition `enabled: false -> true` should trigger fetch evaluation based on stale/invalidated state.

TanStack references:
- `tanstack-query/packages/query-core/src/queryObserver.ts`

### 6) Multi-query + combine

- Multiple query observers aggregate into a combined result stream.
- `combine` callback maps array results into derived output.
- Memoization strategy to avoid redundant recompute when inputs are unchanged.

TanStack references:
- `tanstack-query/packages/query-core/src/queriesObserver.ts`

### 7) SwiftUI observable client layer

- `@Observable`/`ObservableObject` model wrapping query result subscriptions.
- Environment injection for `QueryClient`.
- Ergonomic APIs for:
  - single query observable
  - multi-query observable + combine
- Main-actor delivery for UI safety.

TanStack references (conceptual parity):
- `queryObserver.ts`
- `queriesObserver.ts`

### 8) Garbage collection basics

- Unobserved queries are retained until `gcTime` elapses, then evicted.
- Any new observer cancels pending GC eviction.

TanStack references:
- `tanstack-query/packages/query-core/src/removable.ts`
- `tanstack-query/packages/query-core/src/query.ts`

## Data and state model (contract)

Public result model should keep both state dimensions:

- `status`: `pending | success | error`
- `fetchStatus`: `idle | fetching | paused`

Derived flags:

- `isPending`
- `isLoading` (pending + fetching)
- `isFetching`
- `isRefetching` (fetching + !pending)
- `isSuccess`
- `isError`
- `isStale`

This mirrors the important TanStack split between data status and transport activity.

## V1 API surface

- `QueryClient`
  - `fetchQuery`
  - `prefetchQuery`
  - `refetchQuery`
  - `refetchQueries` (async/throws; controlled by `throwOnError`)
  - `invalidateQueries` (async/throws when refetch is requested and `throwOnError` is enabled)
  - `getQueryData`
  - `setQueryData`
- `QueryOptions`
  - key
  - queryFn
  - query function context cancellation token
  - enabled
  - staleTime
  - gcTime/cacheTime
  - retry/retryDelay
- `QueryCancellationToken`
  - explicit cancellation hook for query function transport cancellation
- `QueryResult`
  - state + derived flags + timestamps + failure metadata
- `combine` helper(s) for multi-query derived output

## Implementation phases

### Phase 1: Core cache + state machine

- Finalize key hashing, cache entry lifecycle, and state transitions.
- Ensure in-flight deduplication and deterministic observer notifications.

Exit criteria:
- Basic fetch/set/get works.
- Status/fetchStatus transitions are correct.

### Phase 2: Defaults, stale rules, invalidation, retry

- Lock in TanStack-like default values for supported options.
- Implement stale checks and invalidation/refetch filters.
- Implement retry policy and delay behavior with deterministic tests.

Exit criteria:
- Stale and invalidation behavior matches expected defaults.
- Retry behavior passes policy-focused tests.

### Phase 3: Observers + SwiftUI integration

- Solidify query observable API and environment wiring.
- Implement multi-query observation and combine semantics.

Exit criteria:
- SwiftUI integration demonstrates live updates with cache + invalidation.

### Phase 4: Hardening + docs

- Expand tests for edge cases and concurrency races.
- Document behavior parity and intentional deviations from TanStack.

Exit criteria:
- Stable test suite for core + observable behavior.
- Migration/usage docs are actionable.

## Current implementation status

### Completed

- Shallow-cloned TanStack Query core reference into `tanstack-query/` (sparse checkout of `packages/query-core`).
- Swift Package Manager distribution support added:
  - `Package.swift` with `BetterQuery` library product and `BetterQueryTests` test target.
  - package builds and tests pass via `swift test`.
- Core `QueryClient` and state model implemented with:
  - key hashing + partial key filtering
  - cache records with status/fetchStatus/error/data timestamps
  - `fetchQuery`, `prefetchQuery`, `refetchQuery`, `refetchQueries`
  - `getQueryData`, `setQueryData`
  - invalidation + refetch type handling
  - retry pipeline with default backoff behavior
  - network/focus toggles and paused fetching path
  - basic GC scheduling/eviction for inactive queries
- Observable integration implemented:
  - single-query async observation stream
  - multi-query observe + combine API
  - combined observable model for SwiftUI client usage (`QueriesObservable`)
  - SwiftUI environment key and observable wrapper model
- Multi-query combine quality improvements:
  - per-query result fingerprinting to skip redundant combine recomputation/emits when inputs are unchanged
- Initial test suite added for cache hit, invalidation, enabled gating, status split, combine, and fetch retry default.
- Additional behavior tests added:
  - observer default retry attempts (`retry = 3`)
  - stale-filtered refetch behavior for active queries
  - inactive stale semantics (`inactive` + `stale` filter only refetches after invalidation)
  - cached query function retention across follow-up refetches
  - retry delay resolver index parity (zero-based failure count)
  - in-flight refetch behavior for `cancelRefetch: false` (dedupe) and `cancelRefetch: true` (cancel + restart)
  - `throwOnError` propagation for `refetchQueries` and non-throw continuation behavior
  - focus/reconnect stale-refetch defaults (including `networkMode: .always` reconnect behavior)
  - SwiftUI observable lifecycle behavior (`QueryObservable` start/refetch/stop, `QueriesObservable` combine updates)
  - query-function cancellation token propagation on cancelled refetches
  - SwiftUI environment `queryClient` replacement behavior
- GC correctness fix:
  - fixed cancellation handling in GC scheduling so rescheduling no longer immediately evicts cache entries.
  - this restores intended TanStack-like `gcTime` behavior for inactive queries.
- SwiftUI ergonomics improvement:
  - `QueryClient` convenience factories for single and multi-query observable models.
  - observable wrappers now cancel active observation tasks in `deinit` for safer lifecycle handling.
- DocC usage/behavior docs expanded:
  - added concrete API usage examples for cache/fetch/observe flows.
  - documented refetch/invalidation `throwOnError` semantics.
  - documented SwiftUI environment wiring and observable factory usage.
- Parity matrix added:
  - detailed matched/partial/deferred TanStack behavior matrix in `docs/tanstack-parity-matrix.md`.

### In progress

- Transport-level cancellation ergonomics (examples/helpers) for common networking stacks.

### Remaining (prioritized)

1. Transport-level cancellation helpers
   - optional convenience adapters for common networking clients to consume `QueryCancellationToken`.
2. Docs parity refinement
   - expand parity matrix with short “how to migrate” notes for deferred areas.

## Test strategy

- Unit tests:
  - key hashing and matching
  - cache write/read + timestamps
  - invalidation filters and exact/partial matching
  - stale boundary checks
  - retry success/fail paths and max retries
  - enabled false/true transitions
  - combine recomputation behavior
- Integration tests:
  - multi-observer synchronization
  - refetch flows preserving previous data on error
  - GC eviction timing for inactive queries
- SwiftUI-level tests:
  - observable propagation on main actor
  - environment client replacement behavior

## Known intentional V1 constraints

- No mutation system in initial scope.
- No persistence/hydration plugin in initial scope.
- No automatic platform lifecycle managers; focus/online state is currently driven via `setFocused` / `setOnline`.
- No infinite query behavior in initial scope.

These can be layered after core parity is stable.

## Maintenance rule

This document is the canonical implementation roadmap.

When architecture, defaults, API surface, or phase status changes, update this document in the same change set.
