//
//  TrackServeWindow.swift
//  PalaceAudiobookToolkit
//

import Foundation

/// Decides which tracks' in-flight serves to abandon so the set of tracks being
/// read matches the set the loader buffers.
///
/// The loader keeps a read buffer per track and holds `maxBufferedTracks` of
/// them, because reads arriving round-robin over more tracks than are buffered
/// evict the window needed next and the hit rate falls to zero. Nothing bounded
/// how many serves actually ran, so a skip burst produced serves for well over
/// that many tracks at once: the buffers thrashed, every displaced read paid for
/// a whole archive fill, and the chapter the patron was waiting for competed
/// with serves for chapters they had already left (PP-5398).
enum TrackServeWindow {

  /// The hrefs whose serves are outside the buffered window, least recently
  /// active last.
  ///
  /// `recencyOrder` is the hrefs with a serve in flight, most recently active
  /// first, and may repeat an href when several ranges of one track are being
  /// served; a track occupies one slot however many ranges it has. A window of
  /// zero or less abandons nothing, so a misconfigured bound disables the
  /// behaviour instead of cancelling every serve.
  static func hrefsToAbandon(recencyOrder: [String], window: Int) -> [String] {
    guard window > 0 else { return [] }

    var seen = Set<String>()
    var distinct: [String] = []
    for href in recencyOrder where !seen.contains(href) {
      seen.insert(href)
      distinct.append(href)
    }

    guard distinct.count > window else { return [] }
    return Array(distinct[window...])
  }
}
