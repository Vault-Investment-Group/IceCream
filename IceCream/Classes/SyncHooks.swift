//
//  SyncHooks.swift
//  IceCream
//

import CloudKit
import Foundation

/// Something the engine could not do and does not retry, a retry it scheduled, or the result of a pull no caller is
/// waiting for.
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
    /// TV Club fork (tvclub.10): a pull will fetch again after `wait` seconds, as CloudKit's `error` asked, at the
    /// database or the zone level.
    case retryScheduled(Error, wait: Double)
    /// TV Club fork (tvclub.11): a pull reached its time limit, `SyncEngine.pullTimeLimit` seconds, and was cancelled.
    case pullTimedOut(seconds: Double)
    /// TV Club fork (tvclub.11): a pulled batch couldn't be written to Realm. Nothing of it was written, its zone's token
    /// didn't move, and the pull called back with `error`.
    case batchApplyFailed(Error)
}

extension SyncEngine {
    /// Optional. Told about each `SyncEvent`, on an arbitrary thread. Nil by default: nothing is reported.
    public static var eventReporter: ((SyncEvent) -> Void)?

    /// Optional. Begins whatever keeps the process running while IceCream writes to Realm, for example a background task,
    /// and returns the call that ends it. IceCream calls it once per pull, or once per write outside a pull. Nil by
    /// default: nothing is held.
    public static var writeHold: ((String) -> () -> Void)?

    /// Optional, for tests. An engine created while this is set keeps it and uses it in place of CloudKit: it asks it for
    /// the account status, hands it every operation it would add to the database, and resumes no long-lived operations.
    /// Nil by default: engines use CloudKit.
    public static var databaseStandIn: DatabaseStandIn?

    /// TV Club fork (tvclub.10): the most one pull's retries wait in all, in seconds. A retry whose wait would take the
    /// pull's total past it isn't made: the pull calls back with that retry's error. Ten minutes; tests set less.
    public static var retryWaitLimit: Double = 600

    /// TV Club fork (tvclub.11): the longest one pull runs, in seconds on the wall clock, so time the app spends suspended
    /// counts. When it passes, the pull cancels its operations, applies no further batch (one already being written
    /// finishes, with its token), and calls back with an error that `pullTimedOut` recognises. A stopped engine's pull
    /// ends as a plain cancellation instead. Twelve minutes: past `retryWaitLimit`, so the retries it allows can run, and short of the
    /// app's own fifteen-minute give-up. Tests set less. A pull's limit is the one set when it started.
    public static var pullTimeLimit: Double = 720

    /// TV Club fork (tvclub.11): true for the error a live engine's pull calls back with when it reached `pullTimeLimit`.
    /// It's a `CKError.operationCancelled`, so check this before reading a cancellation as a stopped engine; it's marked
    /// `failedBeforeZones` too when it ended before the zones.
    public static func pullTimedOut(_ error: Error?) -> Bool {
        guard let error = error else { return false }
        return (error as NSError).userInfo[timedOutKey] as? Bool == true
    }

    static let timedOutKey = "IceCreamPullTimedOut"

    static func timedOutError(beforeZones: Bool) -> Error {
        var userInfo: [String: Any] = [timedOutKey: true]
        if beforeZones { userInfo[beforeZonesKey] = true }
        return CKError(.operationCancelled, userInfo: userInfo)
    }

    /// TV Club fork (tvclub.10): true for a pull's error from the database level, before any zone was fetched: an error
    /// that wasn't retried, or a retry past the wait limit. Until tvclub.10 those never called back, so a caller whose
    /// work assumes a pull ran (an engine's start completion) can tell them apart. The error keeps its domain and code.
    public static func failedBeforeZones(_ error: Error?) -> Bool {
        guard let error = error else { return false }
        return (error as NSError).userInfo[beforeZonesKey] as? Bool == true
    }

    static let beforeZonesKey = "IceCreamPullFailedBeforeZones"

    /// `error`, with the same domain and code, marked as failed before the zones (`failedBeforeZones`).
    static func markedBeforeZones(_ error: Error?) -> Error? {
        guard let error = error else { return nil }
        let nsError = error as NSError
        var userInfo = nsError.userInfo
        userInfo[beforeZonesKey] = true
        if nsError.domain == CKErrorDomain {
            return CKError(CKError.Code(rawValue: nsError.code) ?? .internalError, userInfo: userInfo)
        }
        return NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
    }
}

/// Stands in for CloudKit's database (`SyncEngine.databaseStandIn`). It completes the operations it is given, or not, as
/// the test needs.
public protocol DatabaseStandIn: AnyObject {
    func accountStatus(_ completion: @escaping (CKAccountStatus, Error?) -> Void)
    func add(_ operation: CKDatabaseOperation)
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
