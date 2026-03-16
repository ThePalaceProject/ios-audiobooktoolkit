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

struct LoadingErrorView: View {
  var onRetry: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.5)
        .edgesIgnoringSafeArea(.all)

      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 40))
          .foregroundColor(.yellow)
        Text(Strings.AudiobookPlayerViewController.problemHasOccurred)
          .foregroundColor(.white)
          .font(.headline)
        Text(Strings.AudiobookPlayerViewController.tryAgain)
          .foregroundColor(.white)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
        Button(action: onRetry) {
          Text(Strings.Generic.retry)
            .fontWeight(.semibold)
            .foregroundColor(.black)
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
            .background(Color.white)
            .cornerRadius(8)
        }
      }
    }
  }
}
