//
//  LoadingView.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Work on 7/17/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import SwiftUI

struct LoadingView: View {
  var body: some View {
    ZStack {
      Color.black.opacity(0.5)
        .edgesIgnoringSafeArea(.all)

      VStack {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle())
          .scaleEffect(2)
        Text(Strings.Generic.loading)
          .foregroundColor(.white)
          .padding(.top, 8)
      }
    }
  }
}
