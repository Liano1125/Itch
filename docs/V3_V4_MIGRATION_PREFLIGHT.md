# V3 → V4 Read-only Preflight (Legacy Tooling)

Status: retained for historical diagnostics and converter tests only; not used by the approved production startup path.

The product decision dated 2026-11-21 is to initialize a clean V4 database and not import V3 rows. The production V4 bootstrap must not open, inventory, snapshot, or depend on the V3 store.

V3MigrationPreflight remains a read-only diagnostic utility. It computes model counts and structural diagnostics without changing V3 data or assigning ownership. It is not a prerequisite for V4 initialization, V4 app startup, or cleanup of the retained V3 directory.

Production gates are instead:
- Empty V4 store creation in an isolated staging directory.
- SwiftData close before SQLite integrity and read-only reopen checks.
- Atomic first-time promotion and cross-process bootstrap ownership.
- Restart validation and quarantine of invalid V4 stores.
- Complete account-aware repository/store/view integration.
- A short post-cutover V3 retention window and separately tested cleanup.

The V3 preflight tests remain useful for preventing accidental source mutation in the legacy tooling.
