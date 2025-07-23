import Foundation
import UIKit

extension TimeInterval {
    var humanReadableRemaining: String {
        let totalSeconds = Int(self)
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600

        if totalSeconds == 0 {
            return NSLocalizedString(
                "0 mins remaining",
                bundle: Bundle.audiobookToolkit()!,
                value: "0 mins remaining",
                comment: "Zero minutes remaining"
            )
        }

        if hours == 0 && minutes == 0 {
            return NSLocalizedString(
                "Less than 1 min remaining",
                bundle: Bundle.audiobookToolkit()!,
                value: "Less than 1 min remaining",
                comment: "Less than one minute remaining"
            )
        }

        if hours > 0 {
            let hrFormat = hours == 1 ? "%d hr" : "%d hrs"
            let minFormat = minutes == 1 ? "%d min" : "%d mins"
            let format = NSLocalizedString(
                "\(hrFormat), \(minFormat) remaining",
                bundle: Bundle.audiobookToolkit()!,
                value: "\(hrFormat), \(minFormat) remaining",
                comment: "Hours and minutes remaining"
            )
            return String(format: format, hours, minutes)
        }

        let minuteKey = minutes == 1 ? "%d min remaining" : "%d mins remaining"
        let format = NSLocalizedString(
            minuteKey,
            bundle: Bundle.audiobookToolkit()!,
            value: minuteKey,
            comment: "Minutes remaining"
        )
        return String(format: format, minutes)
    }
}
