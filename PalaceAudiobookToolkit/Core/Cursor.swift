//
//  Cursor.swift
//  NYPLAudiobookToolkit
//
//  Created by Dean Silfen on 2/15/18.
//  Copyright © 2018 Dean Silfen. All rights reserved.
//

import UIKit

public final class Cursor<T> {
  public var currentElement: T {
    data[index]
  }

  public func prev() -> Cursor<T>? {
    Cursor(data: data, index: index - 1)
  }

  public func next() -> Cursor<T>? {
    Cursor(data: data, index: index + 1)
  }

  public func first() -> Cursor<T>? {
    Cursor(data: data, index: data.startIndex)
  }

  public func cursor(at: (_ element: T) -> Bool) -> Cursor<T>? {
    var cursor: Cursor<T>?
    for (i, element) in data.enumerated() {
      if at(element) {
        cursor = Cursor(data: data, index: i)
        break
      }
    }
    return cursor
  }

  public let data: [T]
  public let index: Int
  public init?(data: [T], index: Int) {
    guard index >= data.startIndex else {
      return nil
    }
    guard index < data.count else {
      return nil
    }
    self.data = data
    self.index = index
  }

  public convenience init?(data: [T]) {
    guard !data.isEmpty else {
      return nil
    }
    self.init(data: data, index: data.startIndex)
  }
}
