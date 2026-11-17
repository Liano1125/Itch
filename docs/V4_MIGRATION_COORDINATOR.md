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
- Conversion refuses to start without a live lease for the configured migration lock.
- It does not persist run checkpoints, implement resume, create backups, run
  SQLite integrity checks, atomically switch stores, or roll back production.
- `manifestEligibleForIndependentSafetyGates` is not production promotion
  authorization. Backup, integrity, crash recovery, rollback, complete domain
  coverage, and account-isolation acceptance remain separate gates.
- Only Library and AppState are currently converted. Any other non-empty V3
  domain is retained as uncovered by the Manifest builder and blocks promotion.

## Exclusive migration ownership

Every conversion entry point requires a live `V4MigrationOwnerLock.Lease`
and validates that it protects the exact configured lock-file path. The
snapshot lifecycle coordinator exposes `withExclusiveMigrationOwnership`,
which acquires one lease and keeps it alive across an asynchronous closure.
A full pipeline must use that same lease for:

1. Staging snapshot creation via the lease-taking overload.
2. Library and AppState conversion plus payload verification via
   `V4MigrationCoordinator.run(ownerLockURL:ownerLease:)`.
3. Any subsequent journal transitions and staging validation.

Do not call the convenience snapshot method and then start conversion after
it returns: that method intentionally releases its own lock when snapshot
creation ends. Do not acquire a second lock inside the closure. Recovery must
also use the lease-taking overload when it is part of a larger owned operation.
The lock file path must be stable and shared by every process and migration
entry point.

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
