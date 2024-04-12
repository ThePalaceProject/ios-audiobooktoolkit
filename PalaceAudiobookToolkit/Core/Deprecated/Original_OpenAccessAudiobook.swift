//final class Original_OpenAccessAudiobook: Original_Audiobook {
//    let player: OriginalPlayer
//    var spine: [SpineElement]
//    let uniqueIdentifier: String
//    var token: String? = nil
//    var annotationsId: String { uniqueIdentifier }
//
//    private var drmData: [String: Any]
//    
//    var drmStatus: DrmStatus {
//        get {
//            // Avoids force unwrapping
//            // Should be save since the initializer should always set this value
//            // Access to `drmData` is private and can only be modified by internal code
//            return (drmData["status"] as? DrmStatus) ?? DrmStatus.succeeded
//        }
//        set {
//            drmData["status"] = newValue
//            player.isDrmOk = (DrmStatus.succeeded == newValue)
//        }
//    }
//
//    @available(*, deprecated, message: "Use init?(JSON: Any?, token: String?) instead")
//    public required convenience init?(JSON: Any?, audiobookId: String?) {
//        self.init(JSON: JSON, token: nil)
//    }
//
//    public init?(JSON: Any?, token: String?) {
//        drmData = [String: Any]()
//        drmData["status"] = DrmStatus.succeeded
//        guard let payload = JSON as? [String: Any],
//        let metadata = payload["metadata"] as? [String: Any],
//        let identifier = metadata["identifier"] as? String,
//        let payloadSpine = ((payload["readingOrder"] as? [Any]) ?? (payload["spine"] as? [Any])) else {
//            ATLog(.error, "OpenAccessAudiobook failed to init from JSON: \n\(JSON ?? "nil")")
//            return nil
//        }
//        self.token = token
//
//        // Feedbook DRM Check
//        if !FeedbookDRMProcessor.processManifest(payload, drmData: &drmData) {
//            ATLog(.error, "FeedbookDRMProcessor failed to pass JSON: \n\(JSON ?? "nil")")
//            return nil
//        }
//
//        let mappedSpine: [OpenAccessSpineElement] = payloadSpine.enumerated().compactMap { (tupleItem:(offset: Int, element: Any)) -> OpenAccessSpineElement? in
//            do {
//                return try OpenAccessSpineElement(
//                    JSON: tupleItem.element,
//                    index: UInt(tupleItem.offset),
//                    audiobookID: identifier,
//                    token: token
//                )
//            } catch {
//                ATLog(.error, "Failed to map element at index \(tupleItem.offset): \(error.localizedDescription)")
//                return nil
//            }
//        }.sorted { $0.chapterNumber < $1.chapterNumber }
//    
//        if (mappedSpine.count == 0 || mappedSpine.count != payloadSpine.count) {
//            ATLog(.error, "Failure to create any or all spine elements from the manifest.")
//            return nil
//        }
//        self.spine = mappedSpine
//        self.uniqueIdentifier = identifier
//        guard let cursor = Cursor(data: self.spine) else {
//            ATLog(.error, "Cursor could not be cast to Cursor<OpenAccessSpineElement>")
//            return nil
//        }
//        self.player = OriginalOpenAccessPlayer(cursor: cursor, audiobookID: uniqueIdentifier, drmOk: (drmData["status"] as? DrmStatus) == DrmStatus.succeeded)
//    }
//
//    public func deleteLocalContent() {
//        for element in self.spine {
//            let task = element.downloadTask
//            task.delete()
//        }
//    }
//    
//    public func checkDrmAsync() {
//        FeedbookDRMProcessor.performAsyncDrm(book: self, drmData: drmData)
//    }
//}
