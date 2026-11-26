//
//  Forecast.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2025-05-31.
//

import Foundation
import SwiftUI
import Charts

let forecastDuration = 2.5 * 60 * 60

struct DrawForecast: ChartContent {
    /// Forecast points, already limited to the forecast display window.
    let forecasts: [GraphEntry]
    let cone: [ConeSlice]
    /// Time of the latest actual reading; the forecast boundary line is drawn here.
    let boundary: Date
    let yMin: Double
    let yMax: Double
    let forecastType: ForecastDisplay

    var body: some ChartContent {
        if forecastType == .lines {
            DrawLineForecast(data: forecasts)
        }

        if forecastType == .cone {
            DrawConeForecast(cone: cone)
        }

        // Draw forecast boundry line
        RuleMark(x: .value("Time", boundary),
                 yStart: .value("Glucose", yMin),
                 yEnd: .value("Glucose", yMax)).foregroundStyle(.gray.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5]))
    }
}

struct DrawLineForecast: ChartContent {
    let data: [GraphEntry]
    var body: some ChartContent {
        ForEach(data) { point in
            PointMark(
                x: .value("Time", point.date),
                y: .value("Glucose", point.value)
            )
            .lineStyle(StrokeStyle(lineWidth: 1.0))
            .foregroundStyle(point.color)
            .symbolSize(10)
            .interpolationMethod(.cardinal)
        }
    }
}

struct DrawConeForecast: ChartContent {
    let cone: [ConeSlice]

    var body: some ChartContent {
        // Previously a nested ForEach over min × max entries (O(n²) marks to
        // evaluate on every render); the slices are now pre-paired by time.
        ForEach(cone) { slice in
            // Widen flat slices slightly so the cone stays visible.
            let isFlat = slice.max - slice.min == 0
            AreaMark(
                x: .value("Time", slice.date),
                yStart: .value("Min Value", isFlat ? slice.min - 1 : slice.min),
                yEnd: .value("Max Value", isFlat ? slice.max + 1 : slice.max),
                series: .value("ForecastSeries", 1)
            )
            .foregroundStyle(Color.blue.opacity(0.3))
            .interpolationMethod(.catmullRom)
        }
    }
}
