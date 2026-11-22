# V4 Runtime Integration Boundary: Personal Library and Patreon

## Status

This document records the next integration boundary after the V4 account registry, scoped repositories, and first observable V4 stores. It is an implementation contract, not a claim that the production app has switched to V4.

- Production startup remains on V3.
- V3 data is not imported into V4.
- The V4 database starts empty.
- itch.io and Patreon require fresh authentication after the eventual V4 activation.
- The V4 PR remains Draft and must not be merged as part of this work.

## 1. Personal library data ownership

The existing `PersonalLibraryStore` is not a safe V4 persistence adapter. It is a V3-backed aggregate that reads and writes through `AppDatabase.shared` and combines personal library state with shared catalog projections. Binding an `ItchAccountSession` to it only adds request guards; it does not change the database or assign rows to an account.

The V4 runtime must keep these domains separate:

| Existing library field/data | V4 ownership | Runtime rule |
| --- | --- | --- |
| Game membership, status, favorite, personal notes, added/updated timestamps | Account-scoped `DBLibraryEntry` | Persist only through `AccountScopedLibraryRepository`; account ID comes from the captured live session |
| Custom collections and collection membership | Account-scoped collection and membership rows | Add corresponding V4 store operations before exposing collection editing in the V4 UI |
| Status history | Account-scoped status-event rows | Keep history scoped to the same itch account; do not reconstruct it from current status |
| Game title, URL, cover, engine, developer relationship | Shared catalog | Resolve from V4 shared `DBGame` / developer catalog; never duplicate these values into a personal entry |
| Developer avatar, Patreon URL, Discord URL, discovery tags | Shared developer/detail/source data | Resolve from shared catalog/source repositories |
| Public game update records | Shared game/update catalog | Keep shared and refreshable; a user's library membership must not own the update feed |
| Spark playtime/save metadata | Shared/local runtime metadata boundary still needs a dedicated V4 design | Do not copy V3 Spark metadata during fresh V4 initialization |
| Historical local library notes, custom collections, old status history | Not migrated | User explicitly accepted their loss; no V3 row may be silently assigned to the first V4 login |

The existing `LibraryRecord` is therefore a UI projection, not a V4 persistence model. The V4 library UI should compose an account-scoped entry with shared catalog/detail data. It must not serialize the entire `LibraryRecord` into the account row.

## 2. Required V4 library adapter behavior

The current `V4PersonalLibraryStore` is intentionally only a first persistence slice. Before it can replace the legacy store, it still needs:

1. A joined read projection that resolves account entries against the V4 shared game/developer catalog.
2. Account-scoped collection CRUD and membership operations.
3. Account-scoped status-history reads and writes, with status change plus entry update committed atomically.
4. A single add-to-library operation that verifies or creates the shared game/catalog row, then writes the personal entry and initial status event in one transaction.
5. A single removal operation that removes the selected account's membership, status history, and collection memberships according to the defined product behavior, without deleting shared catalog rows.
6. Session-generation validation before persistence and again before publishing observable state.
7. Tests for two accounts sharing the same game catalog row while retaining different status, favorite, notes, collections, and status history.
8. Tests proving signed-out, stale-session, and removed-account operations fail closed.

The adapter must not read from `PersonalLibraryStore.shared`, `AppDatabase.shared`, or any V3 repository as a fallback. A missing V4 catalog row is an explicit error or a shared-catalog fetch/create flow, never a reason to open V3.

## 3. Patreon fresh-login ordering

The current `ProfileView` starts `PatreonAccountService.restore()` from its own `.task`. That restore reads the legacy `patreon_session_token` from Keychain.

The existing `V4PatreonReauthenticationGate` deletes that token and records completion, but it is deliberately not called by `V4AppDependencies.open()`. This is correct: opening a database for tests/previews must not mutate Keychain.

At the future production cutover, the root startup sequence must be:

1. Open or reuse the clean V4 store.
2. Call `prepareForProductionActivation()` and await successful completion.
3. If the Keychain deletion or completion marker write fails, keep the V4 app behind a recoverable activation-error screen; do not expose `ProfileView` or allow Patreon auto-restore to run.
4. Only after the gate succeeds, construct/publish the V4 production view tree.
5. Patreon may then restore; because the old token has been removed, the account is disconnected and the user must explicitly connect again.
6. A newly connected Patreon token is saved independently in Keychain and must never be written into the itch account registry.

The V3 production startup path must remain unchanged until the full V4 cutover checklist is approved. The gate must run once per installation using its completion marker; it must not be run on every view appearance.

## 4. Cutover remains blocked

Do not switch `itchPocketApp`, `ContentView`, or `ProfileView` to V4 yet. The following are still required before the production switch:

- Complete the V4 library joined projection, collection and status-history operations.
- Inject the V4 stores through a deliberate view-model boundary rather than relying on global `*.shared` stores.
- Make Patreon gate execution an awaited root-startup prerequisite before any Patreon restore task can run.
- Verify fresh V4 first launch is empty, restart reopens the same V4 store, and V3 remains byte-for-byte untouched.
- Exercise interrupted bootstrap, corrupt/incomplete V4 quarantine, activation-gate failure, app relaunch, and rollback/retention behavior on device.
- Keep V3 during the agreed short observation window; only perform V3 cleanup in a separate, explicitly verified operation.

## 5. Current verified boundary

- `V4AppDependencies` opens only the fresh V4 store and creates V4-only stores.
- `V4PersonalLibraryStore` reads/writes only account-scoped personal entry fields.
- `AccountScopedLibraryRepository` requires the account registry row and a pre-existing shared V4 game row for an entry write.
- The legacy `PersonalLibraryStore` still uses V3 `AppDatabase` and combines personal and shared catalog data.
- `ProfileView` still invokes Patreon restore directly; the activation gate is not wired into the production root because V3 is still active.

These are intentionally separate states: the V4 foundation is implemented, but production activation is not.
