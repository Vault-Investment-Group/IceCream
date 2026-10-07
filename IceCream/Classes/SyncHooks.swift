//
//  SyncHooks.swift
//  IceCream
//

import CloudKit
import Foundation

/// Something the engine could not do and does not retry, or the result of a pull no caller is waiting for.
public enum SyncEvent {
    /// A push to CloudKit failed.
    case pushFailed(Error)
    /// A database-level change fetch failed.
    case databaseFetchFailed(Error)
    /// The iCloud account is not available, so the private database is not synced.
    case accountUnavailable(status: CKAccountStatus, error: Error?)
    /// Creating the custom zones failed.
    case zoneCreationFailed(Error)
    /// A pull started by a remote-change notification finished: nil when the zone fetch completed, or its error.
    case remotePullCompleted(Error?)
}

extension SyncEngine {
    /// Optional. Told about each `SyncEvent`, on an arbitrary thread. Nil by default: nothing is reported.
    public static var eventReporter: ((SyncEvent) -> Void)?

    /// Optional. Begins whatever keeps the process running while IceCream writes to Realm, for example a background task,
    /// and returns the call that ends it. IceCream calls it once per pull, or once per write outside a pull. Nil by
    /// default: nothing is held.
    public static var writeHold: ((String) -> () -> Void)?
}

/// `SyncEngine.writeHold` across IceCream's Realm writes: one hold for a whole pull, and one per write made outside a pull.
enum WriteHoldWindow {
    private static let lock = NSLock()
    private static var openWindows = 0

    /// Opens a window and returns its end, which is safe to call more than once and acts only the first time.
    static func open(_ name: String) -> () -> Void {
        let release = SyncEngine.writeHold?(name)
        lock.lock()
        openWindows += 1
        lock.unlock()
        let once = NSLock()
        var ended = false
        return {
            once.lock()
            defer { once.unlock() }
            guard !ended else { return }
            ended = true
            lock.lock()
            openWindows -= 1
            lock.unlock()
            release?()
        }
    }

    /// Runs `body`, holding for it unless a window is open.
    static func write(_ name: String, _ body: () -> Void) {
        lock.lock()
        let covered = openWindows > 0
        lock.unlock()
        let release = covered ? nil : SyncEngine.writeHold?(name)
        defer { release?() }
        body()
    }
}
