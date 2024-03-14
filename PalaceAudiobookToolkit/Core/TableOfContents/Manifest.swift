//
//  Manifest.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

struct Manifest: Codable {
    let context: String
    let metadata: Metadata
    let links: [Link]
    let readingOrder: [ReadingOrderItem]
    let toc: [TOCItem]
    
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case metadata, links, readingOrder, toc
    }
}

struct Metadata: Codable {
    let type: String
    let identifier: URL
    let title: String
    let subtitle: String?
    let author: Author
    let narrator: String
    let language: String
    let description: String
    let publisher: String
    let subject: [String]
    let modified: Date
    let published: Date
    let duration: Int
    let abridged: Bool
    let license: URL
    
    enum CodingKeys: String, CodingKey {
        case type = "@type"
        case license = "schema:license"
        case identifier,
             title,
             subtitle,
             author,
             narrator,
             language,
             description,
             publisher,
             subject,
             modified,
             published,
             duration,
             abridged
    }
}

struct Author: Codable {
    let name: String
    let sortAs: String
}

// Link structure
struct Link: Codable {
    let rel: String
    let href: URL
    let type: String
    let height: Int?
    let width: Int?
    let bitrate: Int?
}

struct ReadingOrderItem: Codable {
    let href: URL
    let type: String
    let bitrate: Int?
    let duration: Int?
    let title: String?
}

struct TOCItem: Codable {
    let href: URL
    let title: String
    let children: [TOCItem]?
}

extension Metadata {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        identifier = try container.decode(URL.self, forKey: .identifier)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        author = try container.decode(Author.self, forKey: .author)
        narrator = try container.decode(String.self, forKey: .narrator)
        language = try container.decode(String.self, forKey: .language)
        description = try container.decode(String.self, forKey: .description)
        publisher = try container.decode(String.self, forKey: .publisher)
        subject = try container.decode([String].self, forKey: .subject)
        
        modified = try container.decodeISO8601Date(forKey: .modified)
        published = try container.decodeISO8601Date(forKey: .published)
        
        duration = try container.decode(Int.self, forKey: .duration)
        abridged = try container.decode(Bool.self, forKey: .abridged)
        license = try container.decode(URL.self, forKey: .license)
    }
}

extension Manifest {
    static func decode(from data: Data) -> Manifest? {
        let decoder = JSONDecoder()
        
        do {
            return try decoder.decode(Manifest.self, from: data)
        } catch {
            print("Error decoding Manifest: \(error)")
            return nil
        }
    }
}

extension KeyedDecodingContainer {
    func decodeISO8601Date(forKey key: K) throws -> Date {
        let dateString = try decode(String.self, forKey: key)
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: dateString) {
            return date
        } else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Date string does not match ISO 8601 format expected by formatter.")
        }
    }
}

extension KeyedDecodingContainer {
    func decode<T: Decodable>(
        _ type: T.Type,
        forKey key: K,
        using formatter: DateFormatter
    ) throws -> T where T: ExpressibleByIntegerLiteral, T: ExpressibleByFloatLiteral, T: ExpressibleByStringLiteral {
        let dateString = try decode(String.self, forKey: key)
        if let date = formatter.date(from: dateString) as? T {
            return date
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Date string does not match format expected by formatter.")
    }
}
