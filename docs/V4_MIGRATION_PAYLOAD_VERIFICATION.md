# V4 Migration Payload Verification

Status: read-only verifier implementation; not wired into migration orchestration or production startup.

## What is compared

The verifier reads a clean V3 source context and a clean V4 staging context. It does not mutate either context.

### Personal library

- Library entries: source game ID, status, favorite flag, notes, added/updated timestamps; destination stable ID and account ownership must also match the expected legacy-unassigned identity.
- Collections: original collection key, title, created/updated timestamps, stable destination ID, and unassigned ownership.
- Collection memberships: collection key, game ID, sort order, added timestamp, composite source identity, stable destination ID, and unassigned ownership.
- Status history: original event ID, game ID, optional previous status, new status, changed timestamp, stable destination ID, and unassigned ownership.

### AppState

- Original logical key and deterministic destination ID.
- Scope is recomputed with the same AppStateScopeRegistry classification and confidence rules used by the converter. Established device/app-global classifications retain their corresponding scope; all provisional, account, Patreon, and unknown classifications remain legacy-unclassified.
- stringValue, dateValue, dataValue (byte-for-byte), and updatedAt.

## Failure behavior and privacy

Missing, extra, duplicate, payload-different, incorrectly scoped, or incorrectly identified rows fail verification. The verifier reports stable diagnostic codes only; it never serializes source keys, notes, values, account identifiers, or raw payloads.

Only exact source/destination record matches count as verified. A clean context is required. The verifier is read-only and does not itself set Manifest status, persist a Manifest, create a backup, or authorize promotion.

## Remaining integration

A later isolated migration orchestrator must call the verifier after conversion and before writing the verification summaries into the Manifest. That orchestrator still needs backup/snapshot validation, SQLite integrity checks, crash recovery, atomic promotion, and rollback. V3 remains authoritative until all gates are independently implemented and tested.

CI coverage is provided by the repository iOS Build workflow for this stacked PR base branch.
