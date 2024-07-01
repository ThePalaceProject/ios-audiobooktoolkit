//
//  AudiobookNetworkService.swift
//  NYPLAudiobookToolkitTests
//
//  Created by Dean Silfen on 3/5/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit
import Combine

class AudiobookNetworkServiceTest: XCTestCase {
    
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() {
        super.setUp()
        cancellables = []
    }
    
    override func tearDown() {
        cancellables = nil
        super.tearDown()
    }
    
    func testDownloadProgressWithEmptyTracks() {
        let service = DefaultAudiobookNetworkService(tracks: [])
        let expectation = XCTestExpectation(description: "Expect no download state updates")
        
        service.downloadStatePublisher
            .sink(receiveValue: { state in
                XCTFail("Should not receive any download state updates")
            })
            .store(in: &cancellables)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2)
    }
    
    func testDownloadProgressWithTwoTracks() {
        // Prepare
        let track1 = TrackMock(progress: 0.50, key: "track1")
        let track2 = TrackMock(progress: 0.25, key: "track2")
        
        let service = DefaultAudiobookNetworkService(tracks: [track1, track2])
        let expectation = XCTestExpectation(description: "Expect correct overall download progress")
        
        // This will collect all progress updates
        var receivedProgress: [Float] = []
        
        // Observe changes
        service.downloadStatePublisher
            .sink(receiveValue: { state in
                switch state {
                case .overallProgress(let progress):
                    receivedProgress.append(progress)
                    if receivedProgress.contains(0.375) {
                        expectation.fulfill()
                    }
                default:
                    break
                }
            })
            .store(in: &self.cancellables)
        
        // Simulate fetch sequentially
        DispatchQueue.global().async {
            track1.simulateProgressUpdate(0.50)
            track2.simulateProgressUpdate(0.25)
        }
        
        // Wait for the results
        wait(for: [expectation], timeout: 5)
    }
}


extension AudiobookNetworkServiceTest {
    class TrackMock: Track {
        var key: String
        var downloadTask: DownloadTask?
        var title: String?
        var index: Int = 0
        var duration: TimeInterval = 0
        var partNumber: Int?
        var chapterNumber: Int?
        var urls: [URL]?
        
        required convenience init(
            manifest: PalaceAudiobookToolkit.Manifest,
            urlString: String?,
            audiobookID: String,
            title: String?,
            duration: Double,
            index: Int,
            token: String?,
            key: String?
        ) throws {
            self.init(progress: 0.0, key: title ?? "")
        }
        
        init(progress: Float, key: String) {
            self.key = key
            self.downloadTask = DownloadTaskMock(progress: progress, key: key, fetchClosure: nil)
        }
        
        func simulateProgressUpdate(_ progress: Float) {
            (downloadTask as? DownloadTaskMock)?.simulateProgress(progress)
        }
    }
    
    class DownloadTaskMock: DownloadTask {
        var statePublisher = PassthroughSubject<DownloadTaskState, Never>()
        var downloadProgress: Float
        var key: String
        var fetchClosure: ((DownloadTaskMock) -> Void)?
        var needsRetry: Bool = false

        init(progress: Float, key: String, fetchClosure: ((DownloadTaskMock) -> Void)?) {
            self.downloadProgress = progress
            self.key = key
            self.fetchClosure = fetchClosure
        }
        
        func fetch() {
            fetchClosure?(self)
        }
        
        func delete() {
            statePublisher.send(.deleted)
        }
        
        func simulateProgress(_ progress: Float) {
            statePublisher.send(.progress(progress))
        }
    }
}

extension Manifest {
    static var mockManifest: Manifest {
        try! Manifest.from(jsonFileName: ManifestJSON.flatland.rawValue, bundle: Bundle(for: AudiobookNetworkServiceTest.self))
    }
}


