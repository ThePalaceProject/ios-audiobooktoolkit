//
// SpeedSliderSheet.swift
// PalaceAudiobookToolkit
//
// Created by Maurice Carrier on 3/23/25.
// Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI

// MARK: - SpeedSliderSheet

/// Audible-style playback speed picker: stepped slider + ± stepper buttons + preset chips.
struct SpeedSliderSheet: View {
  @Binding var playbackRate: PlaybackRate
  var onDismiss: () -> Void

  @State private var sliderValue: Double = 1.0

  private let step: Double = 0.05
  private let minRate: Double = 0.75
  private let maxRate: Double = 2.0

  private var speedLabel: String {
    let rate = Float(sliderValue)
    if abs(rate - 1.0) < 0.001 {
      return "1.0×"
    }
    return HumanReadablePlaybackRate.formatMultiplier(rate)
  }

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
    .onAppear {
      sliderValue = Double(PlaybackRate.convert(rate: playbackRate))
    }
    .onChange(of: sliderValue) { newValue in
      let nearest = PlaybackRate.nearest(to: Float(newValue))
      if nearest != playbackRate {
        playbackRate = nearest
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
  }

  private var sliderRow: some View {
    HStack(spacing: 16) {
      stepButton(systemName: "minus", action: stepDown)

      Slider(value: $sliderValue, in: minRate...maxRate, step: step)
        .tint(Color.orange)
        .accessibilityLabel(Text("Playback speed slider"))
        .accessibilityValue(Text(speedLabel))

      stepButton(systemName: "plus", action: stepUp)
    }
  }

  private func stepButton(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(.white)
        .frame(width: 40, height: 40)
        .background(Circle().fill(Color.white.opacity(0.15)))
    }
    .accessibilityLabel(Text(systemName == "minus" ? "Decrease speed" : "Increase speed"))
  }

  private var presetChips: some View {
    HStack(spacing: 8) {
      ForEach(PlaybackRate.presets, id: \.rawValue) { preset in
        presetChip(for: preset)
      }
    }
  }

  private func presetChip(for preset: PlaybackRate) -> some View {
    let multiplier = PlaybackRate.convert(rate: preset)
    let isSelected = abs(sliderValue - Double(multiplier)) < 0.001

    let label: String = {
      if preset == .normalTime { return "1.0" }
      let d = Double(multiplier)
      if d.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%.1f", d)
      }
      return String(format: "%.2g", d)
    }()

    return Button {
      withAnimation(.easeOut(duration: 0.1)) {
        sliderValue = Double(multiplier)
      }
    } label: {
      VStack(spacing: 2) {
        Text(label)
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
    .accessibilityLabel(Text("Speed \(label)×"))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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

// MARK: - Double rounding helper

private extension Double {
  func rounded(toPlaces places: Int) -> Double {
    let multiplier = pow(10.0, Double(places))
    return (self * multiplier).rounded() / multiplier
  }
}
