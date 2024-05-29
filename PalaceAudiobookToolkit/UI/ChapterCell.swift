//
//  ChapterCell.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/7/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct ChapterCell: View {
    var chapter: Chapter
    
    var body: some View {
        HStack {
            Text(chapter.title)
                .palaceFont(.body)
            Spacer()
            Text(HumanReadableTimestamp(timeInterval: chapter.duration ?? 0.0).timecode)
                .accessibility(label: Text(HumanReadableTimestamp(timeInterval: chapter.duration ?? 0.0).accessibleDescription))
                .palaceFont(.body)
        }
    }
}
