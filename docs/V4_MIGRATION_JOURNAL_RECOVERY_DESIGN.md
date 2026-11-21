# Legacy V3-to-V4 Migration Journal Design

Status: historical/non-production tooling as of 2026-11-21.

The approved production path no longer converts V3 data. Users accept a clean V4 database and will reauthenticate to itch and Patreon. Therefore the snapshot/conversion journal and state machine below are not production cutover requirements. The related implementation may remain for historical experiments and regression coverage, but the app startup path must not invoke it.

## Production V4 bootstrap lifecycle

1. Acquire a stable cross-process bootstrap lease.
2. If a valid V4 store already exists, open it read-only for schema validation, close it, run SQLite integrity and foreign-key checks, then reuse it.
3. If the V4 directory is incomplete or invalid, move the entire directory to a unique quarantine name. Never delete the only existing V4 copy automatically.
4. Create a new V4 store in a unique sibling staging directory. The bootstrap must not accept a V3 URL or open any V3 container.
5. Verify that a newly created store has no account registry or account-owned personal rows.
6. Close every SwiftData handle.
7. Run SQLite integrity_check, foreign_key_check, and read-only reopen checks on the closed staging file.
8. Revalidate ownership of the bootstrap lease.
9. Atomically rename the staging directory to the final V4 directory on the same volume.
10. On restart, repeat validation against the final V4 store before use. If it fails, quarantine and create a fresh empty V4 store.

## Legacy data and credentials

- No V3 cache, library, calendar, Update Watch, AppState, or Spark metadata is imported.
- The old V3 store remains untouched during the post-cutover observation period.
- itch OAuth credentials remain in Keychain and are not copied into SwiftData.
- The user signs in to itch again after V4 startup.
- Patreon session and credentials are not migrated; Patreon remains a separate provider identity and the user signs in again.
- Public game metadata and rebuildable caches are fetched online as needed.
- Local notes, custom events, and other non-reconstructable personal data may be lost, as explicitly accepted by the user.

## Bootstrap acceptance tests

- First launch creates an empty V4 store.
- The legacy V3 fixture remains byte-for-byte untouched and is not imported.
- A second launch reuses the valid V4 store rather than replacing it.
- An incomplete/corrupt V4 directory is quarantined, not deleted.
- A failed staging attempt never becomes the final store.
- Concurrent bootstrap attempts are excluded by the cross-process lease.
- SQLite integrity, foreign-key, and read-only reopen checks pass before promotion.
- Process interruption before promotion leaves no falsely-valid final V4 store.
- Restart after promotion validates and reuses the final store.
- OAuth and Patreon credentials never enter the V4 database or diagnostics.

## Historical conversion journal

The remaining sections in the Git history described requested/snapshotting/snapshotReady/stagingCreated/converting/verifying/manifestWritten/stagingValidated/eligibleForIndependentSafetyGates transitions. Those transitions describe the retired V3 conversion experiment only. They must not be interpreted as authorization to migrate old data or as a dependency of the new clean V4 startup.
