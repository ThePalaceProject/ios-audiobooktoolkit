//
//  FindawayDatabaseVerification.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 5/8/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

// MARK: - FindawayDatabaseVerificationDelegate

/// Main-actor isolated: `FindawayDatabaseVerification` now hops to the main
/// actor before notifying, and every conformer (`FindawayPlayer`,
/// `FindawayDownloadTask`) lives there.
@MainActor
@objc protocol FindawayDatabaseVerificationDelegate: class {
  func findawayDatabaseVerificationDidUpdate(_ findawayDatabaseVerification: FindawayDatabaseVerification)
}

// MARK: - FindawayDatabaseVerification

/// Shared verification state for the AudioEngine database.
///
/// - Sendable invariant: `_verified` and `delegates` are read and written ONLY
///   while `lock` is held; nothing else is stored. `final` keeps that intact —
///   a subclass cannot add unsynchronized state. Hence `@unchecked Sendable`
///   with the invariant stated, rather than a bare claim.
///
/// This was genuinely raced before, not merely un-annotated. `verified` is set
/// from `audioEngineDatabaseVerificationStatusHasBeenUpdated`, an AudioEngine
/// NotificationCenter callback delivered on the SDK's own thread, while
/// `delegates` was mutated by register/remove from wherever a caller happened
/// to be — an unguarded `NSHashTable` written from two threads.
///
/// The `didSet` also called delegates inline on that SDK thread, and one of
/// them is `FindawayPlayer`, which is `@MainActor`. Notification is now hopped
/// to the main actor, which is where every delegate lives.
@objc final class FindawayDatabaseVerification: NSObject, @unchecked Sendable {
  static let shared = FindawayDatabaseVerification()

  private let lock = NSLock()
  private var _verified = false
  private let delegates =
    NSHashTable<FindawayDatabaseVerificationDelegate>(options: [NSPointerFunctions.Options.weakMemory])

  var verified: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _verified
    }
    set {
      lock.lock()
      let changed = (_verified != newValue)
      _verified = newValue
      // Snapshot under the lock; notify outside it, so a delegate calling back
      // into register/removeDelegate cannot deadlock.
      let targets = delegates.allObjects
      lock.unlock()

      guard changed else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          targets.forEach { $0.findawayDatabaseVerificationDidUpdate(self) }
        }
      }
    }
  }

  func registerDelegate(_ delegate: FindawayDatabaseVerificationDelegate) {
    lock.lock()
    defer { lock.unlock() }
    delegates.add(delegate)
  }

  func removeDelegate(_ delegate: FindawayDatabaseVerificationDelegate) {
    lock.lock()
    defer { lock.unlock() }
    delegates.remove(delegate)
  }
}
