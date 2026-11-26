//
//  Glucose.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2023-09-24.
//

import Foundation
import SwiftUI
import CryptoKit
import OSLog
import Combine

@MainActor
class Glucose: ObservableObject, Sendable {

    @Published var glucose: Double = 0.0
    @Published var delta: Double = 0.0
    @Published var glucoseTime: Date = Date()
    @Published var glucoseAge: String = ""
    @Published var trend: String = ""
    @Published var fetchedGlucose: Bool = false
    @Published var entries: [GlucoseEntry]? = nil
    @Published var error: String = ""

    @Published var provider: Provider
    private(set) var settings: SettingsStore
    let vs: ViewState

    private var providerCancellable: AnyCancellable?
    private var isFetching: Bool = false

    // Accessed from the nonisolated deinit; both types are safe to touch from any thread.
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    nonisolated(unsafe) private var notificationObserver: NSObjectProtocol?

    /// Snapshot of provider state that views read through `g.provider` (AID
    /// extras, provider errors). Used to forward a change notification only
    /// when that state actually changed, instead of on every provider tick.
    private var lastProviderSnapshot: ProviderSnapshot?

    /// How often the poll loop checks whether a fetch is due.
    private static let pollInterval: Duration = .seconds(15)

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.formattingContext = .listItem
        return formatter
    }()

    var sourceIndex: Int = -1 {
        didSet { provider.sourceIndex = sourceIndex }
    }
    let logger = Logger(subsystem: "tools.t1d.GlucoseBar", category: "glucose")

    func plog(_ message: String, level: OSLogType = .default) {
        let cat = sourceIndex < 0 ? "glucose" : "glucose/\(sourceIndex)"
        Logger(subsystem: "tools.t1d.GlucoseBar", category: cat)
            .dlog(message, category: cat, level: level)
    }
    let notificationCenter = NotificationCenter.default

    public init(_ settingsStore: SettingsStore, viewState: ViewState = .shared) {
        provider = Provider()
        settings = settingsStore
        vs = viewState

        updateProbeURL()
        if let newProvider = makeProvider(for: settingsStore, fallbackToSimulator: false) {
            replaceProvider(with: newProvider)
        }

        registerForNotifications()
        startPolling()
        getGlucose()
    }

    deinit {
        pollTask?.cancel()
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Polling

    /// Polls on the main actor with some timer tolerance so the system can
    /// coalesce wake-ups. Replaces a background `DispatchSourceTimer` that hopped
    /// to the main actor on every tick anyway.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var delay: Duration = .seconds(1)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay, tolerance: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.pollTick()
                delay = Self.pollInterval
            }
        }
    }

    private func pollTick() {
        if !vs.isOnline {
            plog("Aborting fetch because network is offline", level: .default)
            return
        }

        var shouldFetch = false
        if provider.lastFetch.timeIntervalSinceNow <= -60 {
            shouldFetch = true
            plog("Glucose.timer initiating fetch because last fetch was over 1 minute ago", level: .default)
        }

        if let firstEntry = entries?.first,
           firstEntry.date.timeIntervalSinceNow <= -300,
           provider.lastFetch.timeIntervalSinceNow <= -10 {
            shouldFetch = true
            plog("Glucose.timer initiating fetch because latest reading is over 5 minutes old and last fetch was over 10 seconds ago", level: .default)
        }

        if shouldFetch {
            fetchNow()
        }

        getGlucose()
    }

    private func fetchNow() {
        guard !isFetching else {
            plog("Skipping fetch - already in progress", level: .debug)
            return
        }
        isFetching = true
        let provider = self.provider
        Task { [weak self] in
            await provider.fetch()
            self?.isFetching = false
        }
    }

    // MARK: - Provider management

    private func makeProvider(for settings: SettingsStore, fallbackToSimulator: Bool) -> Provider? {
        switch settings.cgmProvider {
        case .nightscout:
            return Nightscout(baseURL: settings.nsURL, token: settings.nsSecret, aidEnabled: settings.aidEnableIntegration)
        case .dexcomshare:
            return DexcomShare(username: settings.dxEmail, password: settings.dxPassword, server: settings.dxServer)
        case .simulator:
            return Simulator("simulate")
        case .null:
            if fallbackToSimulator {
                return Simulator("defaulted")
            }
            plog("No provider configured", level: .debug)
            return nil
        }
    }

    /// Swaps in a new provider, shutting down the previous one so it stops
    /// polling/streaming in the background.
    private func replaceProvider(with newProvider: Provider) {
        provider.teardown()
        provider = newProvider
        provider.sourceIndex = sourceIndex
        lastProviderSnapshot = nil
        subscribeToProvider()
    }

    /// Subscribe to the current provider's changes. Bursts of changes (a fetch
    /// typically flips several `@Published` properties in a row) are coalesced
    /// into a single refresh.
    private func subscribeToProvider() {
        providerCancellable = provider.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.getGlucose()
            }
    }

    private func updateProbeURL() {
        switch settings.cgmProvider {
        case .nightscout:
            vs.providerURL = URL(string: settings.nsURL)
        case .dexcomshare:
            vs.providerURL = URL(string: settings.dxServer.url)
        default:
            vs.providerURL = nil
        }
    }

    func reset(_ settings: SettingsStore) {
        self.settings = settings
        updateProbeURL()

        entries = nil
        fetchedGlucose = false
        glucose = 0.0
        delta = 0.0
        glucoseTime = Date()
        glucoseAge = ""
        trend = ""
        error = ""

        if let newProvider = makeProvider(for: settings, fallbackToSimulator: true) {
            replaceProvider(with: newProvider)
        }

        startPolling()
        plog("Reset glucose object", level: .default)
    }

    func registerForNotifications() {
        if let observer = notificationObserver {
            notificationCenter.removeObserver(observer)
        }
        notificationObserver = notificationCenter.addObserver(
            forName: .computerDidWakeUp,
            object: nil,
            queue: .main,
            using: { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.getGlucose()
                }
            })
    }

    public func setSettings(_ settings: SettingsStore) {
        guard self.settings !== settings else { return }
        reset(settings)
    }

    func reload() {
        self.getGlucose()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        providerCancellable = nil
        provider.teardown()
        if let observer = notificationObserver {
            notificationCenter.removeObserver(observer)
            notificationObserver = nil
        }
    }

    // MARK: - Derived state

    /// Pulls the latest state out of the provider into the published
    /// properties. Only assigns values that actually changed: every assignment
    /// to a `@Published` property re-renders all views observing this object
    /// (menu bar label, popover, chart), even if the value is identical.
    func getGlucose() {
        let provider = self.provider

        // Views read AID extras / provider issues through `g.provider`, which
        // doesn't publish through this object. Forward a single change when
        // that state changes, or when the wall-clock minute rolls over so
        // relative times ("5 min ago", loop status color) stay current.
        let snapshot = ProviderSnapshot(
            issue: provider.providerIssue,
            remoteSource: provider.RemoteGlucoseSource,
            extras: provider.GlucoseSourceExtras,
            minute: Int(Date().timeIntervalSince1970 / 60)
        )
        if snapshot != lastProviderSnapshot {
            lastProviderSnapshot = snapshot
            objectWillChange.send()
        }

        let newError = provider.providerIssue ?? ""
        if error != newError {
            error = newError
        }

        let glucoseEntries = provider.getSafeGlucoseEntries()
        guard let latest = glucoseEntries.first else {
            return
        }

        if glucose != latest.glucose {
            glucose = latest.glucose
        }

        if glucoseTime != latest.date {
            glucoseTime = latest.date
        }

        let newTrend = latest.trend?.arrows ?? ""
        if trend != newTrend {
            trend = newTrend
        }

        if entries != glucoseEntries {
            entries = glucoseEntries
        }

        // In cases where users have duplicate entries in their glucose source
        // this will correctly find the delta based on time.
        let reference = glucoseEntries.dropFirst().first(where: {
            latest.date.timeIntervalSince($0.date) > 30
        })
        let newDelta = reference.map { latest.glucose - $0.glucose } ?? 0.0
        if delta != newDelta {
            delta = newDelta
        }

        let newAge = Self.ageFormatter.localizedString(for: latest.date, relativeTo: Date())
        if glucoseAge != newAge {
            glucoseAge = newAge
        }

        if !fetchedGlucose {
            fetchedGlucose = true
        }
    }
}

private struct ProviderSnapshot: Equatable {
    var issue: String?
    var remoteSource: GlucoseSourceDevice
    var extras: GlucoseSourceExtraProperties
    var minute: Int
}

extension Digest {
    var bytes: [UInt8] { Array(makeIterator()) }
    var data: Data { Data(bytes) }

    var hexStr: String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
