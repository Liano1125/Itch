# V4 Architecture Decision: Fresh Database Initialization

Decision date: 2026-11-21

## Product decision

The user explicitly accepts losing all old local V3 caches and personal records. Production will therefore **not import, convert, claim, or merge any V3 rows into V4**. The user will sign in to itch and Patreon again; neither provider's old login state or token is migrated.

The V3 database remains untouched during a short safety-observation period after V4 production launch. It may be deleted only after the new V4 release is verified stable and a separate cleanup/rollback acceptance gate passes.

This decision supersedes the former production requirements for V3 ownership inference, V3 snapshot conversion, legacy-row quarantine inside V4, field-by-field V3/V4 payload equivalence, and V3-to-V4 data restoration. Existing conversion code and tests may remain as non-production historical tooling; they are not on the new startup path.

## Current implementation status

- V4 schema and account-scoped repositories exist in the development branch.
- V4 account/session/removal concurrency protections are being implemented.
- A new V4FreshStoreBootstrap component now creates an empty V4 store in a unique sibling staging directory, closes SwiftData, runs SQLite integrity/read-only checks, and atomically promotes the directory.
- An invalid existing V4 directory is quarantined rather than deleted.
- The bootstrap API does not accept or open a V3 URL.
- The production app still constructs AppDatabase using ItchPocketSchemaV3. The app startup switch has **not** happened.
- Existing feature stores and views still include V3/global repository wiring. They must be converted before V4 becomes production.

## New production architecture

1. Keep the current V3 production database and runtime untouched while account-aware V4 repositories are completed.
2. Prepare a clean V4 database at a separate versioned location. Never use the V3 URL or V3 contents as an input.
3. Create V4 in a unique staging directory under an exclusive cross-process bootstrap lease.
4. Close all SwiftData handles; run SQLite integrity_check, foreign_key_check, and read-only reopen validation.
5. Atomically rename the validated staging directory to the V4 final directory.
6. On relaunch, validate and reuse an existing valid V4 store. If it is invalid, quarantine the directory and initialize a fresh V4 store without deleting the quarantined copy.
7. Wire the complete account-aware repository/store/view graph to V4, then switch app startup.
8. Keep V3 untouched for the observation window. Remove it only after a separately tested cleanup and rollback decision.

## Data policy

| Domain | V4 first launch policy |
|---|---|
| Itch account registry | Empty; create only after successful profile validation using numeric itch user ID |
| Itch OAuth | User signs in again; token stays in Keychain, never SwiftData |
| Patreon identity/session | User signs in again; remains independent from itch identity |
| Personal library, collections, status history | Empty; user rebuilds from supported online sources or manually |
| Calendar reminders, notes, personal overlays | Empty |
| Update Watch | Empty; user re-enables watches |
| AppState | Start with V4 defaults; do not copy V3 global keys |
| Shared game/developer/detail/update data | Re-fetch online and repopulate shared caches |
| Translation/discovery caches | Rebuild on demand |
| Device-local Spark scan metadata | Not imported; rescan local files where supported |

Do not promise that every personal record can be reconstructed from itch. Public game metadata can be fetched again; local notes, custom calendar events, and some personal configuration may be permanently lost under this approved policy.

## Safety requirements that remain mandatory

- Stable numeric itch account IDs and strict per-account repository predicates.
- Per-account request generations; stale async work cannot publish or persist.
- Account removal must block late writes and clear only that account's notification namespace.
- OAuth tokens remain Keychain-only.
- Patreon identity and credentials are never inferred from itch identity.
- Shared catalog/cache data must not accidentally contain account-private responses.
- New V4 initialization and corruption recovery must be atomic and restart-safe.
- No broad deletion of V3 data during initial V4 startup.
- No production switch until every active feature store and view uses the V4 dependency graph.

## Remaining stages before production cutover

1. Finish V4 account-scoped repositories and prove account A/B separation.
2. Replace V3 singleton stores and global AppState access with injected V4 repositories.
3. Finish V4 calendar source/personal-state boundaries and account-scoped Update Watch.
4. Wire independent itch and Patreon reauthentication flows to the V4 app graph.
5. Integrate V4FreshStoreBootstrap with app startup behind a tested startup state machine.
6. Test clean install, existing V3 install, interrupted first bootstrap, corrupt V4 quarantine/recreate, sign-out, account switch, account removal, and network cache rebuild.
7. Switch production startup to V4 while retaining the V3 directory.
8. Observe a stable release, then separately implement and test old V3 cleanup.

## Explicitly not authorized

- Do not import any V3 rows into V4.
- Do not migrate old itch or Patreon login state.
- Do not delete V3 during the initial V4 startup.
- Do not switch production startup before the V4 repository graph is complete.
- Do not merge the active Draft PR.
- Do not create scheduled automation or recurring checks.
