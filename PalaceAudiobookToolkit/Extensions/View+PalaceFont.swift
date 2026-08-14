//
//  View+PalaceFont.swift
//  PalaceAudiobookToolkit
//
//  Copyright © 2023 The Palace Project. All rights reserved.
//
//  Vendored from PalaceUIKit (ios-core `Palace/Fonts/Font+PalaceUIKit.swift`) so the
//  toolkit owns its own typography and can be built and tested from a checkout of
//  itself. The toolkit already ships the OpenSans faces in its own resources bundle
//  and declares them under `UIAppFonts` in `PalaceAudiobookToolkit/Info.plist`, so
//  nothing outside this repository is needed to render them.
//
//  Callers, so a future audit does not repeat the one that missed a file: THIRTEEN
//  sites across THREE files — `AudiobookPlayerView` (6), `AudiobookNavigationView`
//  (5) and `ChapterCell` (2). The first audit named only the two files that carried
//  `import PalaceUIKit`; `ChapterCell` compiled anyway because Swift leaks an
//  import's visibility across files in the same module. Vendoring removes that
//  fragility — the extension is now genuinely module-wide — but it is exactly why
//  "grep the files that import it" is not a complete census.
//
//  The sizes, weights and font name below are a verbatim copy of the PalaceUIKit
//  implementation. Keep them in step with ios-core if the shared style guide moves:
//  https://www.figma.com/file/BxLs5QNmU5tCIKhO9ccAyh/TPP-UI---Style-Guidelines
//
//  Deliberately `internal`, for minimal surface: nothing outside this module needs
//  it, and PalaceUIKit already vends a `public` `View.palaceFont(_:)` to the host app.
//
//  The original justification given for `internal` was that app code importing BOTH
//  modules would hit an ambiguous-member error. Review checked it and that is NOT
//  true — no ios-core file imports both, and `TPPAppDelegate`'s `palaceFont` is a
//  different symbol (`UIFont.palaceFont(ofSize:)`). The decision stands; the reason
//  it was made did not, and is corrected here rather than left to mislead.
//

import SwiftUI

struct PalaceFontModifier: ViewModifier {

  var style: Font.TextStyle
  var size: CGFloat?
  var weight: Font.Weight?

  func body(content: Content) -> some View {
    content.font(
      .custom(palaceFontName, size: size ?? fontSize(for: style), relativeTo: style)
        .weight(weight ?? fontWeight(for: style))
    )
  }

  private let palaceFontName = "OpenSans-Regular"

  private func fontSize(for textStyle: Font.TextStyle) -> CGFloat {
    switch textStyle {
    case .largeTitle: return 34
    case .title: return 28
    case .title2: return 22
    case .title3: return 20
    case .headline: return 17
    case .subheadline: return 15
    case .body: return 17
    default: return UIFont.preferredFont(forTextStyle: translateTextStyle(textStyle)).pointSize
    }
  }

  private func fontWeight(for textStyle: Font.TextStyle) -> Font.Weight {
    switch textStyle {
    case .largeTitle: return .bold
    case .title: return .bold
    case .title2: return .bold
    case .title3: return .bold
    case .headline: return .bold
    case .subheadline: return .bold
    case .body: return .regular
    default: return .regular
    }
  }

  private func translateTextStyle(_ textStyle: Font.TextStyle) -> UIFont.TextStyle {
    switch textStyle {
    case .largeTitle: return .largeTitle
    case .title: return .title1
    case .title2: return .title2
    case .title3: return .title3
    case .headline: return .headline
    case .subheadline: return .subheadline
    case .body: return .body
    case .callout: return .callout
    case .footnote: return .footnote
    case .caption: return .caption1
    case .caption2: return .caption2
    @unknown default: return .body
    }
  }
}

extension View {
  func palaceFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
    modifier(PalaceFontModifier(style: style, weight: weight))
  }

  func palaceFont(size: CGFloat, weight: Font.Weight? = nil) -> some View {
    modifier(PalaceFontModifier(style: .body, size: size, weight: weight))
  }
}
