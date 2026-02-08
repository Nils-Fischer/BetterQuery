# BetterQuery Agent Notes

## Canonical Plan

Use `docs/swift-query-port-plan.md` as the canonical roadmap for the Swift port and TanStack Query behavior alignment.

## Required Maintenance

- Any change to architecture, defaults, API surface, feature scope, or phase progress must update `docs/swift-query-port-plan.md` in the same change set.
- Do not introduce implementation behavior that conflicts with `docs/swift-query-port-plan.md` without updating that document first.

## Working Rule

- Before implementing new query-core or SwiftUI observable features, review `docs/swift-query-port-plan.md` and follow its phase/contract guidance.
