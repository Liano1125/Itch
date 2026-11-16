# V4 Migration Journal, Idempotency & Crash-Recovery Design

Status: design proposal only. This document does not add a journal model, write migration state, change conversion behavior, or authorize production cutover.

## Goals

Define the durable lifecycle around the isolated V3 → V4 coordinator so a process death, app relaunch, repeated user action, or source mutation cannot cause a partial staging store to be mistaken for a completed migration.

The first implementation should prefer safe restart-from-snapshot over in-place continuation. True continuation of partially converted domains is deferred until each converter has transactional, idempotent checkpoint semantics.

## Non-goals

- No production V4 startup switch.
- No deletion or mutation of the authoritative V3 store.
- No account ownership inference for legacy rows.
- No OAuth/Patreon token handling or credential persistence.
- No claim that a manifest-eligible result is production-promotion authorization.
- No resume by blindly rerunning a converter against a partially populated destination.

## Required storage separation

Three storage roles must remain distinct:

1. **Authoritative source** — existing V3 database. It remains untouched and authoritative throughout this phase.
2. **Immutable source snapshot** — a consistent SQLite backup/snapshot created before conversion. Snapshot creation must include committed WAL state and must be validated after close. A file copy of only the main SQLite file while WAL is active is not an acceptable snapshot.
3. **Disposable staging store** — a unique V4 database location for exactly one attempt. It must never be the production V4 URL.

The journal/control record must live outside the disposable staging store. Otherwise deleting a failed staging store would also erase the only record explaining why it was discarded. The journal must not be stored in the source database either.

## Journal record

Persist a versioned record with the following fields. Store only opaque local identifiers, stable codes, counts, digests, and timestamps.

| Field | Meaning |
| --- | --- |
| journalVersion | Journal schema version, independent of V3/V4 schema versions |
| runID | Random stable identifier for one logical migration attempt; unique constraint |
| idempotencyKey | Stable key for a requested operation; unique while active |
| state | Current lifecycle state from the state machine below |
| sourceSchemaVersion | Source schema version observed in snapshot |
| sourceSnapshotID | Opaque identifier for the immutable snapshot |
| sourceSnapshotDigest | SHA-256 of the closed snapshot artifact, not a live inventory digest |
| sourceInventoryDigest | Structural inventory digest computed from the immutable snapshot |
| destinationSchemaVersion | Intended V4 schema version |
| stagingStoreID | Opaque unique staging-store identifier; never a production URL |
| completedDomains | Set of domain identifiers committed and verified in staging |
| manifestDigest | Digest of the canonical manifest, if produced |
| createdAt / updatedAt | UTC timestamps |
| lastTransitionAt | Timestamp of last valid state transition |
| failureCode | Optional stable, privacy-safe error code |
| attemptNumber | Monotonic count of full attempts for this idempotency key |

Do not persist raw game titles, notes, URLs, AppState values, Patreon credentials, itch cookies, tokens, raw error descriptions, or absolute filesystem paths in the journal. If a path is needed by the local storage layer, resolve it from the opaque store ID and keep it out of diagnostics and exported manifests.

The journal should have an append-only transition/event table (runID, sequence, fromState, toState, code, timestamp). Enforce unique (runID, sequence), and update the current record and append the transition in one journal transaction. This makes state history auditable without storing user payloads.

## State machine

Allowed forward states:

- requested — request accepted and idempotency key reserved.
- snapshotting — consistent source snapshot is being created.
- snapshotReady — snapshot closed and integrity-checked; source inventory recorded.
- stagingCreated — unique empty V4 staging store created and schema validated.
- converting — conversion is executing against the immutable snapshot.
- verifying — all currently supported converters returned; verifier and domain-coverage checks run.
- manifestWritten — canonical manifest persisted and its digest recorded.
- stagingValidated — staging store closed, SQLite integrity check passed, reopened read-only, and final counts/references/ownership checks passed.
- eligibleForIndependentSafetyGates — this migration attempt is valid as a staging artifact but still not production promotion.
- failed — attempt failed and staging must not be reused.
- abandoned — explicit operator/user cancellation; staging must not be reused.
- superseded — a newer attempt replaced this attempt after source snapshot or schema incompatibility.

No transition may skip a required state. failed, abandoned, and superseded are terminal. A retry creates a new runID and new stagingStoreID; it does not reopen a terminal attempt.

The first implementation may stop at manifestWritten or stagingValidated depending on available integrity gates. It must not write eligibleForIndependentSafetyGates until every predicate for that state is implemented and tested.

## Idempotency rules

1. runID is generated once and remains stable across retries of journal writes for that same attempt.
2. idempotencyKey prevents duplicate active requests for the same source snapshot, target schema, and migration operation.
3. Repeating a request with the same key returns the existing active/completed journal record; it must not start a second converter execution.
4. A terminal failed/abandoned run is never reused. A deliberate retry allocates a new runID, new stagingStoreID, and increments attemptNumber under the same logical operation.
5. Converter writes must target only a newly created empty staging store. Until converters have their own transactional checkpoints, a crash during conversion means discard the entire staging store.
6. A successful conversion is not idempotent merely because the same function can be called twice. Tests must prove duplicate invocation cannot duplicate rows, or the coordinator must guarantee one invocation per unique empty staging store.
7. completedDomains is evidence only after the domain save has completed and its destination rows have been read back and verified. A journal update before destination commit is invalid.

## Crash recovery policy (initial safe version)

On process launch, inspect non-terminal journal records:

- requested / snapshotting: if no closed, verified snapshot exists, mark failed with a stable interruption code and start a new attempt only on a new request.
- snapshotReady: snapshot may be reused only after rechecking its artifact digest, SQLite integrity, schema version, and inventory digest. Otherwise mark failed and create a new snapshot.
- stagingCreated: staging must be proven empty and valid before conversion begins. If the process cannot prove that, discard it and create a new attempt.
- converting / verifying: never continue writing to that staging store in the first implementation. Close and discard it, mark the run failed/interrupted, then require a new attempt from the immutable snapshot.
- manifestWritten: do not assume staging is valid. Reopen staging read-only and run SQLite integrity plus full payload verification. If any proof is unavailable or fails, discard staging and fail the run.
- stagingValidated: recheck the staging artifact digest and integrity before exposing it to any later safety gate.
- eligibleForIndependentSafetyGates: this is still not a production switch. Revalidate the journal, manifest digest, snapshot identity, and staging artifact before any separate promotion workflow.

Recovery must be repeatable: running recovery twice must produce the same terminal result and must not duplicate destination rows or transition events.

## Source consistency

The current coordinator's before/after inventory digest is a useful race detector, not a transactional snapshot. The journal implementation must create a consistent SQLite snapshot first, validate it after close, and run preflight/converters/verifier against that immutable snapshot. If the app cannot obtain a consistent snapshot including WAL content, migration must stop before staging conversion.

A source mutation after snapshot creation does not alter the attempt's input. It may require a fresh attempt if product policy requires the latest V3 state, but must never silently mix rows from two source versions.

## Staging integrity and promotion boundary

Before staging can be considered validated:

1. Close every ModelContext and SQLite connection.
2. Run SQLite quick_check (or stronger integrity_check) on the closed staging artifact.
3. Reopen read-only and validate schema version.
4. Re-run structural reference checks, account/scope ownership checks, row counts, and field-by-field payload verification.
5. Confirm no unexpected tables/domains or duplicate stable identities.
6. Compute a digest of the closed staging artifact and bind it to the journal and manifest.

A staging-valid result is still not permission to replace production. Atomic promotion, durable backup of V3 including WAL, restart recovery at every switch boundary, and rollback to untouched V3 remain separate gates.

## Failure handling and cleanup

- Never delete the authoritative V3 store.
- Never delete the only valid immutable source snapshot while a non-terminal attempt references it.
- Failed/abandoned staging may be garbage-collected only after its terminal journal event is durably committed.
- Cleanup must be scoped by exact opaque stagingStoreID; never use broad directory deletion or unqualified account cleanup.
- If journal persistence fails, stop conversion. Do not continue with in-memory-only lifecycle state.
- If a journal transition and its event cannot commit atomically, treat the journal as corrupt and block recovery/promotion.
- Preserve the last known-good V3 database and snapshot until a separately approved retention policy permits cleanup.

## Privacy-safe diagnostics

Use stable codes only, for example:

- journal.invalidTransition
- journal.persistenceFailed
- snapshot.creationInterrupted
- snapshot.integrityFailed
- staging.notEmptyAtStart
- staging.integrityFailed
- migration.interruptedDuringConversion
- migration.sourceSnapshotMismatch
- migration.manifestDigestMismatch

Never serialize localized error messages or raw underlying errors into the journal.

## Acceptance tests required before claiming recovery

- Duplicate request with the same idempotency key creates exactly one active run.
- Repeated journal transition request does not append duplicate events.
- Illegal state transitions are rejected.
- Crash simulation after every state transition followed by two recovery passes is deterministic.
- Crash during each converter causes staging disposal and no duplicate rows on a fresh retry.
- A source mutation after snapshot creation does not change the snapshot's converted payload.
- A main-database-plus-WAL fixture proves snapshot consistency.
- Corrupted snapshot and corrupted staging artifacts are rejected.
- Journal write failure stops conversion before any destination writes.
- Terminal failed/abandoned runs cannot be resumed or reused.
- Recovery never modifies V3 or changes app startup.
- Diagnostics contain no user payloads, credentials, raw keys, or filesystem paths.

## Implementation sequence

1. Introduce journal value types and strict transition validator with pure unit tests.
2. Add a journal repository backed by a separate local control database/file, with transactional current-state + event append.
3. Add a snapshot service using SQLite's supported backup mechanism; validate closed snapshot including WAL.
4. Adapt the coordinator to consume an immutable snapshot and unique staging-store factory.
5. Add deterministic recovery inspection; initial policy discards interrupted staging rather than resuming it.
6. Add SQLite integrity, post-close verification, and artifact digests.
7. Only after fault-injection coverage, consider per-domain transactional checkpoints and true continuation.
8. Keep production startup on V3 until backup, atomic switch, restart recovery, and rollback have independent acceptance evidence.
