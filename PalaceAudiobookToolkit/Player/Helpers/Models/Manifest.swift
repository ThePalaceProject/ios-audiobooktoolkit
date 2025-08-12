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
    let reserveId: String?
    let crossRefId: Int?
    public let metadata: Metadata?
    let  links: [Link]?
    var linksDictionary: LinksDictionary?
    public let readingOrder: [ReadingOrderItem]?
    let resources: [Link]?
    let toc: [TOCItem]?
    public let formatType: String?
    let spine: [SpineItem]?

    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id, reserveId, crossRefId, metadata, links, readingOrder, resources, toc, formatType, spine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let contextString = try? container.decode(String.self, forKey: .context) {
            context = [.other(contextString)]
        } else if let contextArray = try? container.decode([ManifestContext].self, forKey: .context) {
            context = contextArray
        } else {
            context = []
        }
        
        id = try container.decodeIfPresent(String.self, forKey: .id)
        reserveId = try container.decodeIfPresent(String.self, forKey: .reserveId)
        crossRefId = try container.decodeIfPresent(Int.self, forKey: .crossRefId)
        metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
        readingOrder = try container.decodeIfPresent([ReadingOrderItem].self, forKey: .readingOrder)
        toc = try container.decodeIfPresent([TOCItem].self, forKey: .toc)
        formatType = try container.decodeIfPresent(String.self, forKey: .formatType)
        spine = try container.decodeIfPresent([SpineItem].self, forKey: .spine)

        if let linksArray = try? container.decode([Link].self, forKey: .links) {
            links = linksArray
            linksDictionary = nil
        } else if let linksDict = try? container.decodeIfPresent(LinksDictionary.self, forKey: .links) {
            linksDictionary = linksDict
            links = nil
        } else {
            links = nil
            linksDictionary = nil
        }

        if let decodedResources = try? container.decode([Link].self, forKey: .resources) {
            resources = decodedResources
        } else {
            resources = []
            print("Failed to decode resources or resources were empty. Defaulting to an empty array.")
        }
    }
    
    public static func customDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        
        decoder.dateDecodingStrategy = .custom({ (decoder) -> Date in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            let dateFormats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd"
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

    public struct ReadingOrderItem: Codable {
        public let title: String?
        let type: String
        let duration: Double
        let href: String?
        public let properties: Properties?
        
        public let findawayPart: Int?
        public let findawaySequence: Int?
        
        enum CodingKeys: String, CodingKey {
            case title, type, duration, href, properties
            case findawayPart = "findaway:part"
            case findawaySequence = "findaway:sequence"
        }
        
        /// Create a copy with enhanced properties for streaming
        func withStreamingUrl(_ streamingUrl: String) -> ReadingOrderItem {
            let enhancedProperties = Properties(
                encrypted: properties?.encrypted,
                lcpStreamingUrl: streamingUrl
            )
            
            return ReadingOrderItem(
                title: title,
                type: type,
                duration: duration,
                href: href,
                properties: enhancedProperties,
                findawayPart: findawayPart,
                findawaySequence: findawaySequence
            )
        }
        
        private init(title: String?, type: String, duration: Double, href: String?, properties: Properties?, findawayPart: Int?, findawaySequence: Int?) {
            self.title = title
            self.type = type
            self.duration = duration
            self.href = href
            self.properties = properties
            self.findawayPart = findawayPart
            self.findawaySequence = findawaySequence
        }
    }
    
    public struct Author: Codable {
        let name: String
    }
    
    public struct Link: Codable {
        let rel: [String]?
        let href: String
        let type: String?
        let height: Int?
        let width: Int?
        let bitrate: Int?
        let title: LocalizedString?
        let duration: Int?
        let properties: Properties?
        let physicalFileLengthInBytes: Int?
        let alternates: [Link]?

        // Nested struct for localized title
        struct LocalizedString: Codable {
            let values: [String: String]

            func localizedTitle() -> String {
                let currentLocale = Locale.autoupdatingCurrent
                let languageCode = currentLocale.languageCode ?? "en"
                return values[languageCode] ?? values["en"] ?? ""
            }
        }

        // Add a placeholder for `Properties` struct
        struct Properties: Codable {
            let encrypted: Encrypted?

            struct Encrypted: Codable {
                let algorithm: String?
                let profile: String?
                let scheme: String?
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if let relArray = try? container.decode([String].self, forKey: .rel) {
                rel = relArray
            } else if let relString = try? container.decode(String.self, forKey: .rel) {
                rel = [relString]
            } else {
                rel = nil
            }

            href = try container.decode(String.self, forKey: .href)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            height = try container.decodeIfPresent(Int.self, forKey: .height)
            width = try container.decodeIfPresent(Int.self, forKey: .width)
            bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
            title = try container.decodeIfPresent(LocalizedString.self, forKey: .title)
            duration = try container.decodeIfPresent(Int.self, forKey: .duration)
            properties = try container.decodeIfPresent(Properties.self, forKey: .properties)
            physicalFileLengthInBytes = try container.decodeIfPresent(Int.self, forKey: .physicalFileLengthInBytes)

            if let alternatesArray = try? container.decode([Link].self, forKey: .alternates) {
                alternates = alternatesArray
            } else if let alternateSingle = try? container.decode(Link.self, forKey: .alternates) {
                alternates = [alternateSingle]
            } else {
                alternates = nil
            }
        }
    }

    struct LinksDictionary: Codable {
        var contentLinks: [Link]?
        var selfLink: Link?
    
        enum CodingKeys: String, CodingKey {
            case contentLinks = "contentlinks"
            case selfLink = "self"
        }
    }

    public struct SpineItem: Codable {
        let title: String?
        let href: String
        let type: String
        let duration: Int
        let bitrate: Int?
        let properties: Properties?
        let alternates: [Link]?
    }

    public struct Properties: Codable {
        let encrypted: Encrypted?
        public let lcpStreamingUrl: String?
        
        init(encrypted: Encrypted? = nil, lcpStreamingUrl: String? = nil) {
            self.encrypted = encrypted
            self.lcpStreamingUrl = lcpStreamingUrl
        }
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
        
        encoder.dateEncodingStrategy = .iso8601
        
        guard let jsonData = try? encoder.encode(self),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []),
              let dictionary = jsonObject as? [String: Any] else {
            return nil
        }
        
        return dictionary
    }
}

public extension Manifest {
    enum AudiobookType {
        case findaway, overdrive, lcp, openAccess, unknown
    }
    
    var audiobookType: AudiobookType {
        if let scheme = metadata?.drmInformation?.scheme, scheme.contains("http://librarysimplified.org/terms/drm/scheme/FAE") {
            return .findaway
        }
        
        if formatType?.contains("overdrive") == true {
            return .overdrive
        }
        
        if readingOrder?.contains(where: { $0.properties?.encrypted?.scheme == "http://readium.org/2014/01/lcp" }) == true {
            return .lcp
        }
        
        return .openAccess
    }
    
    var trackMediaType: TrackMediaType {
        readingOrder?.first?.trackMediaType ?? spine?.first?.trackMediaType ?? .audioMP3
    }
    
    func profile(for type: AudiobookType) -> String? {
        switch audiobookType {
        case .findaway:
            return readingOrder?.first?.properties?.encrypted?.profile
        default:
            return nil
        }
    }
}

// MARK: - LCP Streaming Enhancement

extension Manifest {
    /// Create an enhanced manifest with LCP streaming URLs
   public func withStreamingUrls(publicationUrl: URL) -> Manifest {
        guard let readingOrder = readingOrder else {
            return self
        }
        
        let enhancedReadingOrder = readingOrder.map { item in
            guard let href = item.href else { return item }
            
            let streamingUrl = publicationUrl.appendingPathComponent(href)
            return item.withStreamingUrl(streamingUrl.absoluteString)
        }
        
        return Manifest(
            context: context,
            id: id,
            reserveId: reserveId,
            crossRefId: crossRefId,
            metadata: metadata,
            links: links,
            linksDictionary: linksDictionary,
            readingOrder: enhancedReadingOrder,
            resources: resources,
            toc: toc,
            formatType: formatType,
            spine: spine
        )
    }
    
    /// Private initializer for creating enhanced manifests
    private init(context: [ManifestContext], id: String?, reserveId: String?, crossRefId: Int?, metadata: Metadata?, links: [Link]?, linksDictionary: LinksDictionary?, readingOrder: [ReadingOrderItem]?, resources: [Link]?, toc: [TOCItem]?, formatType: String?, spine: [SpineItem]?) {
        self.context = context
        self.id = id
        self.reserveId = reserveId
        self.crossRefId = crossRefId
        self.metadata = metadata
        self.links = links
        self.linksDictionary = linksDictionary
        self.readingOrder = readingOrder
        self.resources = resources
        self.toc = toc
        self.formatType = formatType
        self.spine = spine
    }
}

extension Manifest.ReadingOrderItem {
    var trackMediaType: TrackMediaType? {
        TrackMediaType(rawValue: self.type)
    }
}

extension Manifest.SpineItem {
    var trackMediaType: TrackMediaType? {
        TrackMediaType(rawValue: self.type)
    }
}
