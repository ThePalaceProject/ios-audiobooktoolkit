//
//  ChapterCell.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/7/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct ChapterCell: View {
    @ObservedObject var viewModel: TrackDownloadViewModel
    
    var body: some View {
        HStack {
            Text(viewModel.track.title ?? "Unknown Title")
                .palaceFont(.body)
            Spacer()
            if let _ = viewModel.downloadError {
                Text("Download Error").palaceFont(.body)
            } else if viewModel.downloadProgress > 0 && viewModel.downloadProgress < 1 {
                Text("Downloading... \((viewModel.downloadProgress * 100, specifier: "%.0f"))%").palaceFont(.body)
            } else {
                Text(HumanReadableTimestamp(timeInterval: viewModel.track.duration).timecode)
                    .accessibility(label: Text(HumanReadableTimestamp(timeInterval: viewModel.track.duration).accessibleDescription))
                    .palaceFont(.body)

            }
        }
    }
    
    init(track: Track) {
        self.viewModel = TrackDownloadViewModel(track: track)
    }
}

class TrackDownloadViewModel: ObservableObject {
    @Published var downloadProgress: Float = 0
    @Published var downloadError: Error? = nil
    private var cancellables: Set<AnyCancellable> = []
    
    let track: Track
    
    init(track: Track) {
        self.track = track
        track.downloadTask?.statePublisher
            .receive(on: RunLoop.main)
            .sink(receiveValue: { [weak self] state in
                switch state {
                case .progress(let progress):
                    self?.downloadProgress = progress
                case .error(let error):
                    self?.downloadError = error
                default:
                    break
                }
            })
            .store(in: &cancellables)
    }
}
