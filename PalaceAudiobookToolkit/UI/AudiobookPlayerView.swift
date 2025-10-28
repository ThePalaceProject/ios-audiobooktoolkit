//
//  AudiobookPlayerView.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 10/08/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
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

  @State private var showPlaybackSpeed = false
  @State private var showSleepTimer = false
  @State private var isInBackground = false
  @State private var showTOC = false

  public init(model: AudiobookPlaybackModel) {
    playbackModel = model
    setupBackgroundStateHandling()
  }

  public func updateImage(_ image: UIImage) {
    playbackModel.updateCoverImage(image)
  }

  public func unload() {
    playbackModel.stop()
  }

  public var body: some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 10) {
        VStack {
          Text(playbackModel.audiobookManager.metadata.title ?? "")
            .palaceFont(.headline)
            .accessibilityLabel(Text(playbackModel.audiobookManager.metadata.title ?? ""))
          Text((playbackModel.audiobookManager.metadata.authors ?? []).joined(separator: ", "))
            .palaceFont(.body)
            .accessibilityLabel(Text((playbackModel.audiobookManager.metadata.authors ?? []).joined(separator: ", ")))
        }
        .padding(.top)
        .multilineTextAlignment(.center)

        VStack(spacing: 5) {
          if !isInBackground {
            Text(timeLeftInBookText)
              .palaceFont(.caption)
              .accessibilityLabel(Text("Time left in book: \(timeLeftInBookText)"))

            PlaybackSliderView(value: $playbackModel.playbackProgress) { newValue in
              playbackModel.move(to: newValue)
            }
            .padding(.horizontal)
            .accessibilityLabel(Text("Playback slider value: \(playbackModel.playbackSliderValueDescription)"))
          }

          HStack(alignment: .firstTextBaseline) {
            Text("\(playheadOffsetText)")
              .palaceFont(.caption)
              .accessibilityLabel(Text("Time elapsed: \(playheadOffsetAccessibleText)"))
            Spacer()
            Text(chapterTitle)
              .palaceFont(.headline)
              .multilineTextAlignment(.center)
              .lineLimit(2)
              .accessibilityLabel(Text(chapterTitle))

            Spacer()
            Text("\(timeLeftText)")
              .palaceFont(.caption)
              .accessibilityLabel(Text("Time left in chapter \(timeLeftAccessibleText)"))
          }
          .padding(.horizontal)
        }

        Spacer()

        ToolkitImage(name: "example_cover", uiImage: playbackModel.coverImage)
          .padding(.horizontal)
          .animation(.easeInOut(duration: 0.2), value: playbackModel.isDownloading)

        if !isInBackground {
          downloadProgressView(value: playbackModel.overallDownloadProgress)
        }

        Spacer()

        playbackControlsView
          .padding(.bottom)

        controlPanelView
      }

      bookmarkAddedToastView

      if !playbackModel.audiobookManager.audiobook.player.isLoaded {
        LoadingView()
      }
    }

    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) { backButton }
      ToolbarItem(placement: .navigationBarTrailing) { tocButton }
    }
    .navigationBarTitle(Text(""), displayMode: .inline)
    .navigationBarBackButtonHidden(true)
    .toolbar(.hidden, for: .tabBar)
    .font(.body)
    .onDisappear {
      if !showTOC {
        playbackModel.persistLocation()
        playbackModel.flushPendingBookmarkOperations()
        playbackModel.stop()
      }
    }
  }

  private func setupBackgroundStateHandling() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      isInBackground = true
      playbackModel.persistLocation()
      playbackModel.flushPendingBookmarkOperations()
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
      playbackModel.flushPendingBookmarkOperations()
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
    // Button size: 66 compact, 96 regular
    let size: CGFloat = horizontalSizeClass == .compact ? 66 : 96
    Button(action: action) {
      ToolkitImage(name: imageName, renderingMode: .template)
        .overlay(
          VStack(spacing: -4) {
            Text("\(Int(playbackModel.skipTimeInterval))")
              .palaceFont(.body)
              .offset(x: -1)
            Text("sec")
              .palaceFont(.caption)
          }
          .offset(y: 4)
        )
        .frame(width: size, height: size)
    }
    .accessibilityLabel(accessibilityString)
    .foregroundColor(.primary)
  }

  @ViewBuilder
  private func playButton(isPlaying: Bool, textLabel _: String, action: @escaping () -> Void) -> some View {
    // Button size: 56 compact, 80 regular
    let size: CGFloat = horizontalSizeClass == .compact ? 56 : 80
    Button(action: action) {
      ZStack {
        ToolkitImage(name: "pause", renderingMode: .template)
          .opacity(isPlaying ? 1 : 0)
          .frame(width: size, height: size)
        ToolkitImage(name: "play", renderingMode: .template)
          .opacity(isPlaying ? 0 : 1)
          .frame(width: size, height: size)
          .offset(x: 7) // makes the button visually centered
      }
    }
    .foregroundColor(.primary)
    .accessibilityLabel(Text(isPlaying ? Strings.Accessibility.pauseButton : Strings.Accessibility.playButton))
  }

  @ViewBuilder
  private func downloadProgressView(value: Float) -> some View {
    let progressHeight: CGFloat = 6
    HStack(alignment: .bottom) {
      VStack(alignment: .center) {
        ZStack {
          GeometryReader { geometry in
            Rectangle()
              .frame(height: progressHeight)
              .opacity(0.3)
            Rectangle()
              .frame(height: progressHeight)
              .frame(width: geometry.size.width * CGFloat(value))
          }
          .frame(maxHeight: 6)
        }
        Text(Strings.ScrubberView.downloading)
      }
      .font(.caption)
      .padding(8)
      .padding(.horizontal)
    }
    .frame(maxWidth: .infinity)
    .frame(height: playbackModel.isDownloading ? nil : 0)
    .clipped()
  }

  @ViewBuilder
  private var bookmarkAddedToastView: some View {
    HStack {
      Text(playbackModel.toastMessage)
        .multilineTextAlignment(.leading)
      Spacer()
      Button {
        showToast.value = false
      } label: {
        Image(systemName: "xmark.circle")
      }
    }
    .palaceFont(.subheadline)
    .foregroundColor(.white)
    .padding(.horizontal)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(.darkGray))
        .edgesIgnoringSafeArea([.bottom])
    )
    .padding(.horizontal, 30)
    .padding(.bottom, 100)
    .opacity(showToast.value ? 1 : 0)
    .animation(.easeInOut, value: showToast.value)
  }

  @ViewBuilder
  private var playbackControlsView: some View {
    HStack(spacing: 40) {
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
    .frame(height: 66)
  }

  @ViewBuilder
  private var controlPanelView: some View {
    VStack {
      HStack {
        Spacer()
          .overlay(
            Button {
              showPlaybackSpeed.toggle()
            } label: {
              Text(playbackRateText)
                .font(.body)
            }
            .actionSheet(isPresented: $showPlaybackSpeed) {
              ActionSheet(title: Text(DisplayStrings.playbackSpeed), buttons: playbackRateButtons)
            }
            .accessibilityLabel(Text("Playback speed: \(playbackRateText)"))
          )

        Spacer()
          .overlay(
            AVRoutePickerViewWrapper()
              .accessibility(label: Text(Strings.Accessibility.airplaybutton))
          )

        Spacer()
          .overlay(
            Button {
              showSleepTimer.toggle()
            } label: {
              Text(sleepTimerText)
                .palaceFont(.body)
            }
            .accessibility(label: Text(sleepTimerAccessibilityLabel))
            .actionSheet(isPresented: $showSleepTimer) {
              ActionSheet(title: Text(DisplayStrings.sleepTimer), buttons: sleepTimerButtons)
            }
          )
        Spacer()
          .overlay(
            Button {
              playbackModel.addBookmark { error in
                showToast(message: error == nil ? DisplayStrings.bookmarkAdded : (error as? BookmarkError)?
                  .localizedDescription ?? ""
                )
              }
            } label: {
              ToolkitImage(name: "bookmark", renderingMode: .template)
                .frame(height: 20)
            }
            .accessibilityLabel(Strings.Accessibility.addBookmarksButton)
          )
      }
      .frame(minHeight: 40)
      .foregroundColor(.white)
      .padding()
    }
    .background(
      Rectangle()
        .fill(Color(.darkGray))
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

  private var playbackRateButtons: [ActionSheet.Button] {
    var buttons = [ActionSheet.Button]()
    for playbackRate in PlaybackRate.allCases {
      buttons.append(
        .default(
          Text(HumanReadablePlaybackRate(rate: playbackRate).value),
          action: { playbackModel.setPlaybackRate(playbackRate)
          }
        )
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

/// Clean playback slider with anti-flicker on release
struct PlaybackSliderView: View {
  @Binding var value: Double
  @State private var tempValue: Double?
  @State private var isCommitting: Bool = false
  var onChange: (_ value: Double) -> Void

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(.gray)
          .frame(height: trackHeight)

        Rectangle()
          .fill(Color(.label))
          .frame(width: offsetX(in: geometry.size, for: displayValue), height: trackHeight)

        Capsule()
          .fill(Color.red)
          .frame(width: thumbWidth, height: thumbHeight)
          .offset(x: offsetX(in: geometry.size, for: displayValue))
          .gesture(
            DragGesture()
              .onChanged { gesture in
                let newValue = max(0, min(1, Double(gesture.location.x / geometry.size.width)))
                tempValue = newValue
              }
              .onEnded { _ in
                if let finalValue = tempValue {
                  // Prevent flicker by keeping temp value until seek completes
                  isCommitting = true
                  value = finalValue
                  onChange(finalValue)

                  // Clear temp value after brief delay to prevent flicker
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    tempValue = nil
                    isCommitting = false
                  }
                }
              }
          )
          .accessibilityLabel(Strings.Accessibility.audiobookPlaybackSlider)
      }
    }
    .frame(height: thumbHeight)
  }

  // Use temp value during drag and briefly after release to prevent flicker
  private var displayValue: Double {
    if let tempValue = tempValue {
      return tempValue
    }
    return value
  }

  private func offsetX(in size: CGSize, for value: Double) -> CGFloat {
    CGFloat(value) * (size.width - thumbWidth)
  }

  // MARK: - View configuration

  private let thumbWidth: CGFloat = 10
  private let thumbHeight: CGFloat = 36
  private let trackHeight: CGFloat = 10
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
