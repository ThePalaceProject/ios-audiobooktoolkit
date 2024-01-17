//
//  AudiobookTOCView.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 11/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

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
    @Binding var selectedLocation: ChapterLocation
    @State private var selectedSection: NavigationSection = .toc
    @State private var bookmarks: [ChapterLocation] = []
    
    @ObservedObject private var playback: AudiobookPlaybackModel
    init(model: AudiobookPlaybackModel, selectedLocation: Binding<ChapterLocation>) {
        self.playback = model
        self._selectedLocation = selectedLocation
    }
    
    var body: some View {
        VStack(spacing: 0) {
            navigationPicker
            switch selectedSection {
            case .toc: chaptersList
            case .bookmarks: bookmarksList
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarItems(leading: backButton)
    }
    
    @ViewBuilder
    private var backButton: some View {
        Button {
            presentationMode.wrappedValue.dismiss()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Back")
                    .palaceFont(.body)
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
            ForEach(playback.spine, id: \.key) { spineElement in
                chapterCell(for: spineElement)
                    .onTapGesture {
                        if playback.spineErrors[spineElement.key] != nil {
                            spineElement.downloadTask.fetch()
                        } else {
                            selectedLocation = spineElement.chapter
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
            }
        }
        .listStyle(.plain)
    }
    
    @ViewBuilder
    private func chapterCell(for element: SpineElement) -> some View {
        let progress = element.downloadTask.downloadProgress
        HStack {
            Text(element.chapter.title ?? "")
                .palaceFont(.body)
            Spacer()
            if playback.spineErrors[element.key] != nil {
                Text("Download Error")
                    .palaceFont(.body)
            } else if progress > 0 && progress < 1 {
                Text(
                    String(format: Strings.Generic.downloadingFormatted, HumanReadablePercentage(percentage: progress).value)
                )
                .palaceFont(.body)
            } else {
                Text(HumanReadableTimestamp(timeInterval: element.chapter.duration).timecode)
                    .accessibility(label: Text(HumanReadableTimestamp(timeInterval: element.chapter.duration).accessibleDescription))
                    .palaceFont(.body)
            }
        }
        .contentShape(Rectangle())
        .opacity(progress < 1 ? 0.4 : 1)
    }
    
    @ViewBuilder
    private var bookmarksList: some View {
        Group {
            if self.bookmarks.isEmpty {
                ScrollView {
                    VStack {
                        Text(NSLocalizedString("There are no bookmarks for this book.", comment: ""))
                            .palaceFont(.body)
                            .padding(.top, 200)
                    }
                }
                .refreshable {
                    playback.audiobookManager.fetchBookmarks { bookmarks in
                        self.bookmarks = bookmarks
                    }
                }
            } else {
                List {
                    ForEach(self.bookmarks, id: \.annotationId) { bookmark in
                        bookmarkCell(for: bookmark)
                            .onTapGesture {
                                selectedLocation = bookmark
                                presentationMode.wrappedValue.dismiss()
                            }
                    }
                    .onDelete { indexSet in
                        for index in indexSet.reversed() {
                            if let bookmark = playback.audiobookManager.audiobookBookmarks[safe: index] {
                                playback.audiobookManager.deleteBookmark(at: bookmark) { _ in }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    playback.audiobookManager.fetchBookmarks { bookmarks in
                        self.bookmarks = bookmarks
                    }
                }
            }
        }
        .onAppear {
            playback.audiobookManager.fetchBookmarks { bookmarks in
                self.bookmarks = bookmarks
            }
        }
    }
    
    @ViewBuilder
    private func bookmarkCell(for bookmark: ChapterLocation) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text(bookmark.title ?? "")
                    .lineLimit(1)
                    .palaceFont(.body)
                Text(DateFormatter.convertISO8601String(bookmark.lastSavedTimeStamp) ?? "")
                    .lineLimit(1)
                    .palaceFont(.subheadline, weight: .regular)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(
                DateFormatter.bookmarkTimeFormatter.string(from: Date(timeIntervalSinceReferenceDate: bookmark.actualOffset))
            )
            .palaceFont(.body)
            .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

extension AudiobookNavigationView {
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
        let bookmark = ChapterLocation(number: 0, part: 1, duration: 135, startOffset: nil, playheadOffset: 185, title: "Chapter One", audiobookID: "")
        bookmark.lastSavedTimeStamp = "2023-01-01T12:34:56Z"
        audiobookManager.audiobookBookmarks.append(bookmark)
        self._selectedLocation = .constant(.emptyLocation)
    }
}


struct AudiobookNavigationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AudiobookNavigationView()
        }
    }
}
