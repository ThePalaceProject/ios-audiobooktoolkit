//
//  Track.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public class Track {
    enum TrackType {
        case href(String)
        case findaway(part: Int, sequence: Int)
    }
    
    let type: TrackType
    let title: String?
    let duration: Int
    let index: Int
    var downloadTask: DownloadTask?
    
    init(type: TrackType, title: String?, duration: Int, index: Int) {
        self.type = type
        self.title = title
        self.duration = duration
        self.index = index
    }
}

extension Track: Equatable {
    public static func == (lhs: Track, rhs: Track) -> Bool {
        let typeMatches: Bool = {
            switch (lhs.type, rhs.type) {
            case (.href(let lhsHref), .href(let rhsHref)):
                return lhsHref == rhsHref
            case (.findaway(let lhsPart, let lhsSequence), .findaway(let rhsPart, let rhsSequence)):
                return lhsPart == rhsPart && lhsSequence == rhsSequence
            default:
                return false
            }
        }()
        
        return typeMatches &&
        lhs.duration == rhs.duration &&
        lhs.title == rhs.title &&
        lhs.index == rhs.index
    }
}


extension Track: Comparable {
    public static func < (lhs: Track, rhs: Track) -> Bool {
        switch (lhs.type, rhs.type) {
        case (.href(let lhsHref), .href(let rhsHref)):
            return lhsHref < rhsHref
        case (.findaway(let lhsPart, _), .findaway(let rhsPart, _)):
            return lhsPart < rhsPart
        case (.href, .findaway):
            return true
        case (.findaway, .href):
            return false
        }
    }
}
