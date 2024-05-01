//
//  Metadata.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/26/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

extension Manifest {
    public struct Metadata: Codable {
        public let type: String?
        public let identifier: String?
        public let title: String
        public let subtitle: String?
        public let language: String?
        public let modified: Date?
        public let published: Date?
        public let publisher: String?
        public var author: [Author] = []
        public let duration: Double?
        public let drmInformation: DRMType?
        
        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case identifier, title, subtitle, language, modified, published, publisher, author, duration, encrypted
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            title = try container.decode(String.self, forKey: .title)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            modified = try container.decodeIfPresent(Date.self, forKey: .modified)
            published = try container.decodeIfPresent(Date.self, forKey: .published)
            publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
            duration = try container.decodeIfPresent(Double.self, forKey: .duration)
            drmInformation = try container.decodeIfPresent(DRMType.self, forKey: .encrypted)
            
            // Decode author array from different formats
            if let authorStrings = try? container.decodeIfPresent([String].self, forKey: .author) {
                if let authorStrings {
                    author = authorStrings.map { Author(name: $0) }
                }
            } else if let singleAuthor = try? container.decodeIfPresent(String.self, forKey: .author) {
                if let singleAuthor {
                    author = [Author(name: singleAuthor)]
                }
            } else if let authorArray = try? container.decodeIfPresent([Author].self, forKey: .author) {
                if let authorArray {
                    author = authorArray
                }
            }
        }
    }
    
    public enum DRMType: Codable {
        case findaway(FindawayDRMInformation)
        
        enum CodingKeys: String, CodingKey {
            case findaway
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let findawayInfo = try? container.decode(FindawayDRMInformation.self) {
                self = .findaway(findawayInfo)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "DRM information could not be decoded")
            }
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .findaway(let findawayInfo):
                try container.encode(findawayInfo)
            }
        }
        
        var sessionKey: String? {
            switch self {
            case .findaway(let info):
                return info.sessionKey
            }
        }
        
        var licenseID: String? {
            switch self {
            case .findaway(let info):
                return info.licenseId
            }
        }

        var scheme: String? {
            switch self {
            case .findaway(let information):
                return information.scheme
            }
        }
    }
    
    public struct FindawayDRMInformation: Codable {
        var scheme: String?
        let licenseId: String
        let sessionKey: String
        let checkoutId: String
        let fulfillmentId: String
        let accountId: String
        
        enum CodingKeys: String, CodingKey {
            case scheme
            case licenseId = "findaway:licenseId"
            case sessionKey = "findaway:sessionKey"
            case checkoutId = "findaway:checkoutId"
            case fulfillmentId = "findaway:fulfillmentId"
            case accountId = "findaway:accountId"
        }
    }
}

extension Manifest.Metadata {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(modified, forKey: .modified)
        try container.encodeIfPresent(published, forKey: .published)
        try container.encodeIfPresent(publisher, forKey: .publisher)
        try container.encodeIfPresent(duration, forKey: .duration)
        
        if !author.isEmpty {
            try container.encode(author, forKey: .author)
        }
        
        if let drmInformation = drmInformation {
            try container.encode(drmInformation, forKey: .encrypted)
        }
    }
    }
