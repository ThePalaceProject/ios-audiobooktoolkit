//
//  AudiobookTOCView.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 11/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
// import PalaceUIKit // Not available in audiobook toolkit

struct AudiobookNavigationView: View {
    typealias DisplayStrings = Strings.AudiobookTableOfContentsTableViewController
    
    enum NavigationSection: Identifiable, CaseIterable {
        case toc, bookmarks
        
        var id: Int {
            self.hashValue
        }
        
        var name: String {
            switch self {
            case .toc: return DisplayStrings.chapters
            case .bookmarks: return DisplayStrings.bookmarks
            }
        }
    }
    
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedSection: NavigationSection = .toc
    @State private var bookmarks: [TrackPosition] = []
    @State private var isLoading: Bool = false
    
    @ObservedObject private var playback: AudiobookPlaybackModel
    init(model: AudiobookPlaybackModel) {
        self.playback = model
    }
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if playback.audiobookManager.needsDownloadRetry {
                    RetryToolbar(retryAction: playback.audiobookManager.retryDownload)
                }
                navigationPicker
                switch selectedSection {
                case .toc: chaptersList
                case .bookmarks: bookmarksList
                }
            }
            .navigationBarBackButtonHidden(true)
            .navigationBarItems(leading: backButton)
            
            if isLoading {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.top, 200)
                    Spacer()
                }
            }
        }
    }
    
    @ViewBuilder
    private var backButton: some View {
        Button {
            presentationMode.wrappedValue.dismiss()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Back")
                    .font(.body)
            }
        }
        .foregroundColor(Color(.label))
        .padding(.leading, -6)
    }
    
    @ViewBuilder
    private var navigationPicker: some View {
        Picker("", selection: $selectedSection) {
            ForEach(NavigationSection.allCases) { value in
                Text(value.name)
                    .tag(value)
            }
        }
        .pickerStyle(.segmented)
        .padding()
    }
    
    @ViewBuilder
    private var chaptersList: some View {
        List {
            ForEach(playback.audiobookManager.audiobook.tableOfContents.toc) { chapter in
                ChapterCell(chapter: chapter) {
                    playback.selectedLocation = chapter.position
                    presentationMode.wrappedValue.dismiss()
                }
                .frame(height: 40)
                .opacity(playback.downloadProgress(for: chapter) < 1.0 ? 0.85 : 1.0)
            }
        }
        .listStyle(.plain)
    }
    
    @ViewBuilder
    private var bookmarksList: some View {
        Group {
            if self.bookmarks.isEmpty {
                ScrollView {
                    VStack {
                        Text(NSLocalizedString("There are no bookmarks for this book.", comment: ""))
                            .font(.body)
                            .padding(.top, 200)
                            .opacity(isLoading ? 0.0 : 1.0)
                    }
                }
                .refreshable {
                    fetchBookmarks(showLoading: false)
                }
            } else {
                List {
                    ForEach(self.bookmarks, id: \.timestamp) { bookmark in
                        bookmarkCell(for: bookmark) {
                            playback.selectedLocation = bookmark
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet.reversed() {
                            if let bookmark = playback.audiobookManager.bookmarks[safe: index] {
                                self.bookmarks.removeAll { $0 == bookmark }
                                playback.audiobookManager.deleteBookmark(at: bookmark) { _ in
                                    fetchBookmarks(showLoading: false)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    fetchBookmarks(showLoading: false)
                }
            }
        }
        .onAppear {
            fetchBookmarks()
        }
    }
    
    private func fetchBookmarks(showLoading: Bool = true) {
        isLoading = showLoading
        playback.audiobookManager.fetchBookmarks { bookmarks in
            self.bookmarks = bookmarks
            self.isLoading = false
        }
    }
    
    func title(for position: TrackPosition) -> String {
        (try? playback.audiobookManager.audiobook.tableOfContents.chapter(forPosition: position).title) ?? position.track.title ?? ""
    }
    
    @ViewBuilder
    private func bookmarkCell(for position: TrackPosition, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading) {
                    Text(title(for: position))
                        .lineLimit(1)
                        .font(.body)
                    Text(DateFormatter.convertISO8601String(position.lastSavedTimeStamp) ?? "")
                        .lineLimit(1)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(
                    DateFormatter.bookmarkTimeFormatter.string(from: Date(timeIntervalSinceReferenceDate: position.timestamp))
                )
                .font(.body)
                .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Preview

extension AudiobookNavigationView {
    // Preview init
    // This resource must be available to PalaceAudiobookToolkit module
    fileprivate init?() {
        guard let resource = Bundle.audiobookToolkit()?.url(forResource: "alice_manifest", withExtension: "json"),
              let audiobookData = try? Data(contentsOf: resource),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: audiobookData),
              let audiobook = OpenAccessAudiobook(manifest: manifest, bookIdentifier: "test_book_id", token: nil) else
        {
            return nil
        }
        let audiobookManager = DefaultAudiobookManager(
            metadata: AudiobookMetadata(title: "Test book title", authors: ["Author One", "Author Two"]),
            audiobook: audiobook,
                networkService: DefaultAudiobookNetworkService(tracks: audiobook.tableOfContents.allTracks, decryptor: audiobook.player is LCPPlayer ? (audiobook.player as? LCPPlayer)?.decryptionDelegate : nil)
        )
        self.playback = AudiobookPlaybackModel(audiobookManager: audiobookManager)
        var bookmark = TrackPosition(track: audiobook.player.tableOfContents.tracks.first!, timestamp: 0.0, tracks: audiobook.player.tableOfContents.tracks)
        bookmark.lastSavedTimeStamp = "2023-01-01T12:34:56Z"
        audiobookManager.bookmarks.append(bookmark)
        playback.selectedLocation = bookmark
    }
}

struct AudiobookNavigationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AudiobookNavigationView()
        }
    }
}
