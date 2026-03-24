//
// SpeedSliderSheet.swift
// PalaceAudiobookToolkit
//
// Created by Maurice Carrier on 3/23/25.
// Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

// MARK: - SpeedSliderSheet

/// Playback speed picker: stepped slider + ± stepper buttons + preset chips.
struct SpeedSliderSheet: View {
  @Binding var playbackRate: PlaybackRate
  var onDismiss: () -> Void

  @State private var sliderValue: Double = 1.0

  private let step: Double = 0.05
  private let minRate: Double = 0.75
  private let maxRate: Double = 2.0

  // MARK: - Computed labels

  /// Short visual label shown in the header, e.g. "1.25×"
  private var speedLabel: String {
    let rate = Float(sliderValue)
    if abs(rate - 1.0) < 0.001 { return "1.0×" }
    return HumanReadablePlaybackRate.formatMultiplier(rate)
  }

  /// Full spoken description used by VoiceOver, e.g. "One and a quarter times faster than normal speed."
  private var speedAccessibleDescription: String {
    HumanReadablePlaybackRate(rate: PlaybackRate.nearest(to: Float(sliderValue))).accessibleDescription
  }

  private var atMinimum: Bool { sliderValue <= minRate }
  private var atMaximum: Bool { sliderValue >= maxRate }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      dragHandle

      VStack(spacing: 28) {
        headerRow
        sliderRow
        presetChips
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 36)
    }
    .background(Color(white: 0.12))
    .cornerRadius(20)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Strings.AudiobookPlayerViewController.playbackSpeed)
    .onAppear {
      sliderValue = Double(PlaybackRate.convert(rate: playbackRate))
    }
    .onChange(of: sliderValue) { newValue in
      let nearest = PlaybackRate.nearest(to: Float(newValue))
      if nearest != playbackRate {
        playbackRate = nearest
        UIAccessibility.post(notification: .announcement, argument: speedAccessibleDescription)
      }
    }
  }

  // MARK: - Sub-views

  private var dragHandle: some View {
    RoundedRectangle(cornerRadius: 3)
      .fill(Color.white.opacity(0.3))
      .frame(width: 40, height: 5)
      .padding(.top, 12)
      .padding(.bottom, 4)
      .accessibilityHidden(true)
  }

  private var headerRow: some View {
    HStack {
      Text(Strings.AudiobookPlayerViewController.playbackSpeed)
        .font(.headline)
        .foregroundColor(.white)
      Spacer()
      Text(speedLabel)
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundColor(.white)
        .contentTransition(.numericText())
        .animation(.easeOut(duration: 0.15), value: speedLabel)
    }
    // Combine title + value into one VoiceOver element
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(Strings.AudiobookPlayerViewController.playbackSpeed), \(speedAccessibleDescription)")
  }

  private var sliderRow: some View {
    HStack(spacing: 16) {
      stepButton(systemName: "minus", isDisabled: atMinimum, action: stepDown)

      Slider(value: $sliderValue, in: minRate...maxRate, step: step)
        .tint(Color.orange)
        .accessibilityLabel(Strings.AudiobookPlayerViewController.playbackSpeed)
        .accessibilityValue(speedAccessibleDescription)
        .accessibilityHint(
          NSLocalizedString(
            "Swipe up or down with one finger to adjust",
            bundle: Bundle.audiobookToolkit()!,
            value: "Swipe up or down with one finger to adjust",
            comment: "VoiceOver hint for the playback speed slider"
          )
        )

      stepButton(systemName: "plus", isDisabled: atMaximum, action: stepUp)
    }
  }

  private func stepButton(systemName: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
    let isMinus = systemName == "minus"
    let label = isMinus
      ? NSLocalizedString("Decrease speed", bundle: Bundle.audiobookToolkit()!, value: "Decrease speed", comment: "")
      : NSLocalizedString("Increase speed", bundle: Bundle.audiobookToolkit()!, value: "Increase speed", comment: "")
    let hint = isMinus
      ? NSLocalizedString("Decreases playback speed by 0.05 times", bundle: Bundle.audiobookToolkit()!, value: "Decreases playback speed by 0.05 times", comment: "")
      : NSLocalizedString("Increases playback speed by 0.05 times", bundle: Bundle.audiobookToolkit()!, value: "Increases playback speed by 0.05 times", comment: "")

    return Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(isDisabled ? .white.opacity(0.3) : .white)
        .frame(width: 40, height: 40)
        .background(Circle().fill(Color.white.opacity(isDisabled ? 0.05 : 0.15)))
    }
    .disabled(isDisabled)
    .accessibilityLabel(label)
    .accessibilityHint(hint)
  }

  private var presetChips: some View {
    HStack(spacing: 8) {
      ForEach(PlaybackRate.presets, id: \.rawValue) { preset in
        presetChip(for: preset)
      }
    }
    .accessibilityLabel(
      NSLocalizedString(
        "Speed presets",
        bundle: Bundle.audiobookToolkit()!,
        value: "Speed presets",
        comment: "VoiceOver label for the row of speed preset buttons"
      )
    )
  }

  private func presetChip(for preset: PlaybackRate) -> some View {
    let multiplier = PlaybackRate.convert(rate: preset)
    let isSelected = abs(sliderValue - Double(multiplier)) < 0.001

    let visualLabel: String = {
      if preset == .normalTime { return "1.0" }
      let d = Double(multiplier)
      if d.truncatingRemainder(dividingBy: 1) == 0 { return String(format: "%.1f", d) }
      return String(format: "%.2g", d)
    }()

    let accessibleLabel = HumanReadablePlaybackRate(rate: preset).accessibleDescription

    return Button {
      withAnimation(.easeOut(duration: 0.1)) {
        sliderValue = Double(multiplier)
      }
    } label: {
      VStack(spacing: 2) {
        Text(visualLabel)
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .foregroundColor(isSelected ? .black : .white)
        if preset == .normalTime {
          Text("DEFAULT")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(isSelected ? .black.opacity(0.6) : .white.opacity(0.5))
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(isSelected ? Color.white : Color.white.opacity(0.12))
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibleLabel)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint(
      isSelected ? "" : NSLocalizedString(
        "Sets playback speed",
        bundle: Bundle.audiobookToolkit()!,
        value: "Sets playback speed",
        comment: "VoiceOver hint for a speed preset button"
      )
    )
  }

  // MARK: - Actions

  private func stepDown() {
    withAnimation(.easeOut(duration: 0.1)) {
      sliderValue = max(minRate, (sliderValue - step).rounded(toPlaces: 2))
    }
  }

  private func stepUp() {
    withAnimation(.easeOut(duration: 0.1)) {
      sliderValue = min(maxRate, (sliderValue + step).rounded(toPlaces: 2))
    }
  }
}

// MARK: - SpeedPickerModifier

/// Routes the speed-picker presentation to either the stepped slider sheet
/// or the legacy action sheet depending on `useSlider`.
struct SpeedPickerModifier: ViewModifier {
  @Binding var isPresented: Bool
  let useSlider: Bool
  let playbackRateBinding: Binding<PlaybackRate>
  let legacyButtons: [ActionSheet.Button]

  func body(content: Content) -> some View {
    if useSlider {
      content
        .sheet(isPresented: $isPresented) {
          SpeedSliderSheet(
            playbackRate: playbackRateBinding,
            onDismiss: { isPresented = false }
          )
          .presentationDetents([.height(260)])
          .presentationDragIndicator(.hidden)
        }
    } else {
      content
        .actionSheet(isPresented: $isPresented) {
          ActionSheet(
            title: Text(Strings.AudiobookPlayerViewController.playbackSpeed),
            buttons: legacyButtons
          )
        }
    }
  }
}

// MARK: - Double rounding helper

private extension Double {
  func rounded(toPlaces places: Int) -> Double {
    let multiplier = pow(10.0, Double(places))
    return (self * multiplier).rounded() / multiplier
  }
}
