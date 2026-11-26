//
//  GraphView.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2023-10-01.
//

import Foundation
import SwiftUI
import Charts
import Observation

/// The reading currently under the mouse pointer.
struct HoveredReading: Equatable, Sendable {
    var date: Date
    var value: Double
    var trend: GlucoseEntry.GlucoseTrend
}

/// Hover state shared between the chart overlay and the headline.
///
/// Kept in its own observable object so that moving the mouse only
/// re-renders the two small views that read it. Previously the hover values
/// lived in `GraphView`'s `@State`, so every mouse move rebuilt all chart data
/// and re-rendered every mark in the chart.
@MainActor @Observable
final class ChartHoverState {
    var reading: HoveredReading?

    func set(_ newValue: HoveredReading?) {
        if reading != newValue {
            reading = newValue
        }
    }
}

/// All data the chart needs, computed once per model change.
struct GlucoseChartModel: Equatable, Sendable {
    /// Actual readings, oldest first.
    var glucose: [GraphEntry] = []
    /// Forecast points within the forecast display window.
    var forecasts: [GraphEntry] = []
    var cone: [ConeSlice] = []

    var showForecast = false
    var forecastDisplay: ForecastDisplay = .lines
    var forecastBoundary = Date()
    var showLegend = false
    var isLoop = false

    var yDomain: ClosedRange<Double> = 0...1

    var colorScheme: GlucoseColorScheme = .dynamicColor
    var showHighThreshold = true
    var showLowThreshold = true
    var showTarget = true
    var highThreshold: Double = 180
    var lowThreshold: Double = 70
    var target: Double = 100

    var hasData: Bool { !glucose.isEmpty || !forecasts.isEmpty }

    @MainActor
    init(glucose g: Glucose, settings s: SettingsStore, now: Date = Date()) {
        let extras = g.provider.GlucoseSourceExtras

        let high = convertGlucose(s, glucose: s.highThreshold)
        let low = convertGlucose(s, glucose: s.lowThreshold)
        let colorTarget = convertGlucose(s, glucose: extras.glucoseTarget ?? s.glucoseTarget)

        // Readings within the selected time frame. Duplicated timestamps are
        // dropped so every point has a unique identity.
        let earliestToInclude = now.addingTimeInterval(TimeInterval(-s.graphMinutes * 60))
        var seenDates = Set<Date>()
        var readings: [GraphEntry] = []
        for entry in g.entries ?? [] where entry.date >= earliestToInclude {
            guard seenDates.insert(entry.date).inserted else { continue }
            let value = convertGlucose(s, glucose: entry.glucose)
            let color = getDynamicGlucoseColor(
                glucoseValue: Decimal(value),
                highGlucoseColorValue: Decimal(high),
                lowGlucoseColorValue: Decimal(low),
                targetGlucose: Decimal(colorTarget),
                glucoseColorScheme: s.glucoseColorScheme
            )
            readings.append(GraphEntry(date: entry.date, value: value, trend: entry.trend ?? .notComputable, delta: entry.changeRate ?? 0.0, color: color, forecastType: .none, glucoseType: entry.glucoseType))
        }
        readings.sort { $0.date < $1.date }

        // Forecasts start at the time the AID enacted its last decision.
        let forecastStart = extras.enactedAt ?? now
        var allForecasts: [GraphEntry] = []
        func appendForecast(_ values: [Int]?, color: Color, type: ForecastType) {
            guard let values else { return }
            for (i, value) in values.enumerated() {
                let date = forecastStart.addingTimeInterval(TimeInterval(i * 5 * 60))
                allForecasts.append(GraphEntry(date: date, value: convertGlucose(s, glucose: Double(value)), trend: .notComputable, delta: 0.0, color: color, forecastType: type))
            }
        }
        appendForecast(extras.forecasts.zt, color: .purple, type: .zt)
        appendForecast(extras.forecasts.uam, color: .orange, type: .uam)
        appendForecast(extras.forecasts.cob, color: .yellow, type: .cob)
        appendForecast(extras.forecasts.iob, color: .blue, type: .iob)
        appendForecast(extras.forecasts.loop, color: .blue, type: .loop)

        let forecastHorizon = now.addingTimeInterval(forecastDuration)
        let visibleForecasts = allForecasts.filter { $0.date <= forecastHorizon }
        let cone = calculateConeData(entries: allForecasts, now: now)

        // Loop only has one forecast, so a cone doesn't make sense
        let isLoop = extras.aid == .loop
        let forecastDisplay: ForecastDisplay = isLoop ? .lines : s.aidChartForecastDisplay

        // Y axis range: readings plus whatever forecast is drawn, but never
        // tighter than the default range.
        var values = readings.map(\.value)
        if s.aidChartShowForecast {
            switch forecastDisplay {
            case .cone:
                if let coneMax = cone.map(\.max).max(), coneMax > 0 {
                    values.append(coneMax)
                }
            case .lines:
                values.append(contentsOf: visibleForecasts.map(\.value))
            }
        }
        let defaultMax = convertGlucose(s, glucose: 216.0)
        let defaultMin = convertGlucose(s, glucose: 36.0)
        let maxYMargin = convertGlucose(s, glucose: 36.0)
        let maxY = values.max() ?? defaultMax
        let minY = values.min() ?? defaultMin
        let yLower = Swift.min(minY, defaultMin)
        let yUpper = maxY >= defaultMax ? maxY + maxYMargin : defaultMax

        self.glucose = readings
        self.forecasts = visibleForecasts
        self.cone = cone
        self.showForecast = s.aidChartShowForecast
        self.forecastDisplay = forecastDisplay
        self.forecastBoundary = Swift.min(readings.last?.date ?? now, forecastHorizon)
        self.showLegend = s.aidChartShowForecast && s.aidChartForecastDisplay == .lines
        self.isLoop = isLoop
        self.yDomain = yLower...Swift.max(yUpper, yLower + 1)
        self.colorScheme = s.glucoseColorScheme
        self.showHighThreshold = s.showHighThreshold
        self.showLowThreshold = s.showLowThreshold
        self.showTarget = s.showTarget
        self.highThreshold = high
        self.lowThreshold = low
        self.target = convertGlucose(s, glucose: s.glucoseTarget)
    }
}

struct GraphView: View {

    @ObservedObject var g: Glucose
    @EnvironmentObject var s: SettingsStore
    @EnvironmentObject var vs: ViewState

    @State private var hover = ChartHoverState()
    @State private var isLoading: Bool = false

    @FocusState var buttonFocusState

    init(glucose: Glucose) {
        self.g = glucose
    }

    func reloadData() {
        Task {
            isLoading = true
            await g.provider.fetch()
            isLoading = false
        }
    }

    func changeTimeFrame(minutes: Int) {
        s.graphMinutes = minutes
        s.save()
    }

    /// `selectedTitle` / `title` are localization keys ("3 Hours" / "3").
    @ViewBuilder
    private func timeFrameButton(minutes: Int, selectedTitle: LocalizedStringKey, title: LocalizedStringKey) -> some View {
        Button(s.graphMinutes == minutes ? selectedTitle : title) {
            changeTimeFrame(minutes: minutes)
            buttonFocusState = false
        }.clipShape(Capsule()).buttonStyle(.bordered).focused($buttonFocusState)
    }

    var body: some View {
        let model = GlucoseChartModel(glucose: g, settings: s)
        let graphDataDuration = (-1 * (g.entries?.last?.date.timeIntervalSinceNow ?? 1) / 60 / 60).rounded()

        VStack {
            HStack {
                GraphHeadline(
                    hover: hover,
                    latestTime: g.glucoseTime,
                    latestGlucose: convertGlucose(s, glucose: g.glucose),
                    // `g.trend` holds the arrow glyph, not the direction name,
                    // so take the trend from the latest reading itself.
                    latestTrend: g.entries?.first?.trend ?? .notComputable,
                    unit: s.glucoseUnit
                )
                .padding(.leading, 25).padding(.top, 10)

                // Currently, all three supported AIDs support these options.
                if s.cgmProvider == .nightscout && g.provider.RemoteGlucoseSource != .null {
                    if s.aidChartShowCOB || s.aidChartShowIOB || s.aidChartShowLoopStatus || s.aidChartShowEventualGlucose {
                        Spacer()
                        AidGridView(g: g).environmentObject(s)
                    }
                }
            }.padding()

            HStack {
                if graphDataDuration >= 3 { timeFrameButton(minutes: 180, selectedTitle: "3 Hours", title: "3") }
                if graphDataDuration >= 6 { timeFrameButton(minutes: 360, selectedTitle: "6 Hours", title: "6") }
                if graphDataDuration >= 12 { timeFrameButton(minutes: 720, selectedTitle: "12 Hours", title: "12") }
                if graphDataDuration >= 24 { timeFrameButton(minutes: 1440, selectedTitle: "24 Hours", title: "24") }
                if model.hasData {
                    Spacer()
                    Button(action: {
                        reloadData()
                    }) {
                        HStack {
                            if isLoading {
                                ProgressView().scaleEffect(0.5, anchor: .center).frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }.contentShape(Rectangle())
                    }.help("Refresh all data")
                        .clipShape(Capsule())
                        .buttonStyle(.bordered)
                        .focused($buttonFocusState)
                        .disabled(isLoading)
                }
            }.padding().frame(alignment: .leading)

            GlucoseChart(model: model, hover: hover)
                .equatable()
                .padding()
        }
    }
}

/// Current (or hovered) time, glucose value and trend above the chart.
private struct GraphHeadline: View {
    let hover: ChartHoverState
    let latestTime: Date
    let latestGlucose: Double
    let latestTrend: GlucoseEntry.GlucoseTrend
    let unit: GlucoseUnit

    var body: some View {
        let hovered = hover.reading
        let time = hovered?.date ?? latestTime
        let glucose = hovered?.value ?? latestGlucose
        let trend = hovered?.trend ?? latestTrend

        VStack {
            Text("\(Text(time, format: .dateTime.hour().minute()))").font(.subheadline)
            Text("\(formattedGlucose(glucose, unit: unit)) \(trend.arrows != "↔" ? trend.arrows : "")").font(.largeTitle)
        }
    }
}

/// The chart itself. Equatable so it's only re-rendered when its data changes,
/// not on hover or unrelated parent updates.
private struct GlucoseChart: View, Equatable {
    let model: GlucoseChartModel
    let hover: ChartHoverState

    nonisolated static func == (lhs: GlucoseChart, rhs: GlucoseChart) -> Bool {
        lhs.model == rhs.model && lhs.hover === rhs.hover
    }

    private var legend: KeyValuePairs<String, Color> {
        model.isLoop
            ? ["Forecast": Color.blue]
            : ["UAM": Color.orange, "ZT": Color.purple, "IOB": Color.blue, "COB": Color.yellow]
    }

    var body: some View {
        Chart {
            if model.colorScheme == .staticColor {
                if model.showHighThreshold {
                    RuleMark(y: .value("High", model.highThreshold)).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                }
                if model.showLowThreshold {
                    RuleMark(y: .value("Low", model.lowThreshold)).foregroundStyle(.red).lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                }
            } else if model.colorScheme == .dynamicColor {
                if model.showHighThreshold {
                    RuleMark(y: .value("High", model.highThreshold)).foregroundStyle(dynamicPurple).lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                }
                if model.showLowThreshold {
                    RuleMark(y: .value("Low", model.lowThreshold)).foregroundStyle(dynamicRed).lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                }
            }

            if model.showTarget {
                RuleMark(y: .value("Target", model.target)).foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 1))
            }

            if model.showForecast {
                DrawForecast(
                    forecasts: model.forecasts,
                    cone: model.cone,
                    boundary: model.forecastBoundary,
                    yMin: model.yDomain.lowerBound,
                    yMax: model.yDomain.upperBound,
                    forecastType: model.forecastDisplay
                )
            }
            DrawGlucose(data: model.glucose)
        }
        .chartYScale(domain: model.yDomain)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) {
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        VStack(alignment: .leading) {
                            Text(date, format: .dateTime.hour().minute())
                        }
                    }

                    AxisGridLine()
                    AxisTick()
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ChartHoverLayer(proxy: proxy, geometry: geometry, readings: model.glucose, hover: hover)
            }
        }
        .chartForegroundStyleScale(legend)
        .chartLegend(model.showLegend ? .visible : .hidden)
    }
}

/// Tracks the pointer over the plot area and draws the hovered point.
private struct ChartHoverLayer: View {
    let proxy: ChartProxy
    let geometry: GeometryProxy
    /// Readings sorted oldest first.
    let readings: [GraphEntry]
    let hover: ChartHoverState

    /// Readings further than this from the pointer aren't highlighted.
    private let maxDistance: TimeInterval = 5 * 60

    private var plotOrigin: CGPoint {
        proxy.plotFrame.map { geometry[$0].origin } ?? .zero
    }

    var body: some View {
        let origin = plotOrigin

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let date: Date = proxy.value(atX: location.x - origin.x) else {
                            hover.set(nil)
                            return
                        }
                        hover.set(nearestReading(to: date))
                    case .ended:
                        hover.set(nil)
                    }
                }

            if let reading = hover.reading,
               let position = proxy.position(for: (x: reading.date, y: reading.value)) {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(x: origin.x + position.x, y: origin.y + position.y)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Binary search for the reading closest in time to `date`.
    private func nearestReading(to date: Date) -> HoveredReading? {
        guard !readings.isEmpty else { return nil }

        var low = 0
        var high = readings.count - 1
        while low < high {
            let mid = (low + high) / 2
            if readings[mid].date < date {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var best = readings[low]
        if low > 0, abs(readings[low - 1].date.timeIntervalSince(date)) < abs(best.date.timeIntervalSince(date)) {
            best = readings[low - 1]
        }

        guard abs(best.date.timeIntervalSince(date)) <= maxDistance else { return nil }
        return HoveredReading(date: best.date, value: best.value, trend: best.trend)
    }
}

#Preview {
    GraphView(glucose: Glucose(SettingsStore())).environmentObject(SettingsStore())
}
