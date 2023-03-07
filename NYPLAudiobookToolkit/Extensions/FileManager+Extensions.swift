import AVFoundation
import Swift

extension FileManager {
    static func mergeAudioFiles(audioFileUrls: [URL], lastTrackDuration: Double) async -> URL? {
        return await withCheckedContinuation{ continuation in
            let composition = AVMutableComposition()

            for (index, url) in audioFileUrls.enumerated() {
                guard let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: AVMediaType.audio,
                    preferredTrackID: CMPersistentTrackID()) else {
                    continuation.resume(returning: nil)
                    return
                }

                let asset = AVURLAsset(url: url)
                let trackContainer = asset.tracks(withMediaType: AVMediaType.audio)
                
                guard let audioTrack = trackContainer.first else {
                    continuation.resume(returning: nil)
                    return
                }

                let finalDuration = CMTimeMake(value: Int64(lastTrackDuration), timescale: 600)
                var duration = index == audioFileUrls.count - 1 ? finalDuration : audioTrack.timeRange.duration
                let timeRange = CMTimeRange(start: CMTimeMake(value: 0, timescale: 600), duration: duration)
                try? compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: composition.duration)
            }

            let finalUrl = URL(string: "\(getDocumentsDirectory())\(UUID().uuidString)_audio.m4a")

            let assetExport = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
            assetExport?.outputFileType = AVFileType.m4a
            assetExport?.outputURL = finalUrl
            assetExport?.exportAsynchronously {
                continuation.resume(returning: finalUrl)
            }
        }
    }

    /**
     Get the set document directory for the application
     */
    static func getDocumentsDirectory() -> URL {
        let paths = Self.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }

    /**
     get filename from a given file url or path
     - parameter fileUrl: file path to be extracted
     - returns: filename : String
     */
    func getFileName(_ fileUrl : String) -> String{
        return URL(string: fileUrl)!.lastPathComponent
    }
    
}
