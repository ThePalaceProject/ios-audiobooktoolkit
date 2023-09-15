//
//  ChapterLocation+emptyLocation.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 15/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension ChapterLocation {
    /// Empty location for previews
    static var emptyLocation: ChapterLocation {
        ChapterLocation(
            number: 0,
            part: 0,
            duration: 0,
            startOffset: 0,
            playheadOffset: 0,
            title: nil,
            audiobookID: ""
        )
    }
}
