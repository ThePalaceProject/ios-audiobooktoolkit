//
//  AudiobookPlayerView.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 10/08/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import MediaPlayer
import AVKit
import PalaceUIKit

struct AudiobookPlayerView: View {
    
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    @State private var uiTabarController: UITabBarController?
    @ObservedObject var playbackModel: AudiobookPlaybackModel
    @State private var selectedLocation: ChapterLocation = .emptyLocation
    @ObservedObject private var showToast = BoolWithDelay(delay: 3)
    @State private var toastMessage: String = ""
    @State private var showPlaybackSpeed = false
    @State private var showSleepTimer = false
    
    init(model: AudiobookPlaybackModel) {
        self.playbackModel = model
    }
    
    public func updateImage(_ image: UIImage) {
        playbackModel.updateCoverImage(image)
    }
    
    public func unload() {
        playbackModel.stop()
    }
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                VStack(spacing: 10) {
                    Group {
                        downloadProgressView(value: playbackModel.overallDownloadProgress)
                        
                        VStack {
                            Text(playbackModel.audiobookManager.metadata.title ?? "")
                                .palaceFont(.headline)
                            Text((playbackModel.audiobookManager.metadata.authors ?? []).joined(separator: ", "))
                                .palaceFont(.body)
                        }
                        
                        VStack(spacing: 5) {
                            Text(timeLeftInBookText)
                                .palaceFont(.caption)
                            
                            PlaybackSliderView(value: $playbackModel.playbackProgress) { newValue in
                                playbackModel.move(to: newValue)
                            }
                            .padding(.horizontal)
                            
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(playheadOffsetText)")
                                    .palaceFont(.caption)
                                Spacer()
                                Text(chapterTitle)
                                    .palaceFont(.headline)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                Spacer()
                                Text("\(timeLeftText)")
                                    .palaceFont(.caption)
                            }
                            .padding(.horizontal)
                        }
                        
                        Spacer()
                        
                        ToolkitImage(name: "example_cover", uiImage: playbackModel.coverImage)
                            .padding(.horizontal)
                    }
                    .animation(.easeInOut(duration: 0.2), value: playbackModel.isDownloading)
                    
                    Spacer()
                    
                    playbackControlsView
                        .padding(.bottom)
                    
                    controlPanelView
                    
                }
                
                bookmarkAddedToastView
            }
            .navigationBarTitle(Text(""), displayMode: .inline)
            .navigationBarItems(trailing: tocButton)
            .navigationBarItems(leading: backButton)
        }
        .palaceFont(.body)
        .navigationViewStyle(.stack)
        .onChange(of: selectedLocation) { newValue in
            playbackModel.audiobookManager.audiobook.player.playAtLocation(newValue) { error in
                // present error
            }
        }
    }
    
    private func showToast(message: String) {
        Task {
            toastMessage = message
            showToast.value = true
        }
    }
    
    // MARK: - Controls
    
    @ViewBuilder
    private var tocButton: some View {
        NavigationLink {
            AudiobookNavigationView(model: playbackModel, selectedLocation: $selectedLocation)
        } label: {
            ToolkitImage(name: "table_of_contents", renderingMode: .template)
                .accessibility(label: Text("Table of contents"))
                .foregroundColor(.primary)
                .foregroundColor(.black)
        }
    }
    
    @ViewBuilder
    private var backButton: some View {
        Button {
            presentationMode.wrappedValue.dismiss()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("My Books")
            }
        }
        .foregroundColor(Color(.label))
        .padding(.leading, -6)
    }

    @ViewBuilder
    private func skipButton(_ imageName: String, textLabel: String, action: @escaping () -> Void) -> some View {
        // Button size: 66 compact, 96 regular
        let size: CGFloat = horizontalSizeClass == .compact ? 66 : 96
        Button(action: action) {
            ToolkitImage(name: imageName, renderingMode: .template)
                .overlay(
                    VStack(spacing: -4) {
                        Text("\(Int(playbackModel.skipTimeInterval))")
                            .palaceFont(size: 20)
                            .offset(x: -1)
                        Text("sec")
                            .palaceFont(.caption)
                    }
                        .offset(y: 4)
                )
                .frame(width: size, height: size)
        }
        .accessibility(label: Text(textLabel))
        .foregroundColor(.primary)
    }
    
    @ViewBuilder
    private func playButton(isPlaying: Bool, textLabel: String, action: @escaping () -> Void) -> some View {
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
        .accessibility(label: Text(isPlaying ? "Pause" : "Play"))
    }
    
    @ViewBuilder
    private func downloadProgressView(value: Float) -> some View {
        let progressHeight: CGFloat = 6
        HStack(alignment: .bottom) {
            HStack {
                Text("Downloading:")
                ZStack {
                    GeometryReader { geometry in
                        Capsule()
                            .frame(height: progressHeight)
                            .opacity(0.3)
                        Capsule()
                            .frame(height: progressHeight)
                            .frame(width: geometry.size.width * CGFloat(value))
                    }
                    .frame(maxHeight: 6)
                }
                Text("\(Int(value * 100))%")
            }
            .palaceFont(.caption)
            .padding(8)
            .foregroundColor(.white)
            .background(Color.black)
        }
        .frame(maxWidth: .infinity)
        .frame(height: playbackModel.isDownloading ? nil : 0)
        .clipped()
    }
    
    @ViewBuilder
    private var bookmarkAddedToastView: some View {
        HStack {
            Text(toastMessage)
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
        .padding(.bottom,  100)
        .opacity(showToast.value ? 1 : 0)
        .animation(.easeInOut, value: showToast.value)
    }
    
    @ViewBuilder
    private var playbackControlsView: some View {
        HStack(spacing: 40) {
            skipButton("skip_back", textLabel: "skip back", action: playbackModel.skipBack)
            playButton(isPlaying: playbackModel.isPlaying, textLabel: "play button", action: playbackModel.playPause)
            skipButton("skip_forward", textLabel: "skip forward", action: playbackModel.skipForward)
        }
        .frame(height: 66)
    }
    
    @ViewBuilder
    private var controlPanelView: some View {
        VStack {
            HStack {
                // Playback speed
                // This makes buttons remain at the same position
                // when the size of one changes
                Spacer()
                    .overlay(
                        Button {
                            showPlaybackSpeed.toggle()
                        } label: {
                            Text(playbackRateText)
                                .palaceFont(.body)
                        }
                            .actionSheet(isPresented: $showPlaybackSpeed) {
                                ActionSheet(title: Text(DisplayStrings.playbackSpeed), buttons: playbackRateButtons)
                            }
                    )
                
                // AirPlay
                Spacer()
                    .overlay(
                        AVRoutePickerViewWrapper()
                    )
                
                // Sleep Timer
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
                        // Bookmarks
                        Button {
                            playbackModel.addBookmark { error in
                                showToast(message: error == nil ? DisplayStrings.bookmarkAdded : (error as? BookmarkError)?.localizedDescription ?? "")
                            }
                        } label: {
                            ToolkitImage(name: "bookmark", renderingMode: .template)
                                .frame(height: 20)
                        }
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
        guard let currentLocation = playbackModel.currentLocation else {
            return "--"
        }
        let defaultTitleFormat = DisplayStrings.trackAt
        let indexString = oneBasedSpineIndex() ?? "--"
        return currentLocation.title ?? String(format: defaultTitleFormat, indexString)
    }
    
    private func oneBasedSpineIndex() -> String? {
        guard let currentLocation = playbackModel.currentLocation else {
            return nil
        }
        let spine = playbackModel.audiobookManager.audiobook.spine
        for index in 0..<spine.count {
            if currentLocation.inSameChapter(other: spine[index].chapter) {
                return String(index + 1)
            }
        }
        return nil
    }
    
    private var playbackRateText: String {
        if playbackModel.audiobookManager.audiobook.player.playbackRate == .normalTime {
            return NSLocalizedString("1.0×",
                                     bundle: Bundle.audiobookToolkit()!,
                                     value: "1.0×",
                                     comment: "Default title to explain that button changes the speed of playback.")
        } else {
            return HumanReadablePlaybackRate(rate: playbackModel.audiobookManager.audiobook.player.playbackRate).value
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
        String(format: DisplayStrings.timeToPause, VoiceOverTimestamp(timeInterval: playbackModel.audiobookManager.sleepTimer.timeRemaining)) :
        DisplayStrings.sleepTimer
    }
    
    private var playbackRateDescription: String {
        HumanReadablePlaybackRate(rate: playbackModel.audiobookManager.audiobook.player.playbackRate).accessibleDescription
    }
    
    private var playheadOffsetText: String {
        HumanReadableTimestamp(timeInterval: playbackModel.offset).timecode
    }
    
    private var timeLeftText: String {
        HumanReadableTimestamp(timeInterval: playbackModel.timeLeft).timecode
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
                .default(Text(HumanReadablePlaybackRate(rate: playbackRate).value), action: { playbackModel.setPlaybackRate(playbackRate)
                })
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
        case .endOfChapter: return DisplayStrings.endOfChapter
        case .oneHour: return DisplayStrings.oneHour
        case .thirtyMinutes: return DisplayStrings.thirtyMinutes
        case .fifteenMinutes: return DisplayStrings.fifteenMinutes
        case .never: return DisplayStrings.off
        }
    }
}

// MARK: - Preview

extension AudiobookPlayerView {
    // Preview init
    // This resource must be available to PalaceAudiobookToolkit module
    fileprivate init?() {
        guard let resource = Bundle.audiobookToolkit()?.url(forResource: "alice_manifest", withExtension: "json"),
              let audiobookData = try? Data(contentsOf: resource),
              let audiobookJSON = try? JSONSerialization.jsonObject(with: audiobookData) as? [String: Any],
              let audiobook = OpenAccessAudiobook(JSON: audiobookJSON, token: nil) else
        {
            return nil
        }
        let audiobookManager = DefaultAudiobookManager(
            metadata: AudiobookMetadata(title: "Test book title", authors: ["Author One", "Author Two"]),
            audiobook: audiobook
        )
        self.playbackModel = AudiobookPlaybackModel(audiobookManager: audiobookManager)
    }
}

struct AudiobookPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        AudiobookPlayerView()
    }
}

// MARK: - Controls

/// Airplay button
struct AVRoutePickerViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        return picker
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        //
    }
}

/// Airplay button wrapper
struct AVRoutePickerViewWrapper: View {
    var body: some View {
        AVRoutePickerViewRepresentable()
            .frame(width: 30, height: 30)
    }
}

/// Playback slider
///
struct PlaybackSliderView: View {
    @Binding var value: Double
    @State private var tempValue: Double?
    var onChange: (_ value: Double) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray)
                    .frame(height: trackHeight)
                
                Rectangle()
                    .fill(Color( .label))
                    .frame(width: offsetX(in: geometry.size, for: tempValue ?? value), height: trackHeight)
                
                Capsule()
                    .fill(Color.red)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .offset(x: offsetX(in: geometry.size, for: tempValue ?? value))
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let newValue = max(0, min(1, Double(gesture.location.x / geometry.size.width)))
                                tempValue = newValue
                            }
                            .onEnded { _ in
                                if let finalValue = tempValue {
                                    value = finalValue
                                    onChange(finalValue)
                                    tempValue = nil
                                }
                            }
                    )
            }
        }
        .frame(height: thumbHeight)
    }
    
    private func offsetX(in size: CGSize, for value: Double) -> CGFloat {
        CGFloat(value) * (size.width - thumbWidth)
    }
    
    // MARK: - View configuration
    private let thumbWidth: CGFloat = 10
    private let thumbHeight: CGFloat = 36
    private let trackHeight: CGFloat = 10
}

struct ToolkitImage: View {
    let name: String
    var uiImage: UIImage? = nil
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
