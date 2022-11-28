//
//  AudiobookPlayerViewControllerNow.swift
//  NYPLAudiobookToolkit
//
//  Created by Maurice Carrier on 11/28/22.
//  Copyright © 2022 Dean Silfen. All rights reserved.
//

import SwiftUI

struct AudiobookPlayerViewControllerNow: View {
    var body: some View {
        Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
    }
}

struct AudiobookPlayerViewControllerNow_Previews: PreviewProvider {
    static var previews: some View {
        AudiobookPlayerViewControllerNow()
    }
}

struct AudiobookPlayerView: UIViewRepresentable {
    
    func updateUIView(_ uiView: UIViewType, context: UIViewRepresentableContext<AudiobookPlayerView>) {}
    
    func makeUIView(context: Context) -> some UIView {
        AudiobookPlayerViewController(frame: .zero)
    }
}
