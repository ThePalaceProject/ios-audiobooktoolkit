//
//  FindawayDatabaseVerification.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 5/8/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

// MARK: - FindawayDatabaseVerificationDelegate

@objc protocol FindawayDatabaseVerificationDelegate: class {
  func findawayDatabaseVerificationDidUpdate(_ findawayDatabaseVerification: FindawayDatabaseVerification)
}

// MARK: - FindawayDatabaseVerification

@objc class FindawayDatabaseVerification: NSObject {
  static let shared = FindawayDatabaseVerification()

  var verified = false {
    didSet {
      delegates.allObjects.forEach { delegate in
        delegate.findawayDatabaseVerificationDidUpdate(self)
      }
    }
  }

  private var delegates =
    NSHashTable<FindawayDatabaseVerificationDelegate>(options: [NSPointerFunctions.Options.weakMemory])

  func registerDelegate(_ delegate: FindawayDatabaseVerificationDelegate) {
    delegates.add(delegate)
  }

  func removeDelegate(_ delegate: FindawayDatabaseVerificationDelegate) {
    delegates.remove(delegate)
  }
}
