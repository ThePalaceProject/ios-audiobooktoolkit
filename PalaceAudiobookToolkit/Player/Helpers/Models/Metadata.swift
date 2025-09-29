//
//  Metadata.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/26/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public extension Manifest {
  struct Metadata: Codable {
    public let type: String?
    public let identifier: String?
    public let title: String?
    public let subtitle: String?
    public let language: String?
    public let modified: Date?
    public let published: Date?
    public let publisher: String?
    public var author: [Author] = []
    public let duration: Double?
    public let drmInformation: DRMType?
    public let signature: Signature?
    public let rights: Rights?

    enum CodingKeys: String, CodingKey {
      case type = "@type"
      case identifier, title, subtitle, language, modified, published, publisher, author, duration, encrypted
      case signature = "http://www.feedbooks.com/audiobooks/signature"
      case rights = "http://www.feedbooks.com/audiobooks/rights"
    }

    public struct Signature: Codable {
      let algorithm: String?
      let value: String?
      let issuer: String?
    }

    public struct Rights: Codable {
      let start: String?
      let end: String?
    }

    public struct Author: Codable {
      let name: String
    }

    public struct Publisher: Codable {
      let name: String
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      type = try container.decodeIfPresent(String.self, forKey: .type)
      identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
      title = try container.decodeIfPresent(String.self, forKey: .title)
      subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
      published = try container.decodeIfPresent(Date.self, forKey: .published)
      duration = try container.decodeIfPresent(Double.self, forKey: .duration)
      drmInformation = try container.decodeIfPresent(DRMType.self, forKey: .encrypted)
      signature = try container.decodeIfPresent(Signature.self, forKey: .signature)
      rights = try container.decodeIfPresent(Rights.self, forKey: .rights)

      if let languageArray = try? container.decode([String].self, forKey: .language),
         let firstLanguage = languageArray.first
      {
        language = firstLanguage
      } else if let singleLanguage = try? container.decodeIfPresent(String.self, forKey: .language) {
        language = singleLanguage
      } else {
        language = nil
      }

      if let publisherArray = try? container.decode([Publisher].self, forKey: .publisher),
         let firstPublisher = publisherArray.first
      {
        publisher = firstPublisher.name
      } else {
        publisher = nil
      }

      if let modifiedDateString = try container.decodeIfPresent(String.self, forKey: .modified),
         modifiedDateString != "N/A"
      {
        modified = try container.decode(Date.self, forKey: .modified)
      } else {
        modified = nil
      }

      if let authorArray = try? container.decode([Author].self, forKey: .author) {
        author = authorArray
      }
    }
  }

  internal static func date(from string: String) -> Date? {
    guard string != "N/A" else {
      return nil
    }

    let dateFormats = [
      "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
      "yyyy-MM-dd'T'HH:mm:ssZ",
      "yyyy-MM-dd"
    ]

    let dateFormatter = DateFormatter()
    for format in dateFormats {
      dateFormatter.dateFormat = format
      if let date = dateFormatter.date(from: string) {
        return date
      }
    }

    return nil
  }

  enum DRMType: Codable {
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
      case let .findaway(findawayInfo):
        try container.encode(findawayInfo)
      }
    }

    public var sessionKey: String? {
      switch self {
      case let .findaway(info):
        info.sessionKey
      }
    }

    public var licenseID: String? {
      switch self {
      case let .findaway(info):
        info.licenseId
      }
    }

    public var scheme: String? {
      switch self {
      case let .findaway(information):
        information.scheme
      }
    }

    public var fulfillmentId: String? {
      switch self {
      case let .findaway(info):
        info.fulfillmentId
      }
    }
  }

  struct FindawayDRMInformation: Codable {
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

public extension Manifest.Metadata {
  func encode(to encoder: Encoder) throws {
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

extension Manifest.Metadata {
  func toJSONDictionary() -> [String: Any]? {
    let encoder = JSONEncoder()

    encoder.dateEncodingStrategy = .iso8601

    guard let jsonData = try? encoder.encode(self),
          let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []),
          let dictionary = jsonObject as? [String: Any]
    else {
      return nil
    }

    return dictionary
  }
}
