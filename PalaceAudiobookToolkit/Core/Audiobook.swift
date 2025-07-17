//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared

public enum DRMStatus: Int {
    public typealias RawValue = Int
    case failed
    case processing
    case succeeded
    case unknown
}

/// DRM Decryptor protocol - decrypts protected files
@objc public protocol DRMDecryptor {
    /// After you’ve opened the manifest, this returns the Readium Publication
    /// Decrypt protected file
    /// - Parameters:
    ///   - url: encrypted file URL.
    ///   - resultUrl: URL to save decrypted file at.
    ///   - completion: decryptor callback with optional `Error`.
    func decrypt(url: URL, to resultUrl: URL, completion: @escaping (_ error: Error?) -> Void)
}

public protocol LCPStreamingProvider: DRMDecryptor {
  /// After you’ve opened the manifest, this returns the Readium Publication
  func getPublication() -> Publication?
  /// The HTTP-range retriever to use for on‐demand streaming
  func getHTTPRangeRetriever() -> HTTPRangeRetriever
}

public struct AudiobookFactory {
    public static func audiobookClass(
        for manifest: Manifest
    ) -> Audiobook.Type {
        switch manifest.audiobookType {
        case .findaway:
            return FindawayAudiobook.self
        default:
            return OpenAccessAudiobook.self
        }
    }

    public static func audiobook(
        for manifest: Manifest,
        bookIdentifier: String,
        decryptor: DRMDecryptor?,
        token: String?
    ) -> Audiobook? {
        let cls = audiobookClass(for: manifest)
        return cls.init(
            manifest: manifest,
            bookIdentifier: bookIdentifier,
            decryptor: decryptor,
            token: token
        )
    }
}

open class Audiobook: NSObject {
    public var uniqueId: String
    public var annotationsId: String { uniqueId }
    public var tableOfContents: AudiobookTableOfContents
    public var player: Player
    public var drmStatus: DRMStatus {
        get {
            return DRMStatus.succeeded
        }
        set(newStatus) {
            player.isDrmOk = newStatus == DRMStatus.succeeded
        }
    }

    public required init?(manifest: Manifest, bookIdentifier: String, decryptor: DRMDecryptor?, token: String?) {
        self.uniqueId = bookIdentifier
        
        let tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: token)
        self.tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
     
        let playerFactory = DynamicPlayerFactory()
        self.player = playerFactory.createPlayer(
            forType: manifest.audiobookType,
            withTableOfContents: tableOfContents,
            decryptor: decryptor
        )

        super.init()
    }
    
    open func checkDrmAsync() {}
    
    public class func deleteLocalContent(manifest: Manifest, bookIdentifier: String, token: String? = nil) {
        let tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: token)
        let tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
        tableOfContents.tracks.deleteTracks()
    }
    
    open func update(manifest: Manifest, bookIdentifier: String, token: String?) {
        let tracks = Tracks(manifest: manifest, audiobookID: bookIdentifier, token: token)
        self.tableOfContents = AudiobookTableOfContents(manifest: manifest, tracks: tracks)
    }
}


protocol PlayerFactoryProtocol {
    func createPlayer(forType type: Manifest.AudiobookType, withTableOfContents toc: AudiobookTableOfContents, decryptor: DRMDecryptor?) -> Player
}

class DynamicPlayerFactory: PlayerFactoryProtocol {
    func createPlayer(forType type: Manifest.AudiobookType, withTableOfContents toc: AudiobookTableOfContents, decryptor: DRMDecryptor?) -> Player {
        ATLog(.debug, "[LCPStreaming] Creating player for audiobook type: \(type)")
        
        switch type {
        case .lcp:
            ATLog(.debug, "[LCPStreaming] Identified as LCP audiobook, creating LCP player")
            return createLCPPlayer(tableOfContents: toc, decryptor: decryptor)
        case .findaway:
            ATLog(.debug, "[LCPStreaming] Identified as Findaway audiobook")
            return FindawayPlayer(tableOfContents: toc) ?? OpenAccessPlayer(tableOfContents: toc)
        default:
            ATLog(.debug, "[LCPStreaming] Using default OpenAccess player for type: \(type)")
            return OpenAccessPlayer(tableOfContents: toc)
        }
    }
    

    private func createLCPPlayer(tableOfContents: AudiobookTableOfContents, decryptor: DRMDecryptor?) -> Player {
        ATLog(.debug, "[LCPStreaming] Creating LCP player, checking if streaming is enabled")
        
        // Check if we should use streaming for LCP audiobooks
        if LCPStreamingDownloadTask.isStreamingEnabled() {
            ATLog(.debug, "[LCPStreaming] Streaming is enabled, attempting to create streaming player")
            return createStreamingLCPPlayer(tableOfContents: tableOfContents, decryptor: decryptor)
        } else {
            ATLog(.debug, "[LCPStreaming] Streaming is disabled, using traditional LCP player")
            // Use traditional LCP player
            return LCPPlayer(tableOfContents: tableOfContents, decryptor: decryptor)
        }
    }
    
    private func createStreamingLCPPlayer(
      tableOfContents: AudiobookTableOfContents,
      decryptor: DRMDecryptor?
    ) -> Player {
      ATLog(.debug, "[LCPStreaming] Attempting to create streaming LCP player")
      
      guard let decryptor = decryptor else {
        ATLog(.error, "[LCPStreaming] no decryptor—falling back")
        return LCPPlayer(tableOfContents: tableOfContents, decryptor: nil)
      }
      
      ATLog(.debug, "[LCPStreaming] Decryptor provided, checking LCPStreamingProvider conformance")

      // look for the streaming‐provider conformance, not a concrete class
      if let streaming = decryptor as? LCPStreamingProvider {
        ATLog(.debug, "[LCPStreaming] Decryptor conforms to LCPStreamingProvider")
        
        if let publication = streaming.getPublication() {
          ATLog(.debug, "[LCPStreaming] Publication available, creating streaming player")
          return LCPStreamingPlayer(
            tableOfContents: tableOfContents,
            decryptor: decryptor,
            publication: publication,
            rangeRetriever: streaming.getHTTPRangeRetriever()
          )
        } else {
          ATLog(.warn, "[LCPStreaming] LCPStreamingProvider has no publication—falling back")
        }
      } else {
        ATLog(.warn, "[LCPStreaming] Decryptor does not conform to LCPStreamingProvider—falling back")
      }

      ATLog(.warn, "[LCPStreaming] provider missing or not ready—falling back")
      return LCPPlayer(tableOfContents: tableOfContents, decryptor: decryptor)
    }
}
