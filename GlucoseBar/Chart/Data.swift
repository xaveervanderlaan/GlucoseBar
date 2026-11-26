//
//  Data.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2025-05-31.
//

import Foundation
import SwiftUI

struct GraphEntry: Identifiable, Equatable, Sendable {
    var date: Date
    var value: Double
    var trend: GlucoseEntry.GlucoseTrend
    var delta: Double
    var color: Color
    var forecastType: ForecastType
    var glucoseType: GlucoseEntry.GlucoseType?

    struct ID: Hashable, Sendable {
        let forecastType: ForecastType
        let date: Date
    }

    /// Unique per series and timestamp. Using `date` alone collided between
    /// the forecast series (which share timestamps), confusing `ForEach`.
    var id: ID { ID(forecastType: forecastType, date: date) }
}

public enum ForecastType: String, CaseIterable, Identifiable, Sendable {
    case none
    case zt
    case uam
    case iob
    case cob
    case loop
    public var id: String { self.rawValue }
    public var presentable: String {
        switch self {
        case .none:
            return ""
        case .zt:
            return String(localized: "Zero Temp", comment: "Zero temporary basal rate from the oref algorithmic output, used for the legend when choosing forecast lines (not necessarily translated in Trio)")
        case .uam:
            return String(localized: "Unannounced Meal", comment: "Unannounced meal from the oref algorithmic output, used for the legend when choosing forecast lines (not necessarily translated in Trio)")
        case .iob:
            return String(localized: "Insulin On Board", comment: "Insulin on board from the oref algorithmic output, used for the legend when choosing forecast lines (not necessarily translated in Trio)")
        case .cob:
            return String(localized: "Carbs On Board", comment: "Carbohydrates on board from the oref algorithmic output, used for the legend when choosing forecast lines (not necessarily translated in Trio)")
        case .loop:
            return String(localized: "Loop forecast information", comment: "The singular line that the Loop algorithm outputs for forecasts")
        }
    }
    public var int: Int {
        switch self {
        case .none:
            return 0
        case .zt:
            return 1
        case .uam:
            return 2
        case .iob:
            return 3
        case .cob:
            return 4
        case .loop:
            return 5
        }
    }
}

/// One time slice of the forecast "cone": the lowest and highest predicted
/// value across all forecast series at that time.
struct ConeSlice: Identifiable, Equatable, Sendable {
    var date: Date
    var min: Double
    var max: Double
    var id: Date { date }
}

/// Builds the forecast cone from forecast entries.
///
/// Only times covered by every series are included (the span of the shortest
/// series), and the final slice is dropped, matching the original behaviour.
func calculateConeData(entries: [GraphEntry], now: Date = Date()) -> [ConeSlice] {
    var counters: [ForecastType: Int] = [:]
    for entry in entries where entry.forecastType != .none {
        counters[entry.forecastType, default: 0] += 1
    }

    let shortestCount = counters.values.min() ?? 0
    let horizon = now.addingTimeInterval(Double(shortestCount) * 5 * 60)

    var bounds: [Date: (min: Double, max: Double)] = [:]
    for entry in entries where entry.forecastType != .none && entry.date <= horizon {
        if let existing = bounds[entry.date] {
            bounds[entry.date] = (Swift.min(existing.min, entry.value), Swift.max(existing.max, entry.value))
        } else {
            bounds[entry.date] = (entry.value, entry.value)
        }
    }

    var slices = bounds
        .map { ConeSlice(date: $0.key, min: $0.value.min, max: $0.value.max) }
        .sorted { $0.date < $1.date }

    if slices.count > 1 {
        slices.removeLast()
    }

    return slices
}
