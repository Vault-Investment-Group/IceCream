//
//  BackgroundWorker.swift
//  IceCream
//
//  Created by Kit Forge on 5/9/19.
//

import Foundation
import RealmSwift

// Based on https://academy.realm.io/posts/realm-notifications-on-background-threads-with-swift/
// Tweaked a little by Yue Cai

/// Carries the closure across `perform(_:on:with:waitUntilDone:modes:)`'s `with:` argument.
///
/// The argument slot was already there and already unused (`with: nil`). Using it is what lets
/// `BackgroundWorker` hold NO mutable state: the block travels with the message instead of being
/// parked in a property that every caller thread writes.
private final class BackgroundWorkerBlock: NSObject {
    let block: () -> Void

    init(_ block: @escaping () -> Void) {
        self.block = block
    }
}

/// A single background thread running a runloop, used to hop Realm work off the caller's thread.
///
/// **This class deliberately has no mutable state.** It used to have two `var`s and both raced:
///
///  * `private var block: (() -> Void)?` — `start()` wrote it unsynchronised and `runBlock()` read
///    it on the worker thread. `SyncObject.add(record:)` calls `start()` for every CloudKit record
///    change and CloudKit delivers those concurrently, so N threads wrote one closure property.
///    That is a non-atomic retain/release on a shared reference: it over-releases and corrupts the
///    heap. Apple's Organizer caught it directly on 4.36.7 —
///    `objc_object::sidetable_release` → `performDealloc` under
///    `BackgroundWorker.start(_:)` ← `SyncObject.add(record:)` ←
///    `PrivateDatabaseManager.fetchChangesInZones(_:)`. It also loses work: a caller's block can be
///    overwritten before `runBlock` runs, so one block executes twice and another never executes.
///  * `private var thread: Thread?` — `if thread == nil { … }` is check-then-act. Two callers could
///    both see nil, both build and start a Thread, and the loser's thread would spin a runloop
///    forever with nothing able to reach it.
///
/// Both are ELIMINATED rather than locked. A lock would have worked — no `start()` call site is
/// reachable from the worker thread, so a non-recursive lock could not deadlock — but it leaves the
/// shared state in place for the next edit to get wrong.
class BackgroundWorker: NSObject {

    static let shared = BackgroundWorker()

    private let thread: Thread

    /// Whether the worker thread has exited. Test-facing: a suite that leaves a runloop thread
    /// alive leaks it into every later test.
    var isThreadFinished: Bool { thread.isFinished }

    override init() {
        // Nothing is captured. Inside the body `Thread.current` IS this thread, so the cancellation
        // check needs neither `self` nor the property being initialised.
        thread = Thread {
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: Date.distantFuture)
            }
            Thread.exit()
        }
        super.init()
        thread.name = "IceCream.BackgroundWorker-\(UUID().uuidString)"
        thread.start()
    }

    func start(_ block: @escaping () -> Void) {
        perform(#selector(runBlock(_:)),
                on: thread,
                with: BackgroundWorkerBlock(block),
                waitUntilDone: true,
                modes: [RunLoop.Mode.default.rawValue])
    }

    /// NOTE: this only sets the cancellation flag. `RunLoop.run(mode:before:)` blocks until an input
    /// source fires, so a thread parked in the runloop does not observe it until something else
    /// wakes it — i.e. `stop()` alone does not actually stop the thread. Pre-existing, unchanged
    /// here, and not implicated in the crash this commit fixes.
    func stop() {
        thread.cancel()
    }

    @objc private func runBlock(_ box: BackgroundWorkerBlock) {
        box.block()
    }
}
