//
//  RelativeTime.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2025-06-15.
//

import Foundation
import SwiftUI

@MainActor private let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    formatter.formattingContext = .middleOfSentence
    return formatter
}()

@MainActor func relativeTime(time: Date) -> String {
    if time.timeIntervalSinceNow > -60 {
        return String(localized: "< 1 min. ago", comment: "Used for relative time throughout the application when the elapsed time is less than a minute")
    }

    return relativeTimeFormatter.localizedString(for: time, relativeTo: Date())
}
