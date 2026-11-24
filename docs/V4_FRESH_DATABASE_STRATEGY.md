# Fresh V4 Database Strategy

Decision confirmed: 2026-11-21

## User-approved behavior

- Do not migrate any V3 local data into V4.
- Discard the need to preserve old caches, personal library records, collections, calendar events, Update Watch settings, and V3 AppState.
- Do not migrate the old itch OAuth session or Patreon session.
- Require the user to sign in to itch and Patreon again.
- Rebuild public game information and supported personal data from online sources where possible.
- Keep the old V3 database untouched during a short post-cutover observation period. Delete it only after explicit cleanup and rollback acceptance tests pass.

The user accepts that notes, manually-created calendar items, and other data that the remote services cannot reproduce may be permanently lost.

## Data initialization matrix

| Data | First V4 launch |
|---|---|
| itch account registry | Empty; create after successful OAuth profile validation |
| itch OAuth token | Obtain again and store only in Keychain |
| Patreon identity/session | Reauthenticate independently; never infer from itch identity |
| Personal library | Empty; reload only from supported authoritative sources or user action |
| Collections and status history | Empty |
| Calendar reminders, notes, overlays | Empty |
| Update Watch | Empty; user re-enables desired watches |
| V3 AppState | Not copied; use V4 defaults |
| Public game/developer/detail/update data | Fetch online and cache in shared catalog |
| Discovery/translation caches | Rebuild on demand |
| Spark local scan metadata | Do not import; rescan device-local files when supported |

## Implementation delivered in this slice

Sources/Services/V4FreshStoreBootstrap.swift:
- Does not accept a V3 URL and never opens V3.
- Uses a stable cross-process lock.
- Creates a new V4 SwiftData store in a unique sibling staging directory.
- Verifies that the initial V4 account and account-owned personal tables are empty.
- Closes the container before SQLite integrity and read-only reopen checks.
- Atomically moves the validated staging directory to the final V4 directory.
- Reuses a valid existing V4 store.
- Quarantines an incomplete or invalid existing V4 directory instead of deleting it.

Tests/V4FreshStoreBootstrapTests.swift covers fresh creation without V3 import, preservation of the legacy V3 fixture, idempotent reuse, and quarantine rather than deletion.

## Important boundary

This bootstrap component is not yet wired into itchPocketApp. The app still constructs the V3 AppDatabase, and the existing view/store graph still has V3/global dependencies. Do not switch production startup until the account-aware V4 repositories and their view dependencies are complete.

## Remaining implementation roadmap

### A. Finish V4 account boundary
- Complete account-scoped Library, Calendar, Update Watch, and AppState repositories.
- Keep public catalog/cache repositories shared only where payloads are not account-private.
- Keep account deletion and late-write protection.

### B. Replace V3/global runtime wiring
- Replace singleton feature stores with injected V4 repositories.
- Make active account scope explicit for every personal-data read and write.
- Keep device-local Spark scanning separate from itch account state.
- Keep Patreon authentication independent.

### C. V4 startup state machine
- Integrate V4FreshStoreBootstrap into app startup only after repository wiring.
- On clean install, create V4 and require fresh provider login.
- On existing V3 install, leave V3 untouched and create a separate V4 store.
- On interrupted bootstrap, validate/reuse final V4 or quarantine invalid state and rebuild.
- Do not silently fall back to V3 after V4 has become authoritative.

### D. Acceptance and release
- Test clean install and upgrade from an existing V3 installation.
- Test V4 first creation, interrupted staging, invalid final V4 quarantine, and restart.
- Test sign-in, sign-out, account switch, account removal, and stale async requests.
- Test network reconstruction of shared game metadata and supported library sources.
- Keep V3 untouched through the observation window.
- Implement old V3 cleanup as a separate change with explicit rollback and filesystem tests.

## Stage tracking

The overall project remains in Stage 2: V4 account isolation and unified database management. The stage percentage does not increase merely because the migration scope is simpler. It increases only after the account-aware runtime graph, V4 startup, restart recovery, and rollback/retention acceptance gates are implemented and verified.
