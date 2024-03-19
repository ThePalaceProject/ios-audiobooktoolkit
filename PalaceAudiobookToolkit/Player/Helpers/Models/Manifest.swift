//
//  Manifest.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

struct Manifest: Codable {
    let context: String?
    let id: String?
    let metadata: Metadata
    let links: [Link]
    let readingOrder: [ReadingOrderItem]
    let resources: [Link]?
    let toc: [TOCItem]?
    
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case metadata, links, readingOrder, resources, toc, id
    }
    
    init(
        context: String? = nil,
        id: String?,
        metdata: Metadata,
        links: [Link] = [],
        readingOrder: [ReadingOrderItem] = [],
        resources: [Link]? = nil,
        toc: [TOCItem]? = nil
    ) {
        self.context = context
        self.id = id
        self.metadata = metdata
        self.links = links
        self.readingOrder = readingOrder
        self.resources = resources
        self.toc = toc
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
}

struct ReadingOrderItem: Codable {
    let href: String
    let type: String
    let duration: Int?
    let title: String? 
    let bitrate: Int?
    let properties: Properties?
}

struct Metadata: Codable {
    let type: String?
    let identifier: String?
    let title: String
    let subtitle: String?
    let language: String?
    let modified: Date?
    let published: Date?
    let publisher: String?
    var author: [Author] = []
    let duration: Int?
    
    enum CodingKeys: String, CodingKey {
        case type = "@type"
        case identifier, title, subtitle, language, modified, published, publisher, author, duration
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        modified = try container.decodeIfPresent(Date.self, forKey: .modified)
        published = try container.decodeIfPresent(Date.self, forKey: .published)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        
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

struct Author: Codable {
    let name: String
}

struct Link: Codable {
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

struct Properties: Codable {
    let encrypted: Encrypted?
}

struct Encrypted: Codable {
    let scheme: String?
    let profile: String?
    let algorithm: String?
}

struct TOCItem: Codable {
    let href: String
    let title: String?
    let children: [TOCItem]?
}
