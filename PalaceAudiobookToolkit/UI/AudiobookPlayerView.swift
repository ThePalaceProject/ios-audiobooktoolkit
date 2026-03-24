//
// AudiobookPlayerView.swift
// PalaceAudiobookToolkit
//
// Created by Vladimir Fedorov on 10/08/2023.
// Copyright © 2023 The Palace Project. All rights reserved.
//

import AVKit
import MediaPlayer
import PalaceUIKit
import SwiftUI

// MARK: - AudiobookPlayerView

public struct AudiobookPlayerView: View {
  @Environment(\.presentationMode) private var presentationMode
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @ObservedObject var playbackModel: AudiobookPlaybackModel
  @ObservedObject private var showToast = BoolWithDelay(delay: 3)

  private let useIncrementalSpeedSlider: Bool

  @State private var showPlaybackSpeed = false
  @State private var showSleepTimer = false
  @State private var isInBackground = false
  @AccessibilityFocusState private var isTitleFocused: Bool
  @State private var showTOC = false
  @State private var screenSize: CGSize = UIScreen.main.bounds.size
  @State private var loadingTimedOut = false

  public init(model: AudiobookPlaybackModel, useIncrementalSpeedSlider: Bool = false) {
    playbackModel = model
    self.useIncrementalSpeedSlider = useIncrementalSpeedSlider
    setupBackgroundStateHandling()
  }
  
  private var isLandscape: Bool {
    let isIPhone = UIDevice.current.userInterfaceIdiom == .phone
    let isLandscapeOrientation = screenSize.width > screenSize.height
    return isIPhone && isLandscapeOrientation
  }

  public func updateImage(_ image: UIImage) {
    playbackModel.updateCoverImage(image)
  }

  public func unload() {
    playbackModel.stop()
  }

  public var body: some View {
    ZStack(alignment: .bottom) {
      if isLandscape {
        landscapeLayout
      } else {
        portraitLayout
      }

      bookmarkAddedToastView

      if !playbackModel.audiobookManager.audiobook.player.isLoaded {
        if loadingTimedOut {
          LoadingErrorView {
            loadingTimedOut = false
            playbackModel.audiobookManager.audiobook.player.play()
          }
        } else {
          LoadingView()
            .onAppear {
              loadingTimedOut = false
              DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if !playbackModel.audiobookManager.audiobook.player.isLoaded {
                  loadingTimedOut = true
                }
              }
            }
        }
      }
    }
    .background(
      GeometryReader { geometry in
        Color.clear
          .onAppear {
            screenSize = geometry.size
          }
          .onChange(of: geometry.size) { newSize in
            screenSize = newSize
          }
      }
    )
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      screenSize = UIScreen.main.bounds.size
    }
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) { backButton }
      ToolbarItem(placement: .navigationBarTrailing) { tocButton }
    }
    .navigationBarTitle(Text(""), displayMode: .inline)
    .navigationBarBackButtonHidden(true)
    .toolbar(.hidden, for: .tabBar)
    .font(.body)
    .onAppear {
      NotificationCenter.default.post(
        name: Notification.Name("TPPAccessibilityScreenTransition"),
        object: nil
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        isTitleFocused = true
      }
    }
    .onDisappear {
      if !showTOC {
        playbackModel.persistLocation()
        playbackModel.stop()
      }
    }
  }
  
  // MARK: - Portrait Layout
  
  @ViewBuilder
  private var portraitLayout: some View {
    VStack(spacing: 8) {
      headerView
      playbackInfoView
      Spacer(minLength: 8)
      coverImageView
      if !isInBackground {
        downloadProgressView(value: playbackModel.overallDownloadProgress)
      }
      Spacer(minLength: 12)
      playbackControlsView
        .padding(.bottom, 8)
      controlPanelView
    }
  }
  
  // MARK: - Landscape Layout
  
  @ViewBuilder
  private var landscapeLayout: some View {
    VStack(spacing: 0) {
      HStack(spacing: 20) {
        VStack(spacing: 5) {
          coverImageView
            .frame(maxHeight: .infinity)
          if !isInBackground {
            downloadProgressView(value: playbackModel.overallDownloadProgress)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 20)
        
        VStack(spacing: 8) {
          headerView
          playbackInfoView
          Spacer()
          playbackControlsView
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.trailing, 20)
      }
      .padding(.top, 10)
      
      controlPanelView
    }
  }
  
  // MARK: - View Components
  
  // MARK: - Adaptive type scale
  // Three tiers based on screen width: narrow (<370pt SE/Mini), standard (370-420pt), wide (>420pt Pro Max/iPad)
  private var isWideScreen: Bool { screenSize.width > 420 }

  private var titleFontSize: CGFloat    { isLandscape ? 15 : (isNarrowScreen ? 15 : (isWideScreen ? 20 : 17)) }
  private var authorFontSize: CGFloat   { isLandscape ? 12 : (isNarrowScreen ? 12 : (isWideScreen ? 15 : 13)) }
  private var timeRemFontSize: CGFloat  { isLandscape ? 11 : (isNarrowScreen ? 11 : (isWideScreen ? 13 : 12)) }
  private var timestampFontSize: CGFloat { isLandscape ? 11 : (isNarrowScreen ? 11 : (isWideScreen ? 13 : 12)) }
  private var chapterFontSize: CGFloat  { isLandscape ? 13 : (isNarrowScreen ? 13 : (isWideScreen ? 17 : 15)) }

  @ViewBuilder
  private var headerView: some View {
    VStack {
      Text(playbackModel.audiobookManager.metadata.title ?? "")
        .palaceFont(.headline)
        .font(.system(size: titleFontSize))
        .accessibilityLabel(Text(playbackModel.audiobookManager.metadata.title ?? ""))
        .accessibilityFocused($isTitleFocused)
      Text((playbackModel.audiobookManager.metadata.authors ?? []).joined(separator: ", "))
        .palaceFont(.body)
        .font(.system(size: authorFontSize))
        .accessibilityLabel(Text((playbackModel.audiobookManager.metadata.authors ?? []).joined(separator: ", ")))
    }
    .padding(.top, isLandscape ? 5 : nil)
    .multilineTextAlignment(.center)
  }
  
  @ViewBuilder
  private var playbackInfoView: some View {
    VStack(spacing: 5) {
      if !isInBackground {
        Text(timeLeftInBookText)
          .palaceFont(.caption)
          .font(.system(size: timeRemFontSize))
          .accessibilityLabel(Text("Time left in book: \(timeLeftInBookText)"))

        PlaybackSliderView(value: $playbackModel.playbackProgress) { newValue in
          playbackModel.move(to: newValue)
        }
        .padding(.horizontal)
        .accessibilityLabel(Text("Playback slider value: \(playbackModel.playbackSliderValueDescription)"))
      }

      HStack(alignment: .firstTextBaseline) {
        Text(playheadOffsetText)
          .palaceFont(.caption)
          .font(.system(size: timestampFontSize))
          .accessibilityLabel(Text("Time elapsed: \(playheadOffsetAccessibleText)"))
        Spacer()
        Text(chapterTitle)
          .palaceFont(.headline)
          .font(.system(size: chapterFontSize))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .accessibilityLabel(Text(chapterTitle))
        Spacer()
        Text(timeLeftText)
          .palaceFont(.caption)
          .font(.system(size: timestampFontSize))
          .accessibilityLabel(Text("Time left in chapter \(timeLeftAccessibleText)"))
      }
      .padding(.horizontal)
    }
  }
  
  @ViewBuilder
  private var coverImageView: some View {
    ToolkitImage(name: "example_cover", uiImage: playbackModel.coverImage)
      .cornerRadius(6)
      .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
      .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
      .shadow(color: .white.opacity(0.08), radius: 4, x: 0, y: -1)
      .padding(.horizontal, isLandscape ? 0 : 20)
      .padding(.vertical, isLandscape ? 15 : 0)
      .animation(.easeInOut(duration: 0.2), value: playbackModel.isDownloading)
      .animation(.easeInOut(duration: 0.3), value: playbackModel.coverImage == nil)
  }

  private func setupBackgroundStateHandling() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      isInBackground = true
      playbackModel.persistLocation()
    }

    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      isInBackground = false
    }

    NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { _ in
      // Persist on termination as best-effort
      playbackModel.persistLocation()
    }
  }

  private func showToast(message: String) {
    Task { @MainActor in
      playbackModel.toastMessage = message
      showToast.value = true
    }
  }

  // MARK: - Controls

  @ViewBuilder
  private var tocButton: some View {
    NavigationLink {
      AudiobookNavigationView(model: playbackModel)
        .onAppear {
          showTOC = true
        }
        .onDisappear {
          showTOC = false
        }
    } label: {
      ToolkitImage(name: "table_of_contents", renderingMode: .template)
        .foregroundColor(.primary)
        .frame(width: 24, height: 24)
        .padding(.all, 8)
        .background(Color.clear)
        .contentShape(Rectangle())
        .accessibility(label: Text(Strings.Accessibility.tableOfContentsButton))
    }
  }

  @ViewBuilder
  private var backButton: some View {
    Button {
      // Stop playback before dismissing
      playbackModel.stop()
      presentationMode.wrappedValue.dismiss()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "chevron.left")
        Text("My Books")
      }
    }
    .accessibility(label: Text(Strings.Accessibility.backNavigationButton))
    .foregroundColor(Color(.label))
    .padding(.leading, -6)
  }

  @ViewBuilder
  private func skipButton(
    _ imageName: String,
    textLabel _: String,
    accessibilityString: String,
    action: @escaping () -> Void
  ) -> some View {
    let size: CGFloat = isLandscape ? 44 : (horizontalSizeClass == .compact ? 52 : 72)
    let labelFont: Font = isLandscape ? .system(size: 11) : (horizontalSizeClass == .compact ? .system(size: 13, weight: .medium) : .system(size: 16, weight: .medium))
    let secFont: Font = isLandscape ? .system(size: 8) : (horizontalSizeClass == .compact ? .system(size: 9) : .system(size: 11))
    Button(action: action) {
      ToolkitImage(name: imageName, renderingMode: .template)
        .overlay(
          VStack(spacing: -2) {
            Text("\(Int(playbackModel.skipTimeInterval))")
              .font(labelFont)
              .offset(x: -1)
            Text("sec")
              .font(secFont)
          }
          .offset(y: 3)
        )
        .frame(width: size, height: size)
    }
    .accessibilityLabel(accessibilityString)
    .foregroundColor(.primary)
  }

  @ViewBuilder
  private func playButton(isPlaying: Bool, textLabel _: String, action: @escaping () -> Void) -> some View {
    let iconSize: CGFloat = isLandscape ? 38 : (horizontalSizeClass == .compact ? 48 : 64)
    let bgSize: CGFloat = isLandscape ? 56 : (horizontalSizeClass == .compact ? 72 : 92)
    Button(action: action) {
      ZStack {
        Circle()
          .fill(Color.white.opacity(0.12))
        if isPlaying {
          ToolkitImage(name: "pause", renderingMode: .template)
            .frame(width: iconSize, height: iconSize)
        } else {
          ToolkitImage(name: "play", renderingMode: .template)
            .frame(width: iconSize, height: iconSize)
            .offset(x: isLandscape ? 3 : 5)
        }
      }
      .frame(width: bgSize, height: bgSize)
      .animation(.none, value: isPlaying)
    }
    .foregroundColor(.primary)
    .accessibilityLabel(Text(isPlaying ? Strings.Accessibility.pauseButton : Strings.Accessibility.playButton))
  }

  @ViewBuilder
  private func downloadProgressView(value: Float) -> some View {
    VStack(spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.down.circle.fill")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.white.opacity(0.6))

        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(Color.white.opacity(0.15))
              .frame(height: 4)

            Capsule()
              .fill(Color.white.opacity(0.8))
              .frame(width: max(4, geometry.size.width * CGFloat(value)), height: 4)
              .animation(.easeInOut(duration: 0.3), value: value)
          }
          .frame(maxHeight: .infinity)
        }
        .frame(height: 4)

        Text("\(Int(value * 100))%")
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundColor(.white.opacity(0.6))
          .frame(width: 34, alignment: .trailing)
          .monospacedDigit()
      }
      .padding(.horizontal, 20)

      Text(Strings.ScrubberView.downloading)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.white.opacity(0.45))
    }
    .padding(.vertical, playbackModel.isDownloading ? 8 : 0)
    .frame(height: playbackModel.isDownloading ? nil : 0)
    .clipped()
    .animation(.easeInOut(duration: 0.25), value: playbackModel.isDownloading)
  }

  @ViewBuilder
  private var bookmarkAddedToastView: some View {
    HStack(spacing: 10) {
      Image(systemName: playbackModel.toastMessage.contains("error") || playbackModel.toastMessage.contains("Error") ? "exclamationmark.circle.fill" : "bookmark.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(.white)

      Text(playbackModel.toastMessage)
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white)
        .lineLimit(2)
        .multilineTextAlignment(.leading)

      Spacer(minLength: 8)

      Button {
        showToast.value = false
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(.white.opacity(0.6))
          .padding(6)
          .background(Color.white.opacity(0.12))
          .clipShape(Circle())
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: 16)
          .fill(.ultraThinMaterial)
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.white.opacity(0.08))
        RoundedRectangle(cornerRadius: 16)
          .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
      }
    )
    .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 4)
    .padding(.horizontal, 20)
    .padding(.bottom, 110)
    .offset(y: showToast.value ? 0 : 20)
    .opacity(showToast.value ? 1 : 0)
    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: showToast.value)
  }

  @ViewBuilder
  private var playbackControlsView: some View {
    HStack(spacing: isLandscape ? 25 : 40) {
      skipButton(
        "skip_back",
        textLabel: "skip back",
        accessibilityString: Strings.Accessibility.skipBackButton,
        action: playbackModel.skipBack
      )
      playButton(
        isPlaying: playbackModel.isPlaying,
        textLabel: "play button",
        action: playbackModel.playPause
      )
      skipButton(
        "skip_forward",
        textLabel: "skip forward",
        accessibilityString: Strings.Accessibility.skipForwardButton,
        action: playbackModel.skipForward
      )
    }
    .frame(height: isLandscape ? 56 : 72)
  }

  private var isNarrowScreen: Bool {
    screenSize.width < 370
  }

  @ViewBuilder
  private var controlPanelView: some View {
    let chipHeight: CGFloat = isLandscape ? 34 : (isNarrowScreen ? 34 : 40)
    let chipBg = Color.white.opacity(0.10)
    let fontSize: CGFloat = isLandscape ? 13 : (isNarrowScreen ? 12 : 15)
    let iconSize: CGFloat = isLandscape ? 16 : (isNarrowScreen ? 15 : 19)
    let chipPadH: CGFloat = isLandscape ? 12 : (isNarrowScreen ? 10 : 14)
    let outerPadH: CGFloat = isLandscape ? 16 : (isNarrowScreen ? 12 : 20)
    let chipSpacing: CGFloat = isLandscape ? 8 : (isNarrowScreen ? 6 : 12)

    HStack(spacing: chipSpacing) {
      // Speed
      Button {
        showPlaybackSpeed = true
      } label: {
        Text(playbackRateText)
          .font(.system(size: fontSize, weight: .semibold, design: .rounded))
          .padding(.horizontal, chipPadH + 2)
          .frame(height: chipHeight)
          .background(chipBg)
          .clipShape(Capsule())
          .contentShape(Capsule())
      }
      .modifier(SpeedPickerModifier(
        isPresented: $showPlaybackSpeed,
        useSlider: useIncrementalSpeedSlider,
        playbackRateBinding: playbackRateBinding,
        legacyButtons: playbackRateButtons
      ))
      .accessibilityLabel(Text("Playback speed: \(playbackRateText)"))

      Spacer(minLength: 0)

      // Airplay
      AVRoutePickerViewWrapper()
        .frame(height: chipHeight)
        .padding(.horizontal, chipPadH)
        .background(chipBg)
        .clipShape(Capsule())
        .accessibility(label: Text(Strings.Accessibility.airplaybutton))

      Spacer(minLength: 0)

      // Sleep timer
      Button {
        showSleepTimer = true
      } label: {
        HStack(spacing: isNarrowScreen ? 4 : 6) {
          Image(systemName: "moon.fill")
            .font(.system(size: iconSize - 2))
          if playbackModel.audiobookManager.sleepTimer.isActive {
            Text(HumanReadableTimestamp(timeInterval: playbackModel.audiobookManager.sleepTimer.timeRemaining).timecode)
              .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
              .lineLimit(1)
              .minimumScaleFactor(0.6)
          }
        }
        .padding(.horizontal, chipPadH)
        .frame(height: chipHeight)
        .background(chipBg)
        .clipShape(Capsule())
        .contentShape(Capsule())
      }
      .accessibility(label: Text(sleepTimerAccessibilityLabel))
      .actionSheet(isPresented: $showSleepTimer) {
        ActionSheet(title: Text(DisplayStrings.sleepTimer), buttons: sleepTimerButtons)
      }

      Spacer(minLength: 0)

      // Bookmark
      Button {
        playbackModel.addBookmark { error in
          showToast(message: error == nil ? DisplayStrings.bookmarkAdded : (error as? BookmarkError)?
            .localizedDescription ?? ""
          )
        }
      } label: {
        Image(systemName: "bookmark")
          .font(.system(size: iconSize))
          .padding(.horizontal, chipPadH)
          .frame(height: chipHeight)
          .background(chipBg)
          .clipShape(Capsule())
          .contentShape(Capsule())
      }
      .accessibilityLabel(Strings.Accessibility.addBookmarksButton)
    }
    .foregroundColor(.white.opacity(0.9))
    .padding(.horizontal, outerPadH)
    .padding(.vertical, isLandscape ? 6 : 10)
    .background(
      VStack(spacing: 0) {
        Color.white.opacity(0.06)
          .frame(height: 0.5)
        Rectangle()
          .fill(Color(white: 0.15))
      }
      .edgesIgnoringSafeArea([.bottom])
    )
  }

  // MARK: - Property labels

  typealias DisplayStrings = Strings.AudiobookPlayerViewController

  private var chapterTitle: String {
    playbackModel.currentChapterTitle
  }

  private var playbackRateText: String {
    if playbackModel.audiobookManager.audiobook.player.playbackRate == .normalTime {
      NSLocalizedString(
        "1.0×",
        bundle: Bundle.audiobookToolkit()!,
        value: "1.0×",
        comment: "Default title to explain that button changes the speed of playback."
      )
    } else {
      HumanReadablePlaybackRate(rate: playbackModel.audiobookManager.audiobook.player.playbackRate).value
    }
  }

  private var sleepTimerDefaultText = "☾"

  private var sleepTimerText: String {
    playbackModel.audiobookManager.sleepTimer.isActive ?
      HumanReadableTimestamp(timeInterval: playbackModel.audiobookManager.sleepTimer.timeRemaining).timecode :
      sleepTimerDefaultText
  }

  private var sleepTimerAccessibilityLabel: String {
    playbackModel.audiobookManager.sleepTimer.isActive ?
      String(
        format: DisplayStrings.timeToPause,
        VoiceOverTimestamp(timeInterval: playbackModel.audiobookManager.sleepTimer.timeRemaining)
      ) :
      DisplayStrings.sleepTimer
  }

  private var playbackRateDescription: String {
    HumanReadablePlaybackRate(rate: playbackModel.audiobookManager.audiobook.player.playbackRate).accessibleDescription
  }

  private var playheadOffsetText: String {
    HumanReadableTimestamp(timeInterval: playbackModel.offset).timecode
  }

  private var playheadOffsetAccessibleText: String {
    HumanReadableTimestamp(timeInterval: playbackModel.offset).accessibleDescription
  }

  private var timeLeftText: String {
    HumanReadableTimestamp(timeInterval: playbackModel.timeLeft).timecode
  }

  private var timeLeftAccessibleText: String {
    HumanReadableTimestamp(timeInterval: playbackModel.timeLeft).accessibleDescription
  }

  private var timeLeftInBookText: String {
    let timeLeft = HumanReadableTimestamp(timeInterval: playbackModel.timeLeftInBook).stringDescription
    let formatString = Strings.ScrubberView.timeRemaining
    return String(format: formatString, timeLeft)
  }

  private var playbackRateBinding: Binding<PlaybackRate> {
    Binding(
      get: { playbackModel.audiobookManager.audiobook.player.playbackRate },
      set: { playbackModel.setPlaybackRate($0) }
    )
  }

  private var playbackRateButtons: [ActionSheet.Button] {
    var buttons = PlaybackRate.presets.map { rate in
      ActionSheet.Button.default(
        Text(HumanReadablePlaybackRate(rate: rate).value),
        action: { playbackModel.setPlaybackRate(rate) }
      )
    }
    buttons.append(.cancel())
    return buttons
  }

  private var sleepTimerButtons: [ActionSheet.Button] {
    var buttons = [ActionSheet.Button]()
    for sleepTimer in SleepTimerTriggerAt.allCases {
      buttons.append(
        .default(Text(sleepTimerTitle(for: sleepTimer)), action: {
          playbackModel.setSleepTimer(sleepTimer)
        })
      )
    }
    buttons.append(.cancel())
    return buttons
  }

  private func sleepTimerTitle(for sleepTimer: SleepTimerTriggerAt) -> String {
    switch sleepTimer {
    case .endOfChapter: DisplayStrings.endOfChapter
    case .oneHour: DisplayStrings.oneHour
    case .thirtyMinutes: DisplayStrings.thirtyMinutes
    case .fifteenMinutes: DisplayStrings.fifteenMinutes
    case .never: DisplayStrings.off
    }
  }
}

// MARK: - Preview

private extension AudiobookPlayerView {
  // Preview init
  // This resource must be available to PalaceAudiobookToolkit module
  init?() {
    guard let resource = Bundle.audiobookToolkit()?.url(forResource: "alice_manifest", withExtension: "json"),
          let audiobookData = try? Data(contentsOf: resource),
          let manifest = try? JSONDecoder().decode(Manifest.self, from: audiobookData),
          let audiobook = OpenAccessAudiobook(manifest: manifest, bookIdentifier: "test_book_id", token: nil)
    else {
      return nil
    }
    let audiobookManager = DefaultAudiobookManager(
      metadata: AudiobookMetadata(title: "Test book title", authors: ["Author One", "Author Two"]),
      audiobook: audiobook,
      networkService: DefaultAudiobookNetworkService(
        tracks: audiobook.tableOfContents.allTracks,
        decryptor: audiobook.player is LCPStreamingPlayer ? (audiobook.player as? LCPStreamingPlayer)?.decryptor : nil
      )
    )
    playbackModel = AudiobookPlaybackModel(audiobookManager: audiobookManager)
    useIncrementalSpeedSlider = false
  }
}

// MARK: - AudiobookPlayerView_Previews

struct AudiobookPlayerView_Previews: PreviewProvider {
  static var previews: some View {
    AudiobookPlayerView()
  }
}

// MARK: - AVRoutePickerViewRepresentable

/// Airplay button
struct AVRoutePickerViewRepresentable: UIViewRepresentable {
  func makeUIView(context _: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.tintColor = .white
    return picker
  }

  func updateUIView(_: AVRoutePickerView, context _: Context) {
    //
  }
}

// MARK: - AVRoutePickerViewWrapper

/// Airplay button wrapper
struct AVRoutePickerViewWrapper: View {
  var body: some View {
    AVRoutePickerViewRepresentable()
      .frame(width: 30, height: 30)
  }
}

// MARK: - AudiobookSlider

/// High-performance audiobook slider with smooth seeking and haptic feedback
struct AudiobookSlider: View {
  @Binding var value: Double
  @State private var isDragging: Bool = false
  @State private var dragValue: Double = 0.0
  @State private var lastHapticValue: Double = -1.0
  @State private var committedValue: Double = 0.0

  let onDragChanged: (Double) -> Void
  let onDragEnded: (Double) -> Void

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        // Background track
        Rectangle()
          .fill(.gray)
          .frame(height: trackHeight)

        // Progress track with minimal animation
        Rectangle()
          .fill(Color(.label))
          .frame(width: progressWidth(in: geometry.size), height: trackHeight)
          .animation(.easeOut(duration: isDragging ? 0.0 : 0.1), value: isDragging ? dragValue : value)

        // Thumb with subtle visual feedback
        Capsule()
          .fill(Color.red)
          .frame(width: thumbWidth, height: thumbHeight)
          .offset(x: thumbOffset(in: geometry.size))
          .scaleEffect(isDragging ? 1.05 : 1.0)
          .animation(.easeOut(duration: 0.1), value: isDragging)
          .gesture(
            DragGesture()
              .onChanged { gesture in
                let newValue = max(0, min(1, Double(gesture.location.x / geometry.size.width)))

                if !isDragging {
                  isDragging = true
                  dragValue = newValue
                } else {
                  dragValue = newValue
                }

                // Minimal haptic feedback for professional feel
                provideSubtleHapticFeedback(for: newValue)

                // Visual feedback only during drag
                onDragChanged(newValue)
              }
              .onEnded { _ in
                isDragging = false
                committedValue = dragValue

                // Subtle completion feedback
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()

                // Perform seeking on drag end
                onDragEnded(dragValue)
              }
          )
          .accessibilityLabel(Strings.Accessibility.audiobookPlaybackSlider)
      }
    }
    .frame(height: thumbHeight)
  }

  // MARK: - Helper Methods

  private func progressWidth(in size: CGSize) -> CGFloat {
    let currentValue = isDragging ? dragValue : (committedValue > 0 ? max(value, committedValue) : value)
    return CGFloat(currentValue) * size.width
  }

  private func thumbOffset(in size: CGSize) -> CGFloat {
    let currentValue = isDragging ? dragValue : (committedValue > 0 ? max(value, committedValue) : value)
    return CGFloat(currentValue) * (size.width - thumbWidth)
  }

  private func provideSubtleHapticFeedback(for newValue: Double) {
    // Very subtle haptic feedback only at start/end boundaries
    if abs(newValue - lastHapticValue) > 0.2 {
      if abs(newValue - 0.0) < 0.02 || abs(newValue - 1.0) < 0.02 {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        lastHapticValue = newValue
      }
    }
  }

  // MARK: - View configuration

  private let thumbWidth: CGFloat = 10
  private let thumbHeight: CGFloat = 36
  private let trackHeight: CGFloat = 10
}

// MARK: - PlaybackSliderView

/// Modern playback slider: thin rounded track that expands on touch,
/// with a circular thumb that scales up while dragging.
struct PlaybackSliderView: View {
  @Binding var value: Double
  @State private var tempValue: Double?
  @State private var isDragging: Bool = false
  @State private var isCommitting: Bool = false
  var onChange: (_ value: Double) -> Void

  private let trackRest: CGFloat = 4
  private let trackActive: CGFloat = 6
  private let thumbRest: CGFloat = 8
  private let thumbActive: CGFloat = 14
  private let hitHeight: CGFloat = 44

  private var currentTrackHeight: CGFloat { isDragging ? trackActive : trackRest }
  private var currentThumbSize: CGFloat { isDragging ? thumbActive : thumbRest }

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width

      ZStack(alignment: .leading) {
        // Background track
        Capsule()
          .fill(Color.white.opacity(0.2))
          .frame(height: currentTrackHeight)

        // Progress fill
        Capsule()
          .fill(Color(.label))
          .frame(
            width: max(currentTrackHeight, progressWidth(in: width)),
            height: currentTrackHeight
          )

        // Thumb
        Circle()
          .fill(Color(.label))
          .frame(width: currentThumbSize, height: currentThumbSize)
          .offset(x: thumbOffset(in: width))
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            if !isDragging {
              withAnimation(.easeOut(duration: 0.15)) { isDragging = true }
            }
            let newValue = max(0, min(1, Double(gesture.location.x / width)))
            tempValue = newValue
          }
          .onEnded { _ in
            withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
            if let finalValue = tempValue {
              isCommitting = true
              value = finalValue
              onChange(finalValue)
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                tempValue = nil
                isCommitting = false
              }
            }
          }
      )
      .accessibilityLabel(Strings.Accessibility.audiobookPlaybackSlider)
    }
    .frame(height: hitHeight)
  }

  private var displayValue: Double {
    tempValue ?? value
  }

  private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
    CGFloat(displayValue) * totalWidth
  }

  private func thumbOffset(in totalWidth: CGFloat) -> CGFloat {
    CGFloat(displayValue) * (totalWidth - currentThumbSize)
  }
}

// MARK: - ToolkitImage

struct ToolkitImage: View {
  let name: String
  var uiImage: UIImage?
  var renderingMode: Image.TemplateRenderingMode = .original
  var body: some View {
    if let uiImage {
      Image(uiImage: uiImage)
        .resizable()
        .renderingMode(renderingMode)
        .scaledToFit()
        .aspectRatio(1, contentMode: .fit)
        .accessibility(label: Text("Book Cover"))
    } else {
      Image(name, bundle: Bundle.audiobookToolkit())
        .resizable()
        .renderingMode(renderingMode)
        .scaledToFit()
        .aspectRatio(1, contentMode: .fit)
        .accessibility(label: Text("Book Cover"))
    }
  }
}
