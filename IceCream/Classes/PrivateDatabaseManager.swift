//
//  PrivateDatabaseManager.swift
//  IceCream
//
//  Created by caiyue on 2019/4/22.
//

#if os(macOS)
import Cocoa
#else
import UIKit
#endif

import CloudKit

final class PrivateDatabaseManager: DatabaseManager {
    
    let container: CKContainer
    let database: CKDatabase
    
    let syncObjects: [Syncable]
    let operationRegistry = OperationRegistry()
    let databaseStandIn = SyncEngine.databaseStandIn
    
    /// TV Club fork (tvclub.11): the pull in flight, or the last one. A request while it's in flight joins it.
    private let pullLock = NSLock()
    private var currentPull: PullCallback?
    
    public init(objects: [Syncable], container: CKContainer) {
        self.syncObjects = objects
        self.container = container
        self.database = container.privateCloudDatabase
    }
    
    /// TV Club fork (tvclub.11): one pull at a time. A request while a pull is in flight (the start's, a remote change's,
    /// the app's) joins it and is called back with its result, once. Otherwise it starts a pull, which ends by
    /// `SyncEngine.pullTimeLimit` on the wall clock: when the limit passes first, the pull cancels its operations, applies
    /// nothing more, and calls back with `SyncEngine.pullTimedOut`'s error.
    func fetchChangesInDatabase(_ callback: ((Error?) -> Void)?) {
        pullLock.lock()
        if let current = currentPull, current.join(callback) {
            pullLock.unlock()
            return
        }
        let pull = PullCallback(callback)
        currentPull = pull
        pullLock.unlock()
        let limit = SyncEngine.pullTimeLimit
        DispatchQueue.global(qos: .utility).asyncAfter(wallDeadline: .now() + limit) { [weak pull] in
            guard let pull = pull, pull.timeOut() else { return }
            SyncEngine.eventReporter?(.pullTimedOut(seconds: limit))
        }
        fetchChangesInDatabase(pull: pull)
    }
    
    /// TV Club fork (tvclub.10): every path calls `pull` back, once. A retry is reported and counts toward the pull's wait
    /// limit; an error that isn't retried is reported and called back.
    private func fetchChangesInDatabase(pull: PullCallback) {
        // tvclub.11: a pull that has ended (its time limit) fetches nothing more, a retry scheduled before it ended included.
        guard !pull.isFinished else { return }
        let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeToken)
        
        /// Only update the changeToken when fetch process completes
        changesOperation.changeTokenUpdatedBlock = { [weak self] newToken in
            self?.databaseChangeToken = newToken
        }
        
        changesOperation.fetchDatabaseChangesCompletionBlock = {
            [weak self]
            newToken, _, error in
            // The manager is gone, so the engine was torn down: a cancellation, whatever the operation's own error.
            guard let self = self else {
                pull.finish(CKError(.operationCancelled))
                return
            }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.databaseChangeToken = newToken
                // Fetch the changes in zone level
                self.fetchChangesInZones(pull)
            case .retry(let timeToWait, _):
                self.retry(after: timeToWait, error: error, pull: pull, beforeZones: true) {
                    self.fetchChangesInDatabase(pull: pull)
                }
            case .recoverableError(let reason, _):
                switch reason {
                case .changeTokenExpired:
                    /// The previousServerChangeToken value is too old and the client must re-sync from scratch
                    self.databaseChangeToken = nil
                    self.fetchChangesInDatabase(pull: pull)
                default:
                    if let error = error { SyncEngine.eventReporter?(.databaseFetchFailed(error)) }
                    pull.finish(SyncEngine.markedBeforeZones(error))
                }
            default:
                if let error = error { SyncEngine.eventReporter?(.databaseFetchFailed(error)) }
                pull.finish(SyncEngine.markedBeforeZones(error))
            }
        }
        
        operationRegistry.register(changesOperation)
        pull.track(changesOperation)
        // A registration after stop() is cancelled on the spot, and an operation that finishes without executing is not
        // promised to run its completion block, so the pull calls back here. It calls back once either way.
        if changesOperation.isCancelled { pull.finish(CKError(.operationCancelled)) }
        submit(changesOperation)
        // And a stop() between the check and the submit.
        if changesOperation.isCancelled { pull.finish(CKError(.operationCancelled)) }
    }
    
    /// TV Club fork (tvclub.10): reports the retry and schedules it, or, when its wait would take the pull's total past
    /// `SyncEngine.retryWaitLimit`, calls the pull back with `error` and doesn't retry. A database-level give-up is marked
    /// as one (`SyncEngine.failedBeforeZones`).
    private func retry(after wait: Double, error: Error?, pull: PullCallback, beforeZones: Bool = false, _ block: @escaping () -> Void) {
        guard pull.addWait(wait) else {
            pull.finish(beforeZones ? SyncEngine.markedBeforeZones(error) : error)
            return
        }
        if let error = error { SyncEngine.eventReporter?(.retryScheduled(error, wait: wait)) }
        ErrorHandler.shared.retryOperationIfPossible(retryAfter: wait, block: block)
    }
    
    func createCustomZonesIfAllowed() {
        // TV Club fork (tvclub.9): only the objects whose zones this operation creates are marked and pushed below, so
        // adding a type to an engine whose other zones exist pushes that type's rows alone, not every type's library.
        let objectsToCreate = syncObjects.filter { !$0.isCustomZoneCreated }
        let zonesToCreate = objectsToCreate.map { CKRecordZone(zoneID: $0.zoneID) }
        guard zonesToCreate.count > 0 else { return }
        
        let modifyOp = CKModifyRecordZonesOperation(recordZonesToSave: zonesToCreate, recordZoneIDsToDelete: nil)
        modifyOp.modifyRecordZonesCompletionBlock = { [weak self](_, _, error) in
            guard let self = self else { return }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                objectsToCreate.forEach { object in
                    object.isCustomZoneCreated = true
                    
                    // As we register local database in the first step, we have to force push local objects which
                    // have not been caught to CloudKit to make data in sync
                    DispatchQueue.main.async {
                        object.pushLocalObjectsToCloudKit()
                    }
                }
            case .retry(let timeToWait, _):
                ErrorHandler.shared.retryOperationIfPossible(retryAfter: timeToWait, block: {
                    self.createCustomZonesIfAllowed()
                })
            default:
                if let error = error { SyncEngine.eventReporter?(.zoneCreationFailed(error)) }
                return
            }
        }
        
        operationRegistry.register(modifyOp)
        submit(modifyOp)
    }
    
    func createDatabaseSubscriptionIfHaveNot() {
        #if os(iOS) || os(tvOS) || os(macOS)
        guard !subscriptionIsLocallyCached else { return }
        let subscription = CKDatabaseSubscription(subscriptionID: IceCreamSubscription.cloudKitPrivateDatabaseSubscriptionID.id)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // Silent Push
        
        subscription.notificationInfo = notificationInfo
        
        let createOp = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
        createOp.modifySubscriptionsCompletionBlock = { _, _, error in
            guard error == nil else { return }
            self.subscriptionIsLocallyCached = true
        }
        createOp.qualityOfService = .utility
        operationRegistry.register(createOp)
        submit(createOp)
        #endif
    }
    
    func startObservingTermination() {
        #if os(iOS) || os(tvOS)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: UIApplication.willTerminateNotification, object: nil)
        
        #elseif os(macOS)
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.cleanUp), name: NSApplication.willTerminateNotification, object: nil)
        
        #endif
    }
    
    func registerLocalDatabase() {
        self.syncObjects.forEach { object in
            DispatchQueue.main.async {
                object.registerLocalDatabase()
            }
        }
    }
    
    /// TV Club fork (tvclub.10): a zone's retry or token reset doesn't fetch again from inside this operation, whose own
    /// completion would call back too. The operation's completion fetches again once, after the longest wait asked for, or
    /// calls `pull` back.
    ///
    /// tvclub.11: a zone's changes are held until CloudKit ends their batch (a new zone token, or the zone's end), then
    /// applied in one write (`Syncable.apply`), and only then does the zone's token move. A batch the operation doesn't
    /// end (an error, a cancellation, the time limit) is dropped unapplied, its token unmoved, so the next pull fetches it
    /// again. A batch that fails to apply ends the pull with its error.
    private func fetchChangesInZones(_ pull: PullCallback) {
        guard !pull.isFinished else { return }
        pull.reachedZones()
        let changesOp = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIds, optionsByRecordZoneID: zoneIdOptions)
        changesOp.fetchAllChanges = true
        let fetchAgain = ZoneFetchAgain()
        let batches = ZoneBatches()
        
        /// Applies the zone's held batch, then moves its token. Not when the pull has ended, and not when the apply fails:
        /// that ends the pull and cancels the operation.
        let endBatch: (CKRecordZone.ID, CKServerChangeToken?) -> Void = { [weak self, weak changesOp] zoneId, token in
            let changes = batches.take(zoneId)
            guard let self = self, !pull.isFinished else { return }
            guard let syncObject = self.syncObjects.first(where: { $0.zoneID == zoneId }) else { return }
            do {
                try syncObject.apply(changes)
            } catch {
                SyncEngine.eventReporter?(.batchApplyFailed(error))
                pull.finish(error)
                changesOp?.cancel()
                return
            }
            syncObject.zoneChangesToken = token
        }
        
        changesOp.recordZoneChangeTokensUpdatedBlock = { zoneId, token, _ in
            endBatch(zoneId, token)
        }
        
        changesOp.recordChangedBlock = { [weak self] record in
            /// The Cloud will return the modified record since the last zoneChangesToken, we need to do local cache here.
            /// Handle the record:
            guard let self = self else { return }
            guard let syncObject = self.syncObjects.first(where: { $0.recordType == record.recordType }) else { return }
            batches.add(.changed(record), zone: syncObject.zoneID)
        }
        
        changesOp.recordWithIDWasDeletedBlock = { [weak self] recordId, _ in
            guard let self = self else { return }
            guard self.syncObjects.contains(where: { $0.zoneID == recordId.zoneID }) else { return }
            batches.add(.deleted(recordId), zone: recordId.zoneID)
        }
        
        changesOp.recordZoneFetchCompletionBlock = { [weak self](zoneId ,token, _, _, error) in
            guard let self = self else { return }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                endBatch(zoneId, token)
            case .retry(let timeToWait, _):
                batches.drop(zoneId)
                fetchAgain.retry(after: timeToWait, error: error)
            case .recoverableError(let reason, _):
                batches.drop(zoneId)
                switch reason {
                case .changeTokenExpired:
                    /// The previousServerChangeToken value is too old and the client must re-sync from scratch
                    guard let syncObject = self.syncObjects.first(where: { $0.zoneID == zoneId }) else { return }
                    syncObject.zoneChangesToken = nil
                    fetchAgain.now()
                default:
                    return
                }
            default:
                batches.drop(zoneId)
                return
            }
        }
        
        // One write hold for the whole pull: every record's write (each runs synchronously on BackgroundWorker) and the
        // pending relationships are done when this completion runs, which it does on success, error and cancellation.
        let endWriteHold = WriteHoldWindow.open("IceCream pull")
        changesOp.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
            // A batch no zone ended is never applied.
            batches.dropAll()
            guard let self = self else {
                endWriteHold()
                pull.finish(CKError(.operationCancelled))
                return
            }
            self.syncObjects.forEach {
                $0.resolvePendingRelationships()
            }
            endWriteHold()
            // Cancelled (stop()): no zone fetches again.
            if let ckError = error as? CKError, ckError.code == .operationCancelled {
                pull.finish(error)
                return
            }
            switch fetchAgain.asked {
            case .none:
                pull.finish(error)
            case .now:
                self.fetchChangesInZones(pull)
            case let .after(wait, retryError):
                self.retry(after: wait, error: retryError, pull: pull) {
                    self.fetchChangesInZones(pull)
                }
            }
        }
        
        operationRegistry.register(changesOp)
        pull.track(changesOp)
        // A registration after stop() is cancelled on the spot, and an operation that finishes without executing is not
        // promised to run its completion block, so the window closes here. The close acts once either way, and so does
        // the pull's callback.
        if changesOp.isCancelled {
            endWriteHold()
            pull.finish(CKError(.operationCancelled))
        }
        submit(changesOp)
        // And a stop() between the check and the submit. The window stays for the completion: records may still be
        // applying.
        if changesOp.isCancelled { pull.finish(CKError(.operationCancelled)) }
    }
}

/// TV Club fork (tvclub.10): one pull's callback, called once whatever the path, and the total its retries have waited.
/// tvclub.11: every request that joined the pull is called back, once, with its result; and the pull keeps its operations,
/// so its time limit can cancel them.
final class PullCallback {
    private let lock = NSLock()
    private var callbacks: [(Error?) -> Void] = []
    private var finished = false
    private var waited: Double = 0
    private var zonesReached = false
    private let operations = NSHashTable<CKOperation>.weakObjects()
    
    init(_ callback: ((Error?) -> Void)?) {
        if let callback = callback { callbacks = [callback] }
    }
    
    /// Whether the pull has called back.
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
    
    /// Adds `callback` to the pull in flight and returns true, or returns false when the pull has called back.
    func join(_ callback: ((Error?) -> Void)?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        if let callback = callback { callbacks.append(callback) }
        return true
    }
    
    /// Calls everyone back with `error` the first time, and does nothing after.
    func finish(_ error: Error?) {
        lock.lock()
        let pending = finished ? [] : callbacks
        finished = true
        callbacks = []
        lock.unlock()
        pending.forEach { $0(error) }
    }
    
    /// Adds a retry's wait to the pull's total, unless it would take the total past `SyncEngine.retryWaitLimit`: then it
    /// adds nothing and returns false.
    func addWait(_ wait: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard waited + wait <= SyncEngine.retryWaitLimit else { return false }
        waited += wait
        return true
    }
    
    /// Keeps `operation` for the time limit, or cancels it when the pull has called back.
    func track(_ operation: CKOperation) {
        lock.lock()
        let ended = finished
        if !ended { operations.add(operation) }
        lock.unlock()
        if ended { operation.cancel() }
    }
    
    /// The pull has reached the zones.
    func reachedZones() {
        lock.lock()
        zonesReached = true
        lock.unlock()
    }
    
    /// The time limit: when the pull hasn't called back, calls back with `SyncEngine.pullTimedOut`'s error, cancels its
    /// operations, and returns true.
    func timeOut() -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        let beforeZones = !zonesReached
        let running = operations.allObjects
        operations.removeAllObjects()
        lock.unlock()
        finish(SyncEngine.timedOutError(beforeZones: beforeZones))
        running.forEach { $0.cancel() }
        return true
    }
}

/// TV Club fork (tvclub.11): the changes a zone-changes operation has brought for each zone since its last batch ended.
final class ZoneBatches {
    private let lock = NSLock()
    private var held: [CKRecordZone.ID: [PulledChange]] = [:]
    
    func add(_ change: PulledChange, zone: CKRecordZone.ID) {
        lock.lock()
        defer { lock.unlock() }
        held[zone, default: []].append(change)
    }
    
    /// The zone's held changes, which are no longer held.
    func take(_ zone: CKRecordZone.ID) -> [PulledChange] {
        lock.lock()
        defer { lock.unlock() }
        return held.removeValue(forKey: zone) ?? []
    }
    
    func drop(_ zone: CKRecordZone.ID) {
        _ = take(zone)
    }
    
    func dropAll() {
        lock.lock()
        defer { lock.unlock() }
        held = [:]
    }
}

/// TV Club fork (tvclub.10): what one zone-changes operation's zones asked for: nothing, to fetch again at once (a token
/// reset), or to fetch again after a wait (a retry; the longest wait asked for, with its error).
final class ZoneFetchAgain {
    enum Ask {
        case none
        case now
        case after(Double, Error?)
    }
    
    private let lock = NSLock()
    private var ask = Ask.none
    
    var asked: Ask {
        lock.lock()
        defer { lock.unlock() }
        return ask
    }
    
    func now() {
        lock.lock()
        defer { lock.unlock() }
        if case .none = ask { ask = .now }
    }
    
    func retry(after wait: Double, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if case let .after(longest, _) = ask, longest >= wait { return }
        ask = .after(wait, error)
    }
}

extension PrivateDatabaseManager {
    /// The changes token, for more please reference to https://developer.apple.com/videos/play/wwdc2016/231/
    var databaseChangeToken: CKServerChangeToken? {
        get {
            /// For the very first time when launching, the token will be nil and the server will be giving everything on the Cloud to client
            /// In other situation just get the unarchive the data object
            guard let tokenData = UserDefaults.standard.object(forKey: IceCreamKey.databaseChangesTokenKey.value) as? Data else { return nil }
            return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
        }
        set {
            guard let n = newValue else {
                UserDefaults.standard.removeObject(forKey: IceCreamKey.databaseChangesTokenKey.value)
                return
            }
            let data = NSKeyedArchiver.archivedData(withRootObject: n)
            UserDefaults.standard.set(data, forKey: IceCreamKey.databaseChangesTokenKey.value)
        }
    }
    
    var subscriptionIsLocallyCached: Bool {
        get {
            guard let flag = UserDefaults.standard.object(forKey: IceCreamKey.subscriptionIsLocallyCachedKey.value) as? Bool  else { return false }
            return flag
        }
        set {
            UserDefaults.standard.set(newValue, forKey: IceCreamKey.subscriptionIsLocallyCachedKey.value)
        }
    }
    
    private var zoneIds: [CKRecordZone.ID] {
        return syncObjects.map { $0.zoneID }
    }
    
    private var zoneIdOptions: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions] {
        return syncObjects.reduce([CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions]()) { (dict, syncObject) -> [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions] in
            var dict = dict
            let zoneChangesOptions = CKFetchRecordZoneChangesOperation.ZoneOptions()
            zoneChangesOptions.previousServerChangeToken = syncObject.zoneChangesToken
            dict[syncObject.zoneID] = zoneChangesOptions
            return dict
        }
    }
    
    @objc func cleanUp() {
        for syncObject in syncObjects {
            syncObject.cleanUp()
        }
    }
}
