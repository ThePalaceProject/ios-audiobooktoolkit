//
//  Date+ISO8601.swift
//  r2-shared-swift
//
//  Created by Alexandre Camilleri, Mickaël Menu on 3/22/17.
//
//  Copyright 2018 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import Foundation


public extension Date {
    
    var iso8601: String {
        return DateFormatter.iso8601.string(from: self)
    }
    
}

public extension DateFormatter {
    
    static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
    
    static let bookmarkTimeFormatter: DateFormatter = {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "mm:ss"
        return timeFormatter
    }()
    
    static func iso8601Formatter(for string: String) -> DateFormatter {
        // On iOS 10 and later, this API should be treated withFullTime or withTimeZone for different cases.
        // Otherwise it will accept bad format, for exmaple 2018-04-24XXXXXXXXX
        // Because it will only test the part you asssigned, date, time, timezone.
        // But we should also cover the optional cases. So there is not too much benefit.
        //        if #available(iOS 10.0, *) {
        //            let formatter = ISO8601DateFormatter()
        //            formatter.formatOptions = [.withFullDate]
        //            return formatter
        //        }
        
        // https://developer.apple.com/documentation/foundation/dateformatter
        // Doesn't support millisecond or uncompleted part for date, time, timezone offset.
        let formats = [
            4: "yyyy",
            7: "yyyy-MM",
            10: "yyyy-MM-dd",
            11: "yyyy-MM-ddZ",
            16: "yyyy-MM-ddZZZZZ",
            19: "yyyy-MM-dd'T'HH:mm:ss",
            25: "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        ]
        let defaultFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        
        let format = formats[string.count] ?? defaultFormat
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
    
    static func convertISO8601String(_ dateString: String) -> String? {
        // Check if the input string can be converted to a date
        guard let date = iso8601.date(from: dateString) else {
            return nil
        }
        
        // Create a date formatter for the output format
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MMMM d, yyyy"
        
        // Return the formatted date string
        return outputFormatter.string(from: date)
    }
}

