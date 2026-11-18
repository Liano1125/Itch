# V4 staging snapshot lifecycle

V4MigrationStagingStoreManager owns only disposable staging directories for a single migration attempt.

## Contract

- The authoritative V3 source is opened read-only by the SQLite Online Backup helper. Committed WAL content is included in the SQLite snapshot.
- Each attempt receives a fresh runID and stagingStoreID; the manager never reuses an existing staging directory.
- The copied database is checked read-only with PRAGMA integrity_check and PRAGMA foreign_key_check before a handle is returned. The full check rejects both SQLite structural corruption and referential-integrity violations, including violations left by a source writer that had foreign-key enforcement disabled.
- A failed copy or failed integrity check removes only the partial staging directory created for that attempt.
- discard(runID:stagingStoreID:) is idempotent and derives the only directory it may remove from validated opaque identifiers.
- Source files and sibling staging attempts are never removed by this manager.

## Deliberate limits

- The caller remains responsible for ensuring the source store is in an appropriate stable state and for coordinating SwiftData container lifetimes.
- The manager does not write migration journal transitions, run Library/AppState conversion, verify V4 field parity, or decide whether a staging store is eligible for promotion.
- The manager does not change app startup, switch production storage, or delete/replace the V3 source.
- A new staging ID is required after interruption or failure; do not retry conversion in a partially written staging database.
