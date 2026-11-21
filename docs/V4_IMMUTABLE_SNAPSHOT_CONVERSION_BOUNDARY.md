# V4 immutable-snapshot conversion boundary

Status: implementation contract for the next migration slice. This document does not authorize production cutover.

## Verified current behavior

- `V4MigrationStagingStoreManager.createSnapshot` creates a consistent SQLite backup of the V3 file using SQLite Online Backup, runs `integrity_check` and `foreign_key_check`, reopens read-only, and returns a disposable artifact.
- `V4MigrationSnapshotLifecycleCoordinator` records snapshot lifecycle transitions and holds the cross-process owner lease while creating or recovering a snapshot.
- `V4MigrationCoordinator.run(source:destination:...)` currently accepts arbitrary caller-supplied ModelContexts. It checks the source inventory before and after conversion, but it does not prove that `source` was opened from the immutable snapshot returned by the staging manager.
- The coordinator commits multiple destination domains independently. A failure therefore requires disposal of the complete V4 staging store, not retrying against that context.
- No app startup path or production V4 store is switched by these components.

## Required next implementation

The next executable integration must be a single top-level migration-attempt runner. It must:

1. Acquire one `V4MigrationOwnerLock.Lease` and pass that exact lease through snapshot creation, journal transitions, conversion, and final staging validation.
2. Create the immutable SQLite snapshot from the authoritative V3 store. Do not run converters against the live V3 production context.
3. Close any pre-existing V3 SwiftData context/container that could write to the source. Open a read-only V3 `ModelContainer` against the snapshot URL and verify the schema before conversion.
4. Create a unique, empty V4 staging store for this run. Open the V4 destination container only at that attempt's staging URL.
5. Run preflight, converters, payload verification, and reference verification using only the snapshot-backed V3 context and the isolated V4 staging context.
6. Close both containers and all contexts before running the final SQLite integrity check, read-only reopen, schema check, and artifact digest.
7. Advance the journal only after the corresponding durable artifact or verification result exists. On any failure, close handles, discard only this attempt's staging directory, and record a terminal failure when the journal is writable.
8. Keep the authoritative V3 store untouched. A successful staging attempt remains only a candidate for independent safety gates.

## Explicitly forbidden shortcuts

- Passing the live production V3 context into the converter after creating a snapshot.
- Treating the before/after source inventory digest as a substitute for immutable input.
- Reusing a staging database after a converter has partially saved data.
- Opening a production V4 URL, changing `AppDatabase`, or changing app startup as part of this slice.
- Assigning V3 legacy personal rows to whichever itch account happens to be logged in.
- Deleting the V3 source or its only verified backup.

## Acceptance tests

- Mutate the live V3 source after snapshot creation; conversion output must still match the snapshot, not the later source.
- Prove the V3 snapshot container is opened with saves disabled and the live V3 source remains byte-for-byte unchanged.
- Prove every converter receives the snapshot-backed source context and the attempt-specific V4 destination context.
- Inject failure after each independently saving converter; the attempt is marked failed and its staging directory is removed.
- Re-run recovery twice; no duplicate events, writes, or cleanup outside the attempt directory.
- Hold a competing process lock during the attempt; a second runner cannot create a second active attempt.
- Close all SwiftData/SQLite handles before final integrity and digest checks.
- Confirm app startup still selects V3 and no production V4 directory is created.

## Promotion remains a separate phase

Even after this runner passes, production cutover still requires a durable V3 backup, atomic directory promotion, restart recovery at every rename/switch boundary, rollback to untouched V3, and account-aware production repository wiring. This document does not claim those gates are implemented.
