//
//  LockIsolated.swift
//  PalaceAudiobookToolkit
//
//  Concurrency-safe holder for state that used to live in a mutable `static`
//  or module-level `var`. Under strict concurrency checking such a binding is
//  "nonisolated global shared mutable state" and is diagnosed — even when every
//  access already funnels through a lock, because the compiler cannot see the
//  lock discipline.
//
//  The migration pattern (chosen over `nonisolated(unsafe)`, which merely
//  silences the check without making anything safer) is:
//
//      // before — flagged as unsafe global mutable state:
//      static var tokenResolver: Resolver?
//
//      // after — genuinely safe, and every existing call site is unchanged:
//      private static let _tokenResolver = LockIsolated<Resolver?>(nil)
//      static var tokenResolver: Resolver? {
//        get { _tokenResolver.value }
//        set { _tokenResolver.value = newValue }
//      }
//
//  The `static let` binding is immutable, so it is not global mutable state;
//  all mutation flows through the lock. The public `static var` becomes
//  *computed* — it holds no storage of its own — so callers are untouched.
//
//  `@unchecked Sendable` is sound here because every access to `_value` happens
//  while `lock` is held. That is the invariant this type exists to guarantee;
//  do not add a path that reaches `_value` outside `lock`.
//
//  Mirrors the same-named helper used by the Palace app's test support target,
//  so the idiom reads identically on both sides of the framework boundary.
//

import Foundation

/// A mutable value guarded by an `NSLock`.
///
/// `Value` is constrained to `Sendable` so that handing the wrapped value
/// across isolation domains stays sound: the lock protects *this* box's
/// storage, not any reference graph hanging off a non-`Sendable` payload.
final class LockIsolated<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Value

  init(_ value: Value) {
    _value = value
  }

  /// Atomically read or replace the wrapped value.
  var value: Value {
    get { lock.withLock { _value } }
    set { lock.withLock { _value = newValue } }
  }

  /// Perform an atomic read-modify-write and return a result. Use this when a
  /// compound mutation must not interleave (for example append-then-read),
  /// which a separate `get` then `set` cannot guarantee.
  @discardableResult
  func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    try lock.withLock { try body(&_value) }
  }
}
