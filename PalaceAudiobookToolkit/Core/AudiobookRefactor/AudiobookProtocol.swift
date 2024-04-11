//
//  Audiobook.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public enum DRMStatus: Int {
    public typealias RawValue = Int
    case failed
    case processing
    case succeeded
    case unknown
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

public protocol AudiobookProtocol {
    var uniqueId: String { get }
    var annotationsId: String { get }
    var tableOfContents: AudiobookTableOfContents { get }
    var player: Player { get }
    var drmStatus: DRMStatus { get set }
    
    func checkDrmAsync()
    func deleteLocalContent(completion: @escaping (Bool, Error?) -> Void)
    init?(manifest: Manifest, bookIdentifier: String)
}
