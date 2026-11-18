# V4 journal and staging lifecycle coordination

The lifecycle coordinator commits stagingStoreID in the migration journal before creating a staging directory. It advances the journal through requested → snapshotting → snapshotReady → stagingCreated. A failure attempts to remove only the directory identified by that recorded runID/stagingStoreID pair and records a terminal failed state.

## Cross-process migration ownership

Both snapshot creation and interrupted-attempt recovery acquire the same persistent lock-file URL through V4MigrationOwnerLock before touching journal or staging state. The lock uses the operating system's exclusive advisory flock, not actor isolation or an in-memory Boolean. Separate processes opening the same lock file contend on the same kernel lock; the kernel releases the descriptor lock when a process exits or crashes.

The lock file must live in a stable control directory, be shared by every migration entry point, and must never be deleted or replaced while the application may be running. A busy lock fails closed with alreadyHeld; callers must not proceed with migration or recovery. The lock is held across asynchronous journal operations and staging filesystem work.

This is an advisory lock: every writer/recovery path must use it. It does not protect against unrelated code that bypasses the coordinator and writes the journal or staging root directly.

## Interrupted-attempt recovery

recoverInterruptedSnapshotAttempts handles only requested, snapshotting, and snapshotReady attempts. It discards the recorded staging directory if present and transitions that attempt to failed. A new attempt must use a new runID, idempotency key, and stagingStoreID. Successfully created staging stores are preserved for the next migration phase.

This slice does not run Library/AppState conversion, verify payload parity, promote a production store, or change app startup. V3 remains authoritative.


## Journal write serialization and freshness

Journal creation and state transitions acquire the same persistent owner lock used by snapshot creation and recovery. When a caller already holds the end-to-end migration lease, it passes that exact lease to each journal write so the repository does not attempt a nested lock acquisition. Standalone repository writes acquire and release the configured lock around their own read-modify-write operation.

Every mutation reloads and validates the latest on-disk journal snapshot after ownership is established, then applies the idempotency/state compare-and-swap checks and atomically replaces the file. This is required because Swift actor isolation serializes only one repository instance; it cannot prevent another actor or process from changing the file. Read operations also reload the current file instead of trusting a process-local cached snapshot.

The lock serializes cooperative writers, while atomic replacement keeps the record/event snapshot together. This does not claim stronger power-loss durability than the underlying filesystem write operation.
