//
//  RetryToolbar.swift
//  PalaceAudiobookToolkit
//
//  Created by Maurice Carrier on 6/10/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import SwiftUI

struct RetryToolbar: View {
    var retryAction: () -> Void
    
    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.circle")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(.red)
                .padding(.leading)
            
            Button {
                retryAction()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.primary)
            }
            .padding(.trailing)
        }
        .frame(height: 44)
        .background(Color(UIColor.systemBackground))
    }
}
