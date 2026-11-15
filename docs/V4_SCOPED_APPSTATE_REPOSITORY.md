# V4 Scoped AppState Repository

Status: first V4 implementation slice; not wired into V3 app startup.

## Data model

- V3 `DBAppState` remains in the V4 schema unchanged as a legacy source.
- New `DBScopedAppState` stores `scopeID`, `logicalKey`, typed values, and update time.
- Its unique stable ID is a length-prefixed composite of scope ID and logical key. The same logical key can therefore exist independently in multiple partitions.
- V4 schema includes both models. No V3 row is copied, deleted, rewritten, or assigned an owner by this change.

## Scope contract

- Device: one installation-wide namespace.
- App-global: shared public/cache metadata namespace.
- itch account: `itch:<numeric-user-id>`.
- Patreon account: independent `patreon:<provider-account-id>` namespace; never inferred from itch identity.
- Legacy/unclassified: explicit quarantine namespace; existing V3 rows remain in the legacy model until a reviewed migration/claim path exists.

Every repository operation requires an explicit `AppStateScope`. There is no implicit active-account fallback.

## Repository contract

`ScopedAppStateRepository` provides typed read/write, enumeration, snapshot/restore, scoped prefix deletion, and scoped deletion. Snapshot restoration verifies both scope and logical key. The old V3 `AppStateRepository` remains unchanged for the currently running V3 app.

## Validation

Tests cover:
- same logical key in two itch accounts;
- device/app-global/itch/Patreon namespace isolation;
- prefix deletion limited to one scope;
- snapshot restore and cross-account restore rejection;
- legacy V3 row preservation without implicit migration;
- transaction rollback;
- invalid identities and empty keys.

## Safety boundary

This slice only adds a V4 model and V4-only repository. It does not alter `AppDatabase` startup, current V3 repositories, migration plan, or production data. A later migration slice must stage and validate data before any V4 cutover.
