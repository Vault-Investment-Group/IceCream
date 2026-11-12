//
//  Syncable.swift
//  IceCream
//
//  Created by 蔡越 on 24/05/2018.
//

import Foundation
import CloudKit
import RealmSwift

/// Since `sync` is an informal version of `synchronize`, so we choose the `syncable` word for
/// the ability of synchronization.
public protocol Syncable: class {
    
    /// CKRecordZone related
    var recordType: String { get }
    var zoneID: CKRecordZone.ID { get }
    
    /// Local storage
    var zoneChangesToken: CKServerChangeToken? { get set }
    var isCustomZoneCreated: Bool { get set }
    
    /// Realm Database related
    func registerLocalDatabase()
    func cleanUp()
    func add(record: CKRecord)
    func delete(recordID: CKRecord.ID)
    
    /// TV Club fork (tvclub.11): applies one CloudKit batch of this object's zone, in order. `SyncObject` applies it in one
    /// Realm write: all of it, or none of it when it throws. A pull moves the zone's token only after this returns, and not
    /// when it throws. A conformer without its own gets the default below, one write per change.
    func apply(_ changes: [PulledChange]) throws
    
    func resolvePendingRelationships()
    
    /// CloudKit related
    func pushLocalObjectsToCloudKit()
    
    /// Callback
    var pipeToEngine: ((_ recordsToStore: [CKRecord], _ recordIDsToDelete: [CKRecord.ID]) -> ())? { get set }
    
}

/// TV Club fork (tvclub.11): one change a pull brings for a sync object's zone.
public enum PulledChange {
    /// A record added or changed on the server.
    case changed(CKRecord)
    /// A record deleted on the server.
    case deleted(CKRecord.ID)
}

extension Syncable {
    /// A sync object that doesn't apply a batch itself applies it one change at a time, in order, as before tvclub.11: each
    /// change in its own write, so it isn't all-or-nothing.
    public func apply(_ changes: [PulledChange]) throws {
        for change in changes {
            switch change {
            case let .changed(record): add(record: record)
            case let .deleted(recordID): delete(recordID: recordID)
            }
        }
    }
}
