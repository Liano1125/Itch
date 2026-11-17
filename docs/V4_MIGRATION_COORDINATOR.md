# V4 Migration Coordinator

## Scope

`V4MigrationCoordinator` is the first orchestration layer for the currently
implemented V3 Library and AppState converters. It performs:

1. Clean-context guards.
2. Read-only V3 structural preflight.
3. Abort before writes when structural issues exist.
4. Library conversion into an isolated V4 staging context.
5. AppState conversion into that same staging context.
6. Read-only field-by-field verification.
7. A second source inventory to detect changes during the conversion window.
8. Manifest construction and a blocked/eligible-for-independent-gates outcome.

## Safety boundary

- The caller must create a new, disposable V4 staging store for every attempt.
- The converters save each domain independently. If any later step throws,
  discard the entire staging store; do not retry against that partially written
  context.
- The coordinator never opens or mutates the production database.
- It does not persist run checkpoints, implement resume, create backups, run
  SQLite integrity checks, atomically switch stores, or roll back production.
- `manifestEligibleForIndependentSafetyGates` is not production promotion
  authorization. Backup, integrity, crash recovery, rollback, complete domain
  coverage, and account-isolation acceptance remain separate gates.
- Only Library and AppState are currently converted. Any other non-empty V3
  domain is retained as uncovered by the Manifest builder and blocks promotion.

## Cross-process ownership

Every call to `V4MigrationCoordinator.run` requires an explicit
`ownerLockURL`. It must be the same stable lock-file URL used by
`V4MigrationSnapshotLifecycleCoordinator` for snapshot creation and recovery.
The coordinator acquires the OS-level exclusive lock before preflight and holds
it across both domain conversions, payload verification, final source
inventory, and manifest construction. If another process owns the lock, the
run fails before any staging write.

The lock file is persistent and must not be unlinked or replaced while the app
may be running. Any future migration writer or recovery entry point must use
this same lock. Direct calls to lower-level converters remain implementation
details and must not be exposed as independent migration entry points.

## Source consistency

The coordinator compares the privacy-safe preflight inventory digest before
and after conversion. This detects a changed source inventory during the run.
The caller must still ensure the V3 store is not concurrently mutated while
migration runs; this check is a final guard, not a transactional SQLite
snapshot.

## Retry semantics

This slice intentionally does not reuse a partially populated destination.
Each attempt requires a fresh staging store. Durable idempotency and crash
resume require a separately designed run journal and atomic staging lifecycle.
