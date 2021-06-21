# Build

To build the project, first build Carthage dependencies:

```
carthage update --use-xcframeworks --platform ios
```

Open `NYPLAudiobookToolkit.xcodeproj` and build **NYPLAudiobookToolkit** target.

Project development environment:

- Xcode: 12.4
- Carthage: 0.38

# How to integrate ios-audiobooktoolkit into your project

1) Edit your Cartfile: `github "ThePalaceProject/ios-audiobooktoolkit"`
2) Open Access Support is built-in. Other DRM providers will require licenses.
3) Ensure host has "Background Modes" enabled in Build Settings: Allow audio playback and airplay from the background.

