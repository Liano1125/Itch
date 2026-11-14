# Account-Scoped Data Isolation Plan

## Status

Architecture and migration plan only. This document intentionally does not change the database schema or user-visible behavior. Implementation starts after the stacked database/detail PRs are integrated and the V3 migration baseline is stable.

## Why this is required

The current V3 schema stores several user-owned records with globally unique keys:

- `DBLibraryEntry.gameID` is unique without an account owner.
- `DBLibraryStatusEvent.id` and its `gameID` have no account scope.
- `DBLibraryCollection.id` and `DBLibraryCollectionItem.id` / membership are not scoped to an itch account.
- `DBAppState.key` is globally unique, while some feature state is account-specific.
- User-specific sync snapshots and watch state need an explicit ownership decision.

The canonical game catalogue (`DBGame`, `DBGameDetail`, `DBDeveloper`) is public/shared metadata and should normally remain global. The goal is not to duplicate public game descriptions for every user.

## Ownership model

Introduce a stable local account identity keyed by the itch.io numeric user ID, not username or display name.

- `DBAccount`: stable itch user ID, username snapshot, display name/avatar snapshot, created/last-used timestamps, and active marker if needed.
- User-owned rows carry `accountID`.
- Public catalogue rows remain global and are never deleted merely because an account signs out.
- Credentials remain in Keychain and are not copied into SwiftData.
- Patreon identity is separate from itch identity. A future explicit link record may associate a Patreon account with an itch account; do not assume matching email addresses.

## Proposed V4 ownership changes

| Model | Ownership decision | Proposed key / scope |
|---|---|---|
| DBGame, DBGameDetail, DBDeveloper | Shared catalogue | Keep global stable IDs |
| DBLibraryEntry | Per itch account | Unique `(accountID, gameID)` |
| DBLibraryStatusEvent | Per itch account | Unique event ID; indexed by `(accountID, gameID, changedAt)` |
| DBLibraryCollection | Per itch account | Unique `(accountID, collectionID)` |
| DBLibraryCollectionItem | Per itch account | Unique `(accountID, collectionID, gameID)` |
| DBAppState | Explicit scope | Add optional/account scope or split global and account state |
| DBUpdateWatch | Per itch account | Unique `(accountID, gameID)` |
| DBGameUpdate | Shared source data vs personal read state | Keep update content global; add separate per-account read/follow state if required |
| DBCalendarEvent | Review per field | Personal reminders/notes account-scoped; public release metadata can remain shared |
| DBTranslation, DBDiscoverySnapshot | Shared/rebuildable cache | Keep global unless cache key contains private/user-specific inputs |
| DBSparkMetadata | Device-local game-folder metadata | Keep device-local; do not bind to itch account |

## Migration rules

1. Freeze the current V3 schema as the migration source; never edit V1/V2/V3 snapshots.
2. Add V4 with explicit account ownership fields and deterministic composite identity helpers.
3. Before migration, create or resolve a legacy account identity only when the existing local itch profile ID can be recovered reliably.
4. Never guess an account owner from username text, game creator, or collection title.
5. If the previous schema contains user-owned rows but no reliable account ID, preserve them in a clearly marked legacy/unassigned bucket. Do not silently attach them to whichever account logs in first.
6. Make migration restartable and idempotent. Keep V3 authoritative until V4 has passed SQLite integrity and logical ownership checks.
7. Back up the V3 store before promotion and retain the existing quarantine/recovery behavior.
8. Do not delete public catalogue records when deleting an account's personal library data.

## Runtime account-switch contract

- Resolve the authenticated itch numeric user ID before loading account-owned repositories.
- Every account-owned repository query and write must require an explicit account ID.
- Switching accounts must cancel or invalidate in-flight account-scoped requests and refresh all account-owned snapshots.
- A late response from account A must never be committed after account B becomes active.
- Signing out hides account-owned data but does not erase it unless the user explicitly chooses account-data deletion.
- Re-authenticating the same itch user restores the same library and status history.
- Two accounts may independently add the same public game with different statuses, notes, favorites, and collections.

## Required tests

### Migration
- Empty V3 store to V4.
- Existing single-account data with a recoverable itch user ID.
- Existing data with no recoverable account ID (must remain unassigned and preserved).
- Interrupted migration at every promotion/backfill phase.
- Repeated migration is idempotent.
- Public game/developer/detail rows remain single shared records.

### Isolation
- Account A and B can add the same game independently.
- Status, notes, favorite, collections, and status history do not cross accounts.
- Account switch invalidates the previous account's in-memory snapshots.
- A delayed A request cannot write into B after a switch.
- Sign out and sign back into A restores A's data.
- Deleting A's personal data does not delete shared game metadata or B's rows.

## Implementation sequence

1. Add `DBAccount` and active-account resolution without changing existing repository behavior.
2. Add V4 schema and migration tests, including the unassigned legacy-data path.
3. Convert one repository at a time: library entries, status history, collections, then watches and personal state.
4. Make account ID a required repository dependency; remove implicit global access to personal rows.
5. Add account-switch cancellation/generation guards to network sync stores.
6. Add UI account-switch states and explicit account-data deletion controls.
7. Run the full persistence suite and physical-device sign-in/switch/re-sign-in checks.

## Non-goals

- Do not partition public itch game metadata by account.
- Do not store OAuth or Patreon tokens in the database.
- Do not infer account identity from usernames or Patreon profiles.
- Do not combine the account-isolation migration with the Ren'Py runtime POC.
