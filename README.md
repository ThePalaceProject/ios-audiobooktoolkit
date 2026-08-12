# Build

Open `NYPLAudiobookToolkit.xcodeproj` and build **NYPLAudiobookToolkit** target.

Project development environment:

- Xcode: 12.4

# How to integrate ios-audiobooktoolkit into your project

1) Edit your Cartfile: `github "ThePalaceProject/ios-audiobooktoolkit"`
2) Open Access Support is built-in. Other DRM providers will require licenses.
3) Ensure host has "Background Modes" enabled in Build Settings: Allow audio playback and airplay from the background.

# Breaking changes

## The `Track` model layer became immutable and `Sendable`

Part of the strict-concurrency migration (PP-4724). `Track` now refines
`Sendable`, its public conformers `FindawayTrack`, `LCPTrack` and
`OpenAccessTrack` are `final`, and roughly twenty-five `public var` stored
properties across those types are now `public let`.

This is a source break for any consumer outside this repository that

- **declares its own `Track` conformer** — the protocol now requires `Sendable`,
  so a conformer holding unsynchronised mutable state no longer satisfies it;
- subclasses one of those conformers, or
- assigns to one of their properties after construction.

There is no deprecation period, because the immutability is the thing that
makes the `Sendable` conformance checkable rather than merely asserted — a
conformer that stayed open to subclassing and reassignment could not honestly
claim it. The Palace iOS app, the only in-tree consumer, builds unchanged.

