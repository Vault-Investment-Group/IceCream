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
    
    public init(objects: [Syncable], container: CKContainer) {
        self.syncObjects = objects
        self.container = container
        self.database = container.privateCloudDatabase
    }
    
    func fetchChangesInDatabase(_ callback: ((Error?) -> Void)?) {
        fetchChangesInDatabase(pull: PullCallback(callback))
    }
    
    /// TV Club fork (tvclub.10): every path calls `pull` back, once. A retry is reported and counts toward the pull's wait
    /// limit; an error that isn't retried is reported and called back.
    private func fetchChangesInDatabase(pull: PullCallback) {
        let changesOperation = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeToken)
        
        /// Only update the changeToken when fetch process completes
        changesOperation.changeTokenUpdatedBlock = { [weak self] newToken in
            self?.databaseChangeToken = newToken
        }
        
        changesOperation.fetchDatabaseChangesCompletionBlock = {
            [weak self]
            newToken, _, error in
            guard let self = self else {
                pull.finish(error ?? CKError(.operationCancelled))
                return
            }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                self.databaseChangeToken = newToken
                // Fetch the changes in zone level
                self.fetchChangesInZones(pull)
            case .retry(let timeToWait, _):
                self.retry(after: timeToWait, error: error, pull: pull) {
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
                    pull.finish(error)
                }
            default:
                if let error = error { SyncEngine.eventReporter?(.databaseFetchFailed(error)) }
                pull.finish(error)
            }
        }
        
        operationRegistry.register(changesOperation)
        // A registration after stop() is cancelled on the spot, and an operation that finishes without executing is not
        // promised to run its completion block, so the pull calls back here. It calls back once either way.
        if changesOperation.isCancelled { pull.finish(CKError(.operationCancelled)) }
        submit(changesOperation)
    }
    
    /// TV Club fork (tvclub.10): reports the retry and schedules it, or, when its wait would take the pull's total past
    /// `SyncEngine.retryWaitLimit`, calls the pull back with `error` and doesn't retry.
    private func retry(after wait: Double, error: Error?, pull: PullCallback, _ block: @escaping () -> Void) {
        guard pull.addWait(wait) else {
            pull.finish(error)
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
    private func fetchChangesInZones(_ pull: PullCallback) {
        let changesOp = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIds, optionsByRecordZoneID: zoneIdOptions)
        changesOp.fetchAllChanges = true
        let fetchAgain = ZoneFetchAgain()
        
        changesOp.recordZoneChangeTokensUpdatedBlock = { [weak self] zoneId, token, _ in
            guard let self = self else { return }
            guard let syncObject = self.syncObjects.first(where: { $0.zoneID == zoneId }) else { return }
            syncObject.zoneChangesToken = token
        }
        
        changesOp.recordChangedBlock = { [weak self] record in
            /// The Cloud will return the modified record since the last zoneChangesToken, we need to do local cache here.
            /// Handle the record:
            guard let self = self else { return }
            guard let syncObject = self.syncObjects.first(where: { $0.recordType == record.recordType }) else { return }
            syncObject.add(record: record)
        }
        
        changesOp.recordWithIDWasDeletedBlock = { [weak self] recordId, _ in
            guard let self = self else { return }
            guard let syncObject = self.syncObjects.first(where: { $0.zoneID == recordId.zoneID }) else { return }
            syncObject.delete(recordID: recordId)
        }
        
        changesOp.recordZoneFetchCompletionBlock = { [weak self](zoneId ,token, _, _, error) in
            guard let self = self else { return }
            switch ErrorHandler.shared.resultType(with: error) {
            case .success:
                guard let syncObject = self.syncObjects.first(where: { $0.zoneID == zoneId }) else { return }
                syncObject.zoneChangesToken = token
            case .retry(let timeToWait, _):
                fetchAgain.retry(after: timeToWait, error: error)
            case .recoverableError(let reason, _):
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
                return
            }
        }
        
        // One write hold for the whole pull: every record's write (each runs synchronously on BackgroundWorker) and the
        // pending relationships are done when this completion runs, which it does on success, error and cancellation.
        let endWriteHold = WriteHoldWindow.open("IceCream pull")
        changesOp.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
            guard let self = self else {
                endWriteHold()
                pull.finish(error ?? CKError(.operationCancelled))
                return
            }
            self.syncObjects.forEach {
                $0.resolvePendingRelationships()
            }
            endWriteHold()
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
        // A registration after stop() is cancelled on the spot, and an operation that finishes without executing is not
        // promised to run its completion block, so the window closes here. The close acts once either way, and so does
        // the pull's callback.
        if changesOp.isCancelled {
            endWriteHold()
            pull.finish(CKError(.operationCancelled))
        }
        submit(changesOp)
    }
}

/// TV Club fork (tvclub.10): one pull's callback, called once whatever the path, and the total its retries have waited.
final class PullCallback {
    private let lock = NSLock()
    private var callback: ((Error?) -> Void)?
    private var finished = false
    private var waited: Double = 0
    
    init(_ callback: ((Error?) -> Void)?) {
        self.callback = callback
    }
    
    /// Calls back with `error` the first time, and does nothing after.
    func finish(_ error: Error?) {
        lock.lock()
        let pending = finished ? nil : callback
        finished = true
        callback = nil
        lock.unlock()
        pending?(error)
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
