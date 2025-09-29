//
//  ChapterCell.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 4/7/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Combine
import SwiftUI

struct ChapterCell: View {
  var chapter: Chapter
  var isCurrentChapter: Bool = false
  var action: () -> Void

  var body: some View {
    Button {
      action()
    } label: {
      HStack {
        Text(chapter.title)
          .palaceFont(.body)
          .foregroundColor(isCurrentChapter ? .accentColor : .primary)
          .fontWeight(isCurrentChapter ? .semibold : .regular)
        Spacer()
        Text(HumanReadableTimestamp(timeInterval: chapter.duration ?? chapter.position.track.duration).timecode)
          .accessibility(label: Text(HumanReadableTimestamp(timeInterval: chapter.duration ?? 0.0)
              .accessibleDescription
          ))
          .palaceFont(.body)
          .foregroundColor(isCurrentChapter ? .accentColor : .secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isCurrentChapter ? Color.accentColor.opacity(0.1) : Color.clear)
      )
    }
    .buttonStyle(.plain)
  }
}
