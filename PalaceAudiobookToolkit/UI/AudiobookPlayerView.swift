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

struct AudiobookPlayerView: View {
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    @State private var uiTabarController: UITabBarController?
    private let skipTimeInterval: TimeInterval = 15
    
    @ObservedObject var playback: AudiobookPlaybackModel
    @State private var selectedLocation: ChapterLocation = .emptyLocation
    @ObservedObject private var showToast = BoolWithDelay(delay: 3)
    @State private var toastMessage: String = ""
    
    init(model: AudiobookPlaybackModel) {
        self.playback = model
    }
        
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 15) {
                Group {
                    downloadProgressView(value: playback.overallDownloadProgress)
                    
                    VStack {
                        Text(playback.audiobookManager.metadata.title ?? "")
                            .font(.headline)
                        Text((playback.audiobookManager.metadata.authors ?? []).joined(separator: ", "))
                    }
                    
                    VStack(spacing: 5) {
                        Text(timeLeftInBookText)
                            .font(.caption)
                        
                        PlaybackSliderView(value: playback.playbackProgress) { newValue in
                            playback.move(to: newValue)
                        }
                        .padding(.horizontal)
                        
                        ZStack {
                            HStack {
                                Text("\(playheadOffsetText)")
                                    .font(.caption)
                                Spacer()
                                Text("\(timeLeftText)")
                                    .font(.caption)
                            }
                            Text(chapterTitle)
                                .font(.headline)
                        }
                        .padding(.horizontal)
                    }
                    
                    Spacer()
                    
                    ToolkitImage(name: "example_cover", uiImage: playback.coverImage)
                        .padding(.horizontal)
                }
                .animation(.easeInOut(duration: 0.2), value: playback.isDownloading)
                
                Spacer()
                
                HStack(spacing: 40) {
                    skipButton("skip_back", textLabel: "", action: playback.skipBack)
                    playButton(isPlaying: playback.isPlaying, textLabel: "", action: playback.playPause)
                    skipButton("skip_forward", textLabel: "", action: playback.skipForward)
                }
                .frame(height: 66)
                .padding(.bottom)
                
                VStack {
                    HStack {
                        Text(playbackRateText)
                        Spacer()
                        AVRoutePickerViewWrapper()
                        Spacer()
                        Button {
                            
                            
                        } label: { Text("☾") }
                        Spacer()
                        Button {
                            playback.addBookmark { error in
                                showToast(message: error == nil ? "Bookmark saved" : (error as? BookmarkError)?.localizedDescription ?? "")
                            }
                        } label: {
                            ToolkitImage(name: "bookmark", renderingMode: .template)
                                .frame(maxHeight: 20)
                        }
                    }
                    .padding(.horizontal)
                    .foregroundColor(.white)
                    .padding()
                }
                .background(
                    Rectangle()
                        .fill(Color(.darkGray))
                        .edgesIgnoringSafeArea([.bottom])
                )
            }
            .navigationBarTitle(Text(""), displayMode: .inline)
            .navigationBarItems(trailing: tocButton)
            .onChange(of: selectedLocation) { newValue in
                playback.audiobookManager.audiobook.player.playAtLocation(newValue) { error in
                    // present error
                }
            }
            
            bookmarkAddedToastView
        }
    }
    
    private func showToast(message: String) {
        toastMessage = message
        showToast.value = true
    }
    
    // MARK: - Controls
    
    @ViewBuilder
    private var tocButton: some View {
        NavigationLink {
            AudiobookNavigationView(model: playback, selectedLocation: $selectedLocation)
        } label: {
            ToolkitImage(name: "table_of_contents", renderingMode: .template)
                .accessibility(label: Text("Table of contents"))
                .foregroundColor(.primary)
                .foregroundColor(.black)
        }
    }
    
    @ViewBuilder
    private func skipButton(_ imageName: String, textLabel: String, action: @escaping () -> Void) -> some View {
        // Button size: 66 compact, 96 regular
        let size: CGFloat = horizontalSizeClass == .compact ? 66 : 96
        Button(action: action) {
            ToolkitImage(name: imageName, renderingMode: .template)
                .overlay(
                    VStack(spacing: -4) {
                        Text("\(Int(skipTimeInterval))")
                            .font(.system(size: 20))
                            .offset(x: -1)
                        Text("sec")
                            .font(.caption)
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
                Text("\(Int(value))%")
            }
            .font(.caption)
            .padding(8)
            .foregroundColor(.white)
            .background(Color.black)
        }
        .frame(maxWidth: .infinity)
        .frame(height: playback.isDownloading ? nil : 0)
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
        .font(.subheadline)
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
    
    // MARK: - Property labels

    typealias DisplayStrings = Strings.AudiobookPlayerViewController
    
    var chapterTitle: String {
        guard let currentLocation = playback.currentLocation else {
            return "--"
        }
        let defaultTitleFormat = DisplayStrings.trackAt
        let indexString = oneBasedSpineIndex() ?? "--"
        return currentLocation.title ?? String(format: defaultTitleFormat, indexString)
    }
    
    private func oneBasedSpineIndex() -> String? {
        guard let currentLocation = playback.currentLocation else {
            return nil
        }
        let spine = playback.audiobookManager.audiobook.spine
        for index in 0..<spine.count {
            if currentLocation.inSameChapter(other: spine[index].chapter) {
                return String(index + 1)
            }
        }
        return nil
    }
    
    var playbackRateText: String {
        HumanReadablePlaybackRate(rate: playback.audiobookManager.audiobook.player.playbackRate).value
    }
    
    var playbackRateDescription: String {
        HumanReadablePlaybackRate(rate: playback.audiobookManager.audiobook.player.playbackRate).accessibleDescription
    }
    
    var playheadOffsetText: String {
        HumanReadableTimestamp(timeInterval: playback.offset).timecode
    }
    
    var timeLeftText: String {
        HumanReadableTimestamp(timeInterval: playback.timeLeft).timecode
    }
    
    var timeLeftInBookText: String {
        let timeLeft = HumanReadableTimestamp(timeInterval: playback.timeLeftInBook).stringDescription
        let formatString = Strings.ScrubberView.timeRemaining
        return String(format: formatString, timeLeft)
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
        self.playback = AudiobookPlaybackModel(audiobookManager: audiobookManager)
    }
}

struct AudiobookPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AudiobookPlayerView()
        }
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
    var value: Double
    var onChange: (_ value: Double) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray)
                    .frame(height: trackHeight)
                
                Rectangle()
                    .fill(Color( .label))
                    .frame(width: offsetX(in: geometry.size, for: value), height: trackHeight)
                
                Capsule()
                    .fill(Color.red)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .offset(x: offsetX(in: geometry.size, for: value))
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let value = max(0, min(1, Double(gesture.location.x / (geometry.size.width - thumbWidth) )))
                                onChange(value)
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
