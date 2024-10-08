//
//  Chapter.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 3/14/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

public struct Chapter: Identifiable, Equatable {
    public var id: String = UUID().uuidString
    
    public var title: String
    public var position: TrackPosition
    public var duration: Double?
    public var endPosition: TrackPosition?

    mutating func calculateEndPosition(using tracks: Tracks) {
        guard let duration = duration else {
            self.endPosition = nil
            return
        }
        self.endPosition = position + duration
    }
}
