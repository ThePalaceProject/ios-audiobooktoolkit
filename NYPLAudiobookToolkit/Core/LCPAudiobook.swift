//
//  LCPAudiobook.swift
//  NYPLAudiobookToolkit
//
//  Created by Vladimir Fedorov on 19.11.2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

@objc public class LCPAudiobook: NSObject, Audiobook {

    /// Readium @context parameter value for LCP audiobooks
    static let manifestContext = "https://readium.org/webpub-manifest/context.jsonld"
    
    public var uniqueIdentifier: String
    
    public var spine: [SpineElement]
    
    public var player: Player

    private static let offsetKey = "#t="

    public var drmStatus: DrmStatus {
        get {
            return DrmStatus.succeeded
        }
        set(newStatus) {
            player.isDrmOk = newStatus == DrmStatus.succeeded
        }
    }
    
    public func checkDrmAsync() {
        // We don't check DRM status here;
        // LCP library checks it accessing files
    }
    
    public func deleteLocalContent() {
        for spineElement in spine {
            spineElement.downloadTask.delete()
        }
    }

    @available(*, deprecated, message: "Use init?(JSON: Any?, decryptor: DRMDecryptor?) instead")
    public required convenience init?(JSON: Any?) {
        self.init(JSON: JSON, decryptor: nil)
    }
    
    /// LCP DRM protected audiobook
    /// - Parameters:
    ///   - JSON: Dictionary with audiobook and spine elements data from `manifest.json`.
    ///   - decryptor: LCP DRM decryptor.
    init?(JSON: Any?, decryptor: DRMDecryptor?) {
        guard let publication = JSON as? [String: Any],
            let metadata = publication["metadata"] as? [String: Any],
            let id = metadata["identifier"] as? String,
            let resources = publication["readingOrder"] as? [[String: Any]]
            else {
                ATLog(.error, "LCPAudiobook failed to init from JSON: \n\(JSON ?? "nil")")
                return nil
            }
        self.uniqueIdentifier = id
        
        if let toc = publication["toc"] as? [[String: Any]] {
            self.spine = LCPAudiobook.getSpineElements(toc: toc, resources: resources, identifier: uniqueIdentifier)
        } else {
            self.spine = LCPAudiobook.getSpineElements(resources: resources, identifier: uniqueIdentifier)
        }
        guard let cursor = Cursor(data: spine) else {
            let title = metadata["title"] as? String ?? ""
            ATLog(.error, "Cursor could not be cast to Cursor<LCPSpineElement> in \(id) \(title)")
            return nil
        }
        player = LCPPlayer(cursor: cursor, audiobookID: uniqueIdentifier, decryptor: decryptor)
    }
    
    private static func getSpineElements(resources: [[String: Any]], identifier: String) -> [LCPSpineElement] {
        var spineElements: [LCPSpineElement] = []
        for (index, resource) in resources.enumerated() {
            if let spineElement = LCPSpineElement(JSON: resource, index: UInt(index), audiobookID: identifier) {
                spineElements.append(spineElement)
            }
        }
        spineElements.sort { (a, b) -> Bool in
            a.chapterNumber < b.chapterNumber
        }

        return spineElements
    }
    
    private static func getSpineElements(toc: [[String: Any]], resources: [[String: Any]], identifier: String) -> [LCPSpineElement] {
        var spineElements: [LCPSpineElement] = []
        let resourceElements = LCPAudiobook.extract(resources: resources)

        let allTocElements: [TocElement] = extractTOCElements(toc: toc)

        // Calculate duration
        for (index, element) in allTocElements.enumerated() {
            var elementDuration = 0.0
            let section = resourceElements[element.rawLink() ?? ""]

            if index < allTocElements.count {
                let current = allTocElements[safe: index]
                let next = allTocElements[safe: index + 1]

                if let current = current, let next = next, current.hasSameParent(as: next) {
                    // If next element is in same section, calculate duration as difference between current and next
                    elementDuration = next.offset() - element.offset()
                } else if let section = section {
                    // If next element is not in the same section as the next element,
                    // calculate duration as the difference between current element and duration of section
                    elementDuration = section.duration - element.offset()
                }
            }

            spineElements.append(LCPSpineElement(
                chapterNumber: UInt(section?.chapter ?? 0),
                title: element.title ?? "",
                href: element.href ?? "",
                offset: element.offset(),
                mediaType: section?.type ?? .audioMP3,
                duration: elementDuration,
                audiobookID: identifier
            ))
        }

        return spineElements
    }
    
    private static func extractTOCElements(toc: [[String: Any]]) ->[TocElement] {
        var elements: [TocElement] = []

        toc.forEach {
            let jsonData = try! JSONSerialization.data(withJSONObject: $0, options: .prettyPrinted)
            let tocElement = try! JSONDecoder().decode(TocElement.self, from: jsonData)

            var tocSection = tocElement.children ?? []
            tocSection.insert(tocElement, at: 0)

            elements.append(contentsOf: tocSection)
        }

        return elements
    }

    private static func extract(resources: [[String: Any]]) -> [String: ResourceElement] {
        var resourceElements: [ResourceElement] = []
        for (index, resource) in resources.enumerated() {
            let resourceData = try! JSONSerialization.data(withJSONObject: resource, options: .prettyPrinted)
            var resourceElement = try! JSONDecoder().decode(ResourceElement.self, from: resourceData)
            resourceElement.chapter = index + 1
            resourceElements.append(resourceElement)
        }

        return Dictionary(uniqueKeysWithValues: resourceElements.map { ($0.href, $0) })
    }

    struct ResourceItem {
        var href: URL
        var chapter: Int
        var duration: Double
    }

    struct TocElement: Codable {
        var title: String?
        var href: String?
        var children: [TocElement]?
        
        func rawLink() -> String? {
            guard var href = href else { return nil }
            return stripOffset(&href)
        }

        func offset() -> Double {
            guard let href = href, let range = href.range(of: offsetKey) else { return 0.0 }
            return Double(href[range.upperBound...]) ?? 0.0
        }
        
        func hasSameParent(as element: TocElement) -> Bool {
            guard var href = href, var compHref = element.href else { return false }
            return stripOffset(&href) == stripOffset(&compHref)
        }
        
        func stripOffset(_ string: inout String) -> String {
            string = string.removed(after: offsetKey)
            return string
        }
    }

    struct ResourceElement: Codable {
        var href: String
        var duration: Double
        var chapter: Int?
        var type: LCPSpineElementMediaType?
    }
}
