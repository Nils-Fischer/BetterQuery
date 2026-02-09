# BetterQuery vs TanStack Query Parity Matrix

Last updated: 2026-02-08

This matrix tracks practical behavior parity for the V1 Swift port.

## Legend

- `Matched`: implemented with equivalent behavior for the V1 scope.
- `Partial`: implemented, but with explicit limitations.
- `Deferred`: intentionally out of scope for current V1.

## Core parity

| Area | Status | Notes |
| --- | --- | --- |
| Query key hashing and partial matching | Matched | Stable key hashing and partial key filters are implemented. |
| Cache state split (`status` vs `fetchStatus`) | Matched | Pending/success/error and idle/fetching/paused are modeled separately. |
| Staleness (`staleTime`) | Matched | `0`, `infinity`, and `static` semantics are implemented. |
| Invalidation semantics | Matched | Invalidation marks stale immediately and supports refetch-type targeting. |
| Inactive stale filter behavior | Matched | Inactive queries are stale only when invalidated or missing data. |
| `enabled` gating | Matched | Disabled queries do not auto-fetch but can be refetched manually. |
| `fetch` retry default | Matched | Retry disabled by default for imperative fetches. |
| Observer retry default | Matched | Default retry attempts align with TanStack (`3`). |
| Retry delay progression | Matched | Exponential backoff uses zero-based failure count (`1000 * 2^n`, capped at `30000`). |
| In-flight dedupe/cancel refetch | Matched | `cancelRefetch: false` reuses in-flight fetch; `true` cancels and restarts. |
| Query function cancellation token | Matched | `QueryFunctionContext` provides `QueryCancellationToken` with `isCancelled` and `onCancel` hooks. |
| `throwOnError` refetch propagation | Matched | `refetchQueries`/`invalidateQueries` can propagate errors when enabled. |
| Focus/reconnect stale refetch defaults | Matched | Focus and reconnect refetch stale active queries by default; reconnect defaults respect `networkMode: .always` (`refetchOnReconnect = .never`). |
| Cache GC behavior (`gcTime`) | Matched | Inactive idle queries are evicted after GC timer; reschedule cancellation is handled correctly. |

## SwiftUI/client parity

| Area | Status | Notes |
| --- | --- | --- |
| Single query observable wrapper | Matched | `QueryObservable` is available and main-actor safe. |
| Multi-query combine observable | Matched | `QueriesObservable` supports combined outputs and memoized combine in core stream. |
| Environment injection | Matched | SwiftUI environment key + `queryClient(_:)` modifier implemented. |
| Environment replacement behavior | Matched | `EnvironmentValues.queryClient` replacement behavior is covered by tests. |
| Observable factory ergonomics | Matched | `QueryClient.makeQueryObservable` and `makeQueriesObservable` implemented. |
| Observable lifecycle behavior | Matched | Start/refetch/stop and multi-observable combine updates are covered by tests. |

## Known partial/deferred areas

| Area | Status | Notes |
| --- | --- | --- |
| Transport-native cancellation bridging | Partial | Explicit token hooks exist, but there is no framework-level automatic bridge like browser `AbortSignal`. |
| Mutation APIs | Deferred | Out of V1 scope. |
| Infinite queries | Deferred | Out of V1 scope. |
| Persistence/hydration plugins | Deferred | Out of V1 scope. |

## Verification source

Behavior is validated by executable tests in:

- `/Users/nilsfischer/Code/BetterQuery/BetterQueryTests/BetterQueryTests.swift`
