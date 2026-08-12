//
//  WeakLockIsolated.swift
//  PalaceAudiobookToolkit
//
//  A lock-guarded *weak* reference.
//
//  Deliberately separate from `LockIsolated`, which stores its value strongly.
//  Several download-path delegates hold their collaborator weakly on purpose,
//  and that weakness is load-bearing rather than incidental: the task and its
//  URLSession delegate reference each other, so a strong edge would form a
//  retain cycle that never breaks on player close. The delegate would stay
//  alive, the router's observer would never nil out, and the durable
//  completion fallback that recovers a download finishing while the player is
//  closed would become unreachable (the F2 fix, upstream #197).
//
//  So migrating those properties into `LockIsolated` would silence a warning
//  and reintroduce a shipped bug. Use this type instead: it adds the lock the
//  compiler needs to see while keeping the reference weak.
//

import Foundation

/// A weak reference whose reads and writes are serialized by a lock.
///
/// `@unchecked Sendable` is sound because `_value` is only ever touched while
/// `lock` is held. The referenced object's own thread-safety is a separate
/// concern and remains the caller's responsibility — this box protects the
/// reference, not the referent.
final class WeakLockIsolated<Value: AnyObject> {
  private let lock = NSLock()
  private weak var _value: Value?

  init(_ value: Value? = nil) {
    _value = value
  }

  /// Atomically read or replace the referenced object. Reads return `nil` once
  /// the referent has deallocated, exactly as a plain `weak` would.
  var value: Value? {
    get { lock.withLock { _value } }
    set { lock.withLock { _value = newValue } }
  }
}

extension WeakLockIsolated: @unchecked Sendable {}
