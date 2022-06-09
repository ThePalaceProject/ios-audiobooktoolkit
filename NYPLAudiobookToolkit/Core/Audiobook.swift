//
//  Audiobook.swift
//  NYPLAudibookKit
//
//  Created by Dean Silfen on 1/12/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

@objc public enum DrmStatus:Int {
    public typealias RawValue = Int
    case failed
    case processing
    case succeeded
}

/// DRM Decryptor protocol - decrypts protected files
@objc public protocol DRMDecryptor {

    /// Decrypt protected file
    /// - Parameters:
    ///   - url: encrypted file URL.
    ///   - resultUrl: URL to save decrypted file at.
    ///   - completion: decryptor callback with optional `Error`.
    func decrypt(url: URL, to resultUrl: URL, completion: @escaping (_ error: Error?) -> Void)
}

@objc public protocol SpineElement: class {
    var key: String { get }
    var downloadTask: DownloadTask { get }
    var chapter: ChapterLocation { get }
}

@objc public protocol Audiobook: class {
    var uniqueIdentifier: String { get }
    var spine: [SpineElement] { get }
    var player: Player { get }
    var drmStatus: DrmStatus { get set }
    func checkDrmAsync()
    func deleteLocalContent()
    init?(JSON: Any?)
}

public enum AudiobookType {
    case FindAway(JSON: Any)
    case Overdrive(JSON: Any)
    case LCP(JSON: Any, decryptor: DRMDecryptor)
    case OpenAccess(JSON: Any, token: String?)
}

/// Host app should instantiate a audiobook object with an AudiobookType with associated JSON,
/// decryptor or tokens
/// This audiobook should then be able to construct utility classes
/// using data in the spine of that JSON.
@objcMembers public final class AudiobookFactory: NSObject {
    public static func audiobook(_ type: AudiobookType) -> Audiobook? {
        let audiobook: Audiobook?

        switch type {
        case .FindAway(let JSON):
            let FindawayAudiobookClass = NSClassFromString("NYPLAEToolkit.FindawayAudiobook") as? Audiobook.Type
            audiobook = FindawayAudiobookClass?.init(JSON: JSON)
        case .Overdrive(let JSON):
            audiobook = OverdriveAudiobook(JSON: JSON)
        case .LCP(let JSON, let decryptor):
            audiobook = LCPAudiobook(JSON: JSON, decryptor: decryptor)
        case .OpenAccess(let JSON, let token):
            audiobook = OpenAccessAudiobook(JSON: JSON, token: token)
        }

        ATLog(.debug, "checkDrmAsync")
        audiobook?.checkDrmAsync()
        return audiobook
    }
}
