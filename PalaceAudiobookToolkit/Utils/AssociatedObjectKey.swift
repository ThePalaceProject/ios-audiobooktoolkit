//
//  AssociatedObjectKey.swift
//  PalaceAudiobookToolkit
//
//  `objc_setAssociatedObject` / `objc_getAssociatedObject` identify a slot by
//  the *address* of a key, never by its contents. The long-standing Objective-C
//  idiom for that is a file-scope `private var someKey: UInt8 = 0` passed as
//  `&someKey`, but under strict concurrency checking a mutable global is
//  "nonisolated global shared mutable state" and is diagnosed.
//
//  Swapping in a bare `let` of `UnsafeRawPointer` does not help either: pointer
//  types are deliberately non-`Sendable`, because in general the compiler
//  cannot know what the pointee is or who else may be writing it.
//
//  Here it can be known, and that is what this type documents: the allocated
//  byte is never read and never written by anyone. Only the pointer's identity
//  is ever used. That makes sharing it across isolation domains sound, so the
//  `@unchecked Sendable` conformance rests on a real invariant rather than on
//  silencing the check — which is why this is preferred over
//  `nonisolated(unsafe)` at each site.
//

import Foundation

/// A process-lifetime unique address for use as an Objective-C associated-object key.
///
/// - Important: The allocated storage is intentionally never freed and never
///   dereferenced. Do not add an accessor that reads or writes the pointee —
///   doing so would invalidate the `@unchecked Sendable` conformance.
struct AssociatedObjectKey: @unchecked Sendable {
  /// The key address to hand to the `objc_*AssociatedObject` runtime calls.
  let rawValue: UnsafeRawPointer

  init() {
    rawValue = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
  }
}
