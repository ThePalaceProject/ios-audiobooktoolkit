//
//  OpenAccessAudiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared

#if LCP
import ReadiumStreamer
#endif

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
  func getPublication() -> Publication?
  func getHTTPRangeRetriever() -> HTTPRangeRetriever
  func getStreamingBaseURL() -> URL?  // 🚀 Base URL for streaming (from license)
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
        ATLog(.debug, "🎵 [PlayerFactory] Creating player for type: \(manifest.audiobookType), decryptor: \(String(describing: decryptor))")
        self.player = playerFactory.createPlayer(
            forType: manifest.audiobookType,
            withTableOfContents: tableOfContents,
            decryptor: decryptor
        )
        ATLog(.debug, "🎵 [PlayerFactory] Created player: \(type(of: self.player))")

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
        ATLog(.debug, "🎵 [DynamicPlayerFactory] createPlayer called with type: \(type)")
        
        switch type {
        case .lcp:
            ATLog(.debug, "🎵 [DynamicPlayerFactory] LCP type detected, creating LCP player")
            return createLCPPlayer(tableOfContents: toc, decryptor: decryptor)
        case .findaway:
            ATLog(.debug, "🎵 [DynamicPlayerFactory] Findaway type detected")
            return FindawayPlayer(tableOfContents: toc) ?? OpenAccessPlayer(tableOfContents: toc)
        default:
            ATLog(.debug, "🎵 [DynamicPlayerFactory] Default type (\(type)), creating OpenAccessPlayer")
            return OpenAccessPlayer(tableOfContents: toc)
        }
    }
    
    private func createLCPPlayer(tableOfContents: AudiobookTableOfContents, decryptor: DRMDecryptor?) -> Player {
        ATLog(.debug, "🎵 [DynamicPlayerFactory] createLCPPlayer called")
        return createStreamingLCPPlayer(tableOfContents: tableOfContents, decryptor: decryptor)
    }
    
    private func createStreamingLCPPlayer(
      tableOfContents toc: AudiobookTableOfContents,
      decryptor: DRMDecryptor?
    ) -> Player {
      ATLog(.debug, "createStreamingLCPPlayer - checking for LCP streaming provider")
      
#if LCP
      if let provider = decryptor as? LCPStreamingProvider {
        ATLog(.debug, "createStreamingLCPPlayer - found LCPStreamingProvider")
        if let publication = provider.getPublication() {
          ATLog(.debug, "createStreamingLCPPlayer - publication available, creating LCPStreamingPlayer")
          return LCPStreamingPlayer(
            tableOfContents: toc,
            decryptor: provider,
            publication: publication,
            rangeRetriever: provider.getHTTPRangeRetriever()
          )
        } else {
          ATLog(.debug, "createStreamingLCPPlayer - publication not available, falling back to LCPPlayer")
        }
      } else {
        ATLog(.debug, "createStreamingLCPPlayer - decryptor is not LCPStreamingProvider, falling back to LCPPlayer")
      }

      ATLog(.debug, "createStreamingLCPPlayer - creating LCPPlayer")
      return LCPPlayer(tableOfContents: toc, decryptor: decryptor)
#else
      ATLog(.debug, "createStreamingLCPPlayer - LCP not available, creating OpenAccessPlayer")
      return OpenAccessPlayer(tableOfContents: toc)
#endif
    }
}
