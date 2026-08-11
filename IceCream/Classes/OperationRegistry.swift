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
//  in flight BEFORE the engine reference is dropped. The next engine's resume pass then
//  finds nothing running.
//

import CloudKit
import Foundation

/// Weakly tracks the CKOperations a database manager has added, so teardown can cancel
/// what is still in flight. Thread-safe: operations are added from CloudKit callback
/// queues and cancelled from wherever the app tears the engine down.
public final class OperationRegistry {

    private let lock = NSLock()
    private let operations = NSHashTable<CKOperation>.weakObjects()

    public init() {}

    public func register(_ operation: CKOperation) {
        lock.lock()
        defer { lock.unlock() }
        operations.add(operation)
    }

    /// Cancels every tracked operation that is still alive and clears the table.
    /// Cancelling an already-finished operation is a documented no-op, so this is safe
    /// to call regardless of how much of the queue has drained.
    public func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
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
