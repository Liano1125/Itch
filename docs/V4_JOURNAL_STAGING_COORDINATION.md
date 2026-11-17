# V4 journal and staging lifecycle coordination

The lifecycle coordinator commits stagingStoreID in the migration journal before creating a staging directory. It advances the journal through requested → snapshotting → snapshotReady → stagingCreated. A failure attempts to remove only the directory identified by that recorded runID/stagingStoreID pair and records a terminal failed state.

## Interrupted-attempt recovery

recoverInterruptedSnapshotAttempts handles only requested, snapshotting, and snapshotReady attempts. It discards the recorded staging directory if present and transitions that attempt to failed. A new attempt must use a new runID, idempotency key, and stagingStoreID. Successfully created staging stores are preserved for the next migration phase.

Recovery must run only after the application has acquired an exclusive migration-owner lock and established that no other process or task is writing the journal or staging root. The journal repository actor serializes calls only within one instance; it is not a cross-process lock.

This slice does not run Library/AppState conversion, verify payload parity, promote a production store, or change app startup. V3 remains authoritative.