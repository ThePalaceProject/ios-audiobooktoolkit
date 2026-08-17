//
//  Reachability.swift
//  PalaceAudiobookToolkit
//
//  Created by Vladimir Fedorov on 15/09/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Network
import SwiftUI
import SystemConfiguration

/// Network-reachability observer for the download scheduler and the player UI.
///
/// Two real races were fixed here, both stemming from `pathUpdateHandler` being
/// invoked on `NWPathMonitor`'s own queue rather than on main:
///
/// 1. `isConnected` is `@Published` and drives SwiftUI, but was assigned
///    directly from that background handler — publishing to SwiftUI off the
///    main thread, which is undefined behaviour.
/// 2. `retriesCounter` was written from that handler while the main-queue
///    `asyncAfter` retry loop was incrementing it, so the retry budget could be
///    reset mid-count or exceeded.
///
/// Both are now confined to main. `updateStatus()` and the counter are
/// main-thread-only by contract, and every entry point hops before touching
/// them.
///
/// - Note: the remaining diagnostics on this type are capture warnings that
///   only clear once it is `@MainActor`, which is the correct end state for an
///   `ObservableObject`. That is deliberately NOT done here: `isConnected` is
///   observed from `AudiobookPlaybackModel.setupBindings()`, which runs from
///   that type's **public** `init`, so isolating this class forces a public API
///   change in the app. The two must migrate together in the UI pass.
final class Reachability: ObservableObject {
  /// Main-thread only — it is `@Published` and drives SwiftUI.
  @Published var isConnected: Bool = false

  private let connectionMonitor = NWPathMonitor()
  // Status update retries
  private let maxRetries = 30
  /// Main-thread only, together with `updateStatus()`.
  private var retriesCounter = 0

  /// Read by `AudiobookNetworkService` from inside a background barrier block
  /// when deciding whether a download may start. Safe off-main: it touches no
  /// mutable state — `NWPathMonitor.currentPath` is documented as readable from
  /// any thread and returns an immutable snapshot.
  var isOnWiFi: Bool {
    let path = connectionMonitor.currentPath
    return path.status == .satisfied
      && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
  }

  func startMonitoring() {
    connectionMonitor.pathUpdateHandler = { [weak self] _ in
      // This seems to be the most reliable way to determine the connectin status
      // path.status remains .unsatisfied during off/on testing
      //
      // Hops to main before touching `retriesCounter` / `isConnected`: this
      // handler runs on the monitor's queue, and both are main-thread-only
      // (one of them is published to SwiftUI).
      DispatchQueue.main.async {
        guard let self else {
          return
        }
        self.retriesCounter = 0
        self.updateStatus()
      }
    }
    let queue = DispatchQueue(label: "NetworkMonitor")
    connectionMonitor.start(queue: queue)
  }

  /// The object that starts the monitor stops it. Previously only
  /// `AudiobookPlaybackModel.deinit` called `stopMonitoring()`, so the
  /// `NWPathMonitor` outlived any other owner — and that cross-object reach
  /// from a deinit is exactly what the main-actor isolation made illegal.
  deinit {
    connectionMonitor.cancel()
  }

  func stopMonitoring() {
    connectionMonitor.cancel()
  }

  /// - Important: main thread only. Reads and writes `retriesCounter` and
  ///   publishes `isConnected`.
  func updateStatus() {
    guard retriesCounter < maxRetries else {
      return
    }
    retriesCounter += 1
    let newStatus = isConnectedToNetwork()
    if isConnected != newStatus {
      isConnected = newStatus
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        self?.updateStatus()
      }
    }
  }

  func isConnectedToNetwork() -> Bool {
    var zeroAddress = sockaddr_in()
    zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
    zeroAddress.sin_family = sa_family_t(AF_INET)

    let defaultRouteReachability = withUnsafePointer(to: &zeroAddress) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { zeroSockAddress in
        SCNetworkReachabilityCreateWithAddress(nil, zeroSockAddress)
      }
    }

    var flags = SCNetworkReachabilityFlags()
    if !SCNetworkReachabilityGetFlags(defaultRouteReachability!, &flags) {
      return false
    }
    let isReachable = (flags.rawValue & UInt32(kSCNetworkFlagsReachable)) != 0
    let needsConnection = (flags.rawValue & UInt32(kSCNetworkFlagsConnectionRequired)) != 0
    return isReachable && !needsConnection
  }
}
