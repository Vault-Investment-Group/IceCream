//
//  SyncSource.swift
//  IceCream
//
//  Created by David Collado on 1/5/18.
//

import Foundation
import RealmSwift
import CloudKit

/// SyncObject is for each model you want to sync.
/// Logically,
/// 1. it takes care of the operations of CKRecordZone.
/// 2. it detects the changeSets of Realm Database and directly talks to it.
/// 3. it hands over to SyncEngine so that it can talk to CloudKit.

public final class SyncObject<T, U, V, W> where T: Object & CKRecordConvertible & CKRecordRecoverable, U: Object, V: Object, W: Object {
    
    /// Notifications are delivered as long as a reference is held to the returned notification token. We should keep a strong reference to this token on the class registering for updates, as notifications are automatically unregistered when the notification token is deallocated.
    /// For more, reference is here: https://realm.io/docs/swift/latest/#notifications
    private var notificationToken: NotificationToken?
    
    public var pipeToEngine: ((_ recordsToStore: [CKRecord], _ recordIDsToDelete: [CKRecord.ID]) -> ())?
    
    public let realmConfiguration: Realm.Configuration
    
    private let pendingUTypeRelationshipsWorker = PendingRelationshipsWorker<U>()
    private let pendingVTypeRelationshipsWorker = PendingRelationshipsWorker<V>()
    private let pendingWTypeRelationshipsWorker = PendingRelationshipsWorker<W>()
    
    public init(
        realmConfiguration: Realm.Configuration = .defaultConfiguration,
        type: T.Type,
        uListElementType: U.Type? = nil,
        vListElementType: V.Type? = nil,
        wListElementType: W.Type? = nil
    ) {
        self.realmConfiguration = realmConfiguration
    }
    
}

// MARK: - Zone information

extension SyncObject: Syncable {
    
    public var recordType: String {
        return T.recordType
    }
    
    public var zoneID: CKRecordZone.ID {
        return T.zoneID
    }
    
    public var zoneChangesToken: CKServerChangeToken? {
        get {
            /// For the very first time when launching, the token will be nil and the server will be giving everything on the Cloud to client
            /// In other situation just get the unarchive the data object
            guard let tokenData = UserDefaults.standard.object(forKey: T.className() + IceCreamKey.zoneChangesTokenKey.value) as? Data else { return nil }
            return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
        }
        set {
            guard let n = newValue else {
                UserDefaults.standard.removeObject(forKey: T.className() + IceCreamKey.zoneChangesTokenKey.value)
                return
            }
            let data = NSKeyedArchiver.archivedData(withRootObject: n)
            UserDefaults.standard.set(data, forKey: T.className() + IceCreamKey.zoneChangesTokenKey.value)
        }
    }

    public var isCustomZoneCreated: Bool {
        get {
            guard let flag = UserDefaults.standard.object(forKey: T.className() + IceCreamKey.hasCustomZoneCreatedKey.value) as? Bool else { return false }
            return flag
        }
        set {
            UserDefaults.standard.set(newValue, forKey: T.className() + IceCreamKey.hasCustomZoneCreatedKey.value)
        }
    }
    
    public func add(record: CKRecord) {
        BackgroundWorker.shared.start {
            let realm = try! Realm(configuration: self.realmConfiguration)
            guard let object = T.parseFromRecord(
                record: record,
                realm: realm,
                notificationToken: self.notificationToken,
                pendingUTypeRelationshipsWorker: self.pendingUTypeRelationshipsWorker,
                pendingVTypeRelationshipsWorker: self.pendingVTypeRelationshipsWorker,
                pendingWTypeRelationshipsWorker: self.pendingWTypeRelationshipsWorker
            ) else {
                print("There is something wrong with the converson from cloud record to local object")
                return
            }
            self.pendingUTypeRelationshipsWorker.realm = realm
            self.pendingVTypeRelationshipsWorker.realm = realm
            self.pendingWTypeRelationshipsWorker.realm = realm
            
            /// If your model class includes a primary key, you can have Realm intelligently update or add objects based off of their primary key values using Realm().add(_:update:).
            /// https://realm.io/docs/swift/latest/#objects-with-primary-keys
            WriteHoldWindow.write("IceCream add") {
                realm.beginWrite()
                realm.add(object, update: .modified)
                if let token = self.notificationToken {
                    try! realm.commitWrite(withoutNotifying: [token])
                } else {
                    try! realm.commitWrite()
                }
            }
        }
    }
    
    public func delete(recordID: CKRecord.ID) {
        BackgroundWorker.shared.start {
            let realm = try! Realm(configuration: self.realmConfiguration)
            guard let object = realm.object(ofType: T.self, forPrimaryKey: T.primaryKeyForRecordID(recordID: recordID)) else {
                // Not found in local realm database
                return
            }
            CreamAsset.deleteCreamAssetFile(with: recordID.recordName)
            WriteHoldWindow.write("IceCream delete") {
                realm.beginWrite()
                realm.delete(object)
                if let token = self.notificationToken {
                    try! realm.commitWrite(withoutNotifying: [token])
                } else {
                    try! realm.commitWrite()
                }
            }
        }
    }
    
    /// TV Club fork (tvclub.11): one CloudKit batch in one Realm write, on the background worker: every record added or
    /// updated and every deletion, in the order the pull brought them. A commit that fails is cancelled and thrown, so
    /// nothing of the batch is written; a record that doesn't convert is skipped, as `add(record:)` skips it. A deleted
    /// record's asset files go only once the write has committed.
    public func apply(_ changes: [PulledChange]) throws {
        guard !changes.isEmpty else { return }
        var failure: Error?
        BackgroundWorker.shared.start {
            let realm: Realm
            do {
                realm = try Realm(configuration: self.realmConfiguration)
            } catch {
                failure = error
                return
            }
            self.pendingUTypeRelationshipsWorker.realm = realm
            self.pendingVTypeRelationshipsWorker.realm = realm
            self.pendingWTypeRelationshipsWorker.realm = realm
            // The relationships this batch leaves pending name its own objects; a write that fails leaves them out.
            let pendingU = self.pendingUTypeRelationshipsWorker.pendingListElementPrimaryKeyValue
            let pendingV = self.pendingVTypeRelationshipsWorker.pendingListElementPrimaryKeyValue
            let pendingW = self.pendingWTypeRelationshipsWorker.pendingListElementPrimaryKeyValue
            var deletedRecordNames: [String] = []
            WriteHoldWindow.write("IceCream batch") {
                realm.beginWrite()
                for change in changes {
                    switch change {
                    case let .changed(record):
                        guard let object = T.parseFromRecord(
                            record: record,
                            realm: realm,
                            notificationToken: self.notificationToken,
                            pendingUTypeRelationshipsWorker: self.pendingUTypeRelationshipsWorker,
                            pendingVTypeRelationshipsWorker: self.pendingVTypeRelationshipsWorker,
                            pendingWTypeRelationshipsWorker: self.pendingWTypeRelationshipsWorker
                        ) else {
                            print("There is something wrong with the converson from cloud record to local object")
                            continue
                        }
                        realm.add(object, update: .modified)
                    case let .deleted(recordID):
                        guard let object = realm.object(ofType: T.self, forPrimaryKey: T.primaryKeyForRecordID(recordID: recordID)) else {
                            continue
                        }
                        realm.delete(object)
                        deletedRecordNames.append(recordID.recordName)
                    }
                }
                do {
                    if let token = self.notificationToken {
                        try realm.commitWrite(withoutNotifying: [token])
                    } else {
                        try realm.commitWrite()
                    }
                } catch {
                    if realm.isInWriteTransaction { realm.cancelWrite() }
                    failure = error
                    deletedRecordNames = []
                    self.pendingUTypeRelationshipsWorker.pendingListElementPrimaryKeyValue = pendingU
                    self.pendingVTypeRelationshipsWorker.pendingListElementPrimaryKeyValue = pendingV
                    self.pendingWTypeRelationshipsWorker.pendingListElementPrimaryKeyValue = pendingW
                }
            }
            deletedRecordNames.forEach { CreamAsset.deleteCreamAssetFile(with: $0) }
        }
        if let failure = failure { throw failure }
    }
    
    /// When you commit a write transaction to a Realm, all other instances of that Realm will be notified, and be updated automatically.
    /// For more: https://realm.io/docs/swift/latest/#writes
    public func registerLocalDatabase() {
        BackgroundWorker.shared.start {
            let realm = try! Realm(configuration: self.realmConfiguration)
            self.notificationToken = realm.objects(T.self).observe({ [weak self](changes) in
                guard let self = self else { return }
                switch changes {
                case .initial(_):
                    break
                case .update(let collection, _, let insertions, let modifications):
                    let recordsToStore = (insertions + modifications).filter { $0 < collection.count }.map { collection[$0] }.filter{ !$0.isDeleted }.map { $0.record }
                    let recordIDsToDelete = modifications.filter { $0 < collection.count }.map { collection[$0] }.filter { $0.isDeleted }.map { $0.recordID }
                    
                    guard recordsToStore.count > 0 || recordIDsToDelete.count > 0 else { return }
                    self.pipeToEngine?(recordsToStore, recordIDsToDelete)
                case .error(_):
                    break
                }
            })
        }
    }
    
    public func resolvePendingRelationships() {
        pendingUTypeRelationshipsWorker.resolvePendingListElements()
        pendingVTypeRelationshipsWorker.resolvePendingListElements()
        pendingWTypeRelationshipsWorker.resolvePendingListElements()
    }
    
    public func cleanUp() {
        BackgroundWorker.shared.start {
            let realm = try! Realm(configuration: self.realmConfiguration)
            let objects = realm.objects(T.self).filter { $0.isDeleted }
            
            var tokens: [NotificationToken] = []
            self.notificationToken.flatMap { tokens = [$0] }
            
            WriteHoldWindow.write("IceCream clean up") {
                realm.beginWrite()
                objects.forEach({ realm.delete($0) })
                do {
                    try realm.commitWrite(withoutNotifying: tokens)
                } catch {
                    
                }
            }
        }
    }
    
    public func pushLocalObjectsToCloudKit() {
        let realm = try! Realm(configuration: self.realmConfiguration)
        let recordsToStore: [CKRecord] = realm.objects(T.self).filter { !$0.isDeleted }.map { $0.record }
        pipeToEngine?(recordsToStore, [])
    }
    
}

