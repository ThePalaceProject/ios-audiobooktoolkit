//
//  String+sha256Test.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Vladimir Fedorov on 17/08/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

final class String_sha256Test: XCTestCase {

    func testSHA256results() throws {
        // Test string
        let testString = "aàáâäæãåā1234567890"
        // Result received with previous Objective-C implementation
        let expectedString = "3e4e1345cd779669810716fac6648fd937ffbfc38a2bdfb3320eaea364b9032a"
        // Current implementation
        let result = testString.sha256?.hexString
        
        XCTAssertNotNil(result)
        XCTAssertEqual(expectedString, result)
    }

}
