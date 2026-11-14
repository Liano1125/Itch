# V3 → V4 Read-only Migration Preflight

Status: implementation slice; no production migration or startup change.

## Purpose

`V3MigrationPreflight` creates a privacy-safe inventory from an already-open V3 `ModelContext`. It is the first migration gate: establish a stable row-count snapshot and detect structural reference problems before any backup, staging, or conversion code is allowed to run.

## Guarantees

- Fetches V3 model rows and computes counts only.
- Does not insert, update, delete, save, or assign ownership to source records.
- Does not serialize user-authored notes, calendar text, OAuth credentials, or payload contents into the report.
- Produces a deterministic SHA-256 digest over schema version, model counts, ownership-review counts, and sorted structural diagnostics.
- Reports dangling references involving games, developers, updates, collections, and collection membership.
- Treats missing linked update rows as non-fatal, matching the existing calendar reference policy; a present update linked to another game is reported.
- Keeps all V3 personal rows explicitly in the ownership-review bucket. The currently signed-in account is never consulted.

## Ownership review required

V3 does not carry a durable itch account owner for these records. The report therefore marks all existing rows in these groups for review:

- Library entries
- Collections and collection membership
- Library status history
- Update watches
- Calendar events (mixed public and personal fields)
- AppState keys (scope registry not yet approved)

This is not a statement that every row is invalid. It means the migration must not attach those rows to an account without separate authoritative proof or a deliberate claim/import workflow.

## Deliberate non-goals

This slice does not:

- Open a production V3 database itself or configure a read-only SQLite connection.
- Copy or back up SQLite/WAL files.
- Create a V4 container or transform V3 rows.
- Split calendar source events from account-owned reminder state.
- Classify AppState keys.
- Promote V4, switch app startup, or modify user data.

The caller must supply the authoritative V3 context and ensure no concurrent writer changes the source during inventory collection. A later bootstrap layer must add a consistent SQLite snapshot, source immutability, staging, validation, restart recovery, and rollback before production use.

## Tests

`V3MigrationPreflightTests` covers empty-store inventory, populated-store counts, unresolved ownership reporting, privacy-safe output, stable digest generation, dangling-reference diagnostics, and the absence of context mutations.
