# V3 → V4 Legacy Library Conversion

Status: isolated conversion slice only. This implementation does not open the production store, create a durable V4 store, promote V4, or change app startup.

## Scope

`V4LegacyLibraryConverter` copies the four V3 personal-library model families into their V4 replacements:

- `DBLibraryEntry` → `ItchPocketSchemaV4.DBLibraryEntry`
- `DBLibraryCollection` → `ItchPocketSchemaV4.DBLibraryCollection`
- `DBLibraryCollectionItem` → `ItchPocketSchemaV4.DBLibraryCollectionItem`
- `DBLibraryStatusEvent` → `ItchPocketSchemaV4.DBLibraryStatusEvent`

## Ownership rule

The converter accepts only a V3 source context and an empty V4 staging context. It intentionally has no active-account or session argument. Every converted row receives `accountID == nil` (`legacy-unassigned`).

A currently authenticated itch account is not evidence that historical V3 rows belong to that account. No ownership is inferred from the Keychain token, username, Patreon identity, or current session.

## Safety properties

- Requires clean source and destination contexts.
- Reads the V3 source only; it never inserts, updates, deletes, or saves source rows.
- Requires an empty destination for the four converted model families. It never merges into an unknown or partially converted staging library.
- Validates game references, collection references, and duplicate migration identities before writing.
- Sorts source records deterministically before conversion.
- Saves the destination once; on a write/save error, rolls back the destination context.
- Returns row counts and a SHA-256 digest over stable record identities only. Notes and other user-authored content are excluded from the digest.
- A second conversion into the same destination is rejected rather than silently duplicating or overwriting records.

## Explicitly not included

This slice does not convert shared catalog/cache models, update watches, calendar events, AppState, Spark metadata, or Patreon data. Calendar rows remain subject to the V4 quarantine policy. AppState rows remain subject to the explicit scope registry and ownership review.

It also does not create a SQLite snapshot, run `quick_check`, produce a durable migration manifest, manage disk-space requirements, promote a staging directory, or implement restart recovery/rollback. Those are separate mandatory gates before any production V4 cutover.

## Tests

`V4LegacyLibraryConverterTests` covers:

- Lossless field copying for entries, collections, membership, and status history.
- Explicit nil ownership on every converted personal row.
- Preservation of all source rows.
- Rejection of broken references before destination mutation.
- Rejection of non-empty staging tables and pending context changes.