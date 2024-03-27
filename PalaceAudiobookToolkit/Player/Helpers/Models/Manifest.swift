//
//  Manifest.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public enum ManifestContext: Codable {
    case uri(URL)
    case object([String: String])
    case other(String)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let uri = try? container.decode(URL.self) {
            self = .uri(uri)
        } else if let object = try? container.decode([String: String].self) {
            self = .object(object)
        } else if let string = try? container.decode(String.self) {
            self = .other(string)
        } else {
            throw DecodingError.typeMismatch(
                ManifestContext.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown Context type"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .uri(let uri):
            try container.encode(uri)
        case .object(let object):
            try container.encode(object)
        case .other(let string):
            try container.encode(string)
        }
    }
}

public struct Manifest: Codable {
    let context: [ManifestContext]
    let id: String?
    public let metadata: Metadata
    let links: [Link]
    let readingOrder: [ReadingOrderItem]
    let resources: [Link]?
    let toc: [TOCItem]?
    
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id, metadata, links, readingOrder, resources, toc
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Handle both a single string or an array for `@context`
        if let contextString = try? container.decode(String.self, forKey: .context) {
            context = [.other(contextString)]
        } else if let contextArray = try? container.decode([ManifestContext].self, forKey: .context) {
            context = contextArray
        } else {
            throw DecodingError.typeMismatch(
                [ManifestContext].self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected to decode String or Array for @context"))
        }
        
        // Decode other properties
        id = try container.decodeIfPresent(String.self, forKey: .id)
        metadata = try container.decode(Metadata.self, forKey: .metadata)
        links = try container.decode([Link].self, forKey: .links)
        readingOrder = try container.decode([ReadingOrderItem].self, forKey: .readingOrder)
        resources = try container.decodeIfPresent([Link].self, forKey: .resources)
        toc = try container.decodeIfPresent([TOCItem].self, forKey: .toc)
        
    }
        static func customDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        
        decoder.dateDecodingStrategy = .custom({ (decoder) -> Date in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            let dateFormats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd",
            ]
            
            let dateFormatter = DateFormatter()
            
            for dateFormat in dateFormats {
                dateFormatter.dateFormat = dateFormat
                if let date = dateFormatter.date(from: dateString) {
                    return date
                }
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date string \(dateString)"
            )
        })
        
        return decoder
    }

    struct ReadingOrderItem: Codable {
        let title: String?
        let type: String
        let duration: Double
        let href: String?
        
        let findawayPart: Int?
        let findawaySequence: Int?
        
        enum CodingKeys: String, CodingKey {
            case title, type, duration, href
            case findawayPart = "findaway:part"
            case findawaySequence = "findaway:sequence"
        }
    }
    
    public struct Author: Codable {
        let name: String
    }
    
    public struct Link: Codable {
        let rel: String?
        let href: String
        let type: String?
        let height: Int?
        let width: Int?
        let bitrate: Int?
        let title: String?
        let duration: Int?
        let properties: Properties?
    }
    
    public struct Properties: Codable {
        let encrypted: Encrypted?
    }
    
    public struct Encrypted: Codable {
        let scheme: String?
        let profile: String?
        let algorithm: String?
    }
}

public struct TOCItem: Codable {
    let href: String?
    let title: String?
    let children: [TOCItem]?
}

extension Manifest {
    func toJSONDictionary() -> [String: Any]? {
        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(self),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) else {
            return nil
        }

        return jsonObject as? [String: Any]
    }
}

extension Manifest {
    enum AudiobookType {
        case overdrive
        case findaway
        case lcp
        case openAccess
        case unknown
    }
    
    var audiobookType: AudiobookType {
        if let scheme = metadata.drmInformation?.scheme, scheme.contains("FAE") {
            return .findaway
        }
        
        if metadata.formatType?.contains("overdrive") == true {
            return .overdrive
        }
        
        if context.contains(where: { contextItem in
            switch contextItem {
            case .uri(let url):
                return url.absoluteString.contains("readium.org/lcp")
            case .object(let dict):
                return dict.values.contains(where: { $0.contains("readium.org/lcp") })
            case .other(let string):
                return string.contains("readium.org/lcp")
            }
        }) {
            return .lcp
        }
        
        if metadata.drmInformation == nil {
            return .openAccess
        }
        
        return .unknown
    }
}
