# V3 → V4 Migration Manifest

Status: isolated metadata contract and tests. This slice does not execute a migration, write a manifest to a production location, create a backup, promote V4, or change app startup.

## Purpose

A migration attempt needs one versioned, machine-readable record that ties together the read-only V3 preflight, per-domain converters, destination validation, and later recovery decisions. The manifest is evidence about a run; it is not itself proof that a store is safe to promote.

## Manifest fields

- `manifestVersion`: format version, independent of database schema versions.
- `runID` and `generatedAt`: identify one attempt.
- `sourceSchemaVersion` / `destinationSchemaVersion`: currently V3 `3.0.0` and V4 `4.0.0`.
- `registryVersion`: the AppState scope registry version used for classification.
- `sourceRowCount` and `sourceInventoryDigest`: source inventory summary from read-only preflight.
- `domains`: per-domain source/destination counts, destination scope counts, quarantined row count, digest plus its explicit kind, payload-verification summary, and integrity diagnostic codes.
- `integrityDiagnostics`: sorted, stable machine-readable codes.

## Digest semantics

A digest is meaningful only together with its kind:

- `structuralSHA256`: canonical preflight structure/counts/diagnostics.
- `stableIdentitySHA256`: stable row identities used by a domain converter.
- `keyOnlySHA256`: AppState keys only.

None of these digests is a payload-integrity digest. The manifest deliberately does not contain raw payloads, notes, tokens, account credentials, or user-authored calendar text.

## Payload verification

The summary distinguishes `notRun`, `partial`, `verified`, and `failed`, plus the method and verified/unverified row counts. A converter's successful save or matching row count alone is not field-by-field payload verification. The promotion predicate requires verified payloads, zero unverified rows, consistent scope counts, and no integrity diagnostics for every included domain.

## Promotion boundary

`isPromotionEligible` is a conservative metadata predicate, not an authorization to switch production. A real cutover must additionally pass:

1. Read-only V3 SQLite snapshot and `quick_check`.
2. Durable backup verification, including committed WAL content.
3. Fresh isolated V4 staging conversion and post-close `quick_check`.
4. Model counts, references, ownership, scope, and field-by-field payload equivalence.
5. Atomic promotion and a durable promotion marker.
6. Restart recovery at every interruption point.
7. Rollback to untouched V3 without deleting the recovery copy.

Until these gates exist and pass, the manifest must remain an audit artifact and V3 remains authoritative.

## Privacy and diagnostics

Diagnostics must be stable codes such as `reference.missingGame` or `scope.unclassifiedRows`; never embed source keys, game titles, notes, URLs containing credentials, OAuth tokens, or raw error descriptions. The manifest records counts and verification outcomes, not user data.

## Current integration status

The V3 preflight and the AppState/library converters currently expose separate report types. This manifest is the shared envelope for a later orchestration layer; wiring that layer, persisting the manifest, and verifying every model family remain future work. Calendar ownership splitting, update-watch ownership, Patreon identity isolation, and SQLite staging/recovery are not considered complete by this metadata contract.
