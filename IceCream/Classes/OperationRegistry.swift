//
//  OperationRegistry.swift
//  IceCream
//
//  TV Club fork (2.0.4-tvclub.5): teardown cancellation for A4.
//
//  Every SyncEngine start resumes ALL long-lived operations registered with the container
//  (resumeLongLivedOperationIfPossible), and every push is registered long-lived. Two engines
//  created in quick succession therefore run two resume passes over the same daemon-side
//  registry and add the same operation identity twice — CloudKit throws
//  "Long-lived operation <id> attempted to start, but another instance of it is already
//  running" on its private container queue, uncaught, SIGABRT.
//
//  The fix: every operation a DatabaseManager adds is registered here (weakly — completed
//  operations fall out on their own), and SyncEngine.stop() cancels whatever is still
//  in flight BEFORE the engine reference is dropped. After stop(), the registry is
//  LATCHED: a registration arriving late (a retry backoff firing post-teardown, a setup
//  callback completing across the stop) is cancelled at registration, so an
//  alive-but-stopped manager cannot launch new work — the Tier-A review found exactly
//  those windows open in the latch-less first version.
//
//  HONEST LIMIT, stated: what code can guarantee is that in-process operations are
//  cancelled or refused at registration. That cancellation clears the DAEMON-side
//  long-lived registration, and that a stop→start cycle faster than the cancellation
//  round-trip cannot still collide, are CloudKit's semantics — narrowed by this fix,
//  verified on-device by the entitlement-cycling procedure that produced the crash,
//  not provable from here.
//

import CloudKit
import Foundation

/// Weakly tracks the CKOperations a database manager has added, so teardown can cancel
/// what is still in flight. Thread-safe: operations are added from CloudKit callback
/// queues and cancelled from wherever the app tears the engine down.
public final class OperationRegistry {

    private let lock = NSLock()
    private let operations = NSHashTable<CKOperation>.weakObjects()
    private var isStopped = false

    public init() {}

    public func register(_ operation: CKOperation) {
        lock.lock()
        defer { lock.unlock() }
        // THE LATCH: once stopped, a late registration is cancelled on the spot — the
        // registration sites all register BEFORE database.add, and adding an
        // already-cancelled NSOperation finishes it without executing. This is what
        // closes the post-stop escape paths (retry backoffs, setup callbacks completing
        // across the stop) that a drain-only cancelAll left open.
        if isStopped {
            operation.cancel()
            return
        }
        operations.add(operation)
    }

    /// Cancels every tracked operation that is still alive, clears the table, and
    /// LATCHES the registry: registrations arriving after this point are cancelled at
    /// registration rather than tracked. Cancelling an already-finished operation is a
    /// documented no-op, so this is safe regardless of how much of the queue has drained.
    public func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        isStopped = true
        for operation in operations.allObjects {
            operation.cancel()
        }
        operations.removeAllObjects()
    }

    /// The number of still-alive tracked operations (weak table: finished operations
    /// disappear on their own). Exposed for the app's tests.
    public var trackedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return operations.allObjects.count
    }
}
