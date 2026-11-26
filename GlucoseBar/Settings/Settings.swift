//
//  Settings.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2023-09-25.
//

import Foundation
import OSLog

@MainActor
class SettingsStore: ObservableObject, @unchecked Sendable {

    /// Raw JSON of the last loaded `menuBarItems`, so a reload only rebuilds
    /// the item containers when the stored configuration actually changed.
    private var loadedMenuBarItemsJSON: String?

    // MARK: - Source identity

    /// The UUID that namespaces all UserDefaults keys for this source.
    let sourceId: UUID

    @Published var sourceName: String = "My CGM"
    @Published var iconSymbol: String = "person.fill"
    @Published var iconColor: CodableColor = .white
    @Published var showSourceIcon: Bool = false

    // MARK: - CGM settings

    @Published var glucoseUnit: GlucoseUnit = .mgdl
    @Published var highThreshold: Double = 180
    @Published var lowThreshold: Double = 70
    @Published var glucoseTarget: Double = 100

    @Published var cgmProvider: CGMProvider = .null
    @Published var graphMinutes: Int = 180

    // Nightscout
    @Published var nsURL: String = "https://my.nightscout.site"
    @Published var nsSecret: String = "my-secret"

    // Dexcom Share
    @Published var dxServer: DexcomServer = .ous
    @Published var dxEmail: String = "your@email.com"
    @Published var dxPassword: String = ""

    // Libre LinkUp
    @Published var libreServer: String = ""
    @Published var libreUsername: String = "your@email.com"
    @Published var librePassword: String = ""
    @Published var libreConnectionID: String = ""

    @Published var showTimeSince: Bool = false
    @Published var showDelta: Bool = true

    // MenuBar layout options
    @Published var showMenuBarIcon: Bool = false
    @Published var menuBarItems: [MenuBarItemContainer] = []
    @Published var menuBarItemSpacing: CGFloat = 8.0
    @Published var zenMode: Bool = false

    // Chart settings
    @Published var glucoseColorScheme: GlucoseColorScheme = .dynamicColor
    @Published var showHighThreshold: Bool = true
    @Published var showLowThreshold: Bool = true
    @Published var showTarget: Bool = true

    // Trio / AID Specifics
    @Published var aidEnableIntegration: Bool = false

    @Published var trioBarShowIOB: Bool = false
    @Published var trioBarShowCOB: Bool = false
    @Published var trioBarShowEventualGlucose: Bool = false

    @Published var aidChartShowForecast: Bool = true
    @Published var aidChartForecastDisplay: ForecastDisplay = .lines
    @Published var aidChartShowIOB: Bool = true
    @Published var aidChartShowCOB: Bool = true
    @Published var aidChartShowEventualGlucose: Bool = true
    @Published var aidChartShowLoopStatus: Bool = true

    @Published var validSettings: Bool = false
    @Published var debugMode: Bool = false

    let logger = Logger(subsystem: "tools.t1d.GlucoseBar", category: "settingsstore")

    // MARK: - Init

    /// Designated initialiser. All UserDefaults keys are namespaced to `sourceId`
    /// so that multiple sources never collide.
    public init(sourceId: UUID) {
        self.sourceId = sourceId
        load()
        // Re-open the log file if debug mode was already enabled before this launch.
        // This is where file rotation happens: the previous session's debug.log gets
        // archived with a timestamp before a fresh one is opened.
        if debugMode {
            DebugLogger.shared.enable()
        }
    }

    /// Toggles debug mode and starts/stops the file logger accordingly.
    func setDebugMode(_ enabled: Bool) {
        debugMode = enabled
        UserDefaults.standard.set(enabled, forKey: "debugMode")
        if enabled {
            DebugLogger.shared.enable()
        } else {
            DebugLogger.shared.disable()
        }
    }

    /// Convenience initialiser that generates a fresh UUID.
    /// Use for previews, one-off tests, and the throwaway instance inside
    /// `Glucose.init` (which is immediately replaced by `setSettings`).
    public convenience init() {
        self.init(sourceId: UUID())
    }

    // MARK: - Key namespacing

    /// Returns a UserDefaults key namespaced to this source's UUID.
    private func key(_ base: String) -> String {
        "\(sourceId.uuidString).\(base)"
    }

    // MARK: - Load / Save

    func load() {
        loadInternal()
    }

    // MARK: - Language-independent decoding

    /// The CGM provider, chart color scheme and forecast style are stored as
    /// their *translated* display name (e.g. "Nachtscout" in Dutch). Older
    /// versions of the app only recognise that format, so it's still written
    /// that way, but reading only matched the current language: after a
    /// language change the value no longer matched and silently reset.
    ///
    /// This matches the stored string against the raw value, the translation
    /// in every language the app ships, and translations that have since been
    /// corrected (see `legacyTranslations`).
    private static func decode<T>(_ stored: String?, _ options: [(value: T, rawValue: String, localizationKey: String)], fallback: T) -> T {
        guard let stored, !stored.isEmpty else { return fallback }
        for option in options where stored == option.rawValue
            || translations(of: option.localizationKey).contains(stored)
            || legacyTranslations[option.localizationKey, default: []].contains(stored) {
            return option.value
        }
        return fallback
    }

    /// Translations that earlier versions shipped (and therefore saved) but
    /// that were corrected later. Brand names like "Nightscout" had been
    /// translated ("Nachtscout"), and a few words had the wrong meaning.
    /// Settings saved with these must keep loading.
    private static let legacyTranslations: [String: Set<String>] = [
        "Nightscout": ["Nachtscout", "Explorador nocturno"],
        "Dexcom Share": ["Dexcom Delen", "Compartir Dexcom", "Condivisione Dexcom", "Dela Dexcom", "Partajare Dexcom", "Udział Dexcom"],
        "Static": ["statisch", "Stationnaire"],
        "Cone": ["Bot", "Klatka", "Conu"],
        "Lines": ["Regels"],
    ]

    private static var translationCache: [String: Set<String>] = [:]

    /// Every translation the app ships for a source-language string.
    private static func translations(of key: String) -> Set<String> {
        if let cached = translationCache[key] {
            return cached
        }
        var names: Set<String> = [key]
        for localization in Bundle.main.localizations {
            if let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                names.insert(bundle.localizedString(forKey: key, value: key, table: nil))
            }
        }
        translationCache[key] = names
        return names
    }

    /// Assigns only when the value differs. Every assignment to a `@Published`
    /// property notifies all observing views, even when the value is unchanged.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func loadInternal() {
        let defaults = UserDefaults.standard

        update(\.validSettings, defaults.bool(forKey: key("validSettings")))
        update(\.debugMode, defaults.bool(forKey: "debugMode"))

        // Identity
        update(\.sourceName, defaults.string(forKey: key("sourceName")) ?? "My CGM")
        update(\.iconSymbol, defaults.string(forKey: key("iconSymbol")) ?? "person.fill")
        update(\.showSourceIcon, defaults.bool(forKey: key("showSourceIcon")))
        if let data = defaults.data(forKey: key("iconColor")),
           let color = try? JSONDecoder().decode(CodableColor.self, from: data) {
            update(\.iconColor, color)
        } else {
            update(\.iconColor, .white)
        }

        // Nightscout
        update(\.nsURL, defaults.string(forKey: key("nsURL")) ?? "https://my.nightscout.site")
        update(\.nsSecret, defaults.string(forKey: key("nsSecret")) ?? "")

        // Dexcom Share
        update(\.dxEmail, defaults.string(forKey: key("dxEmail")) ?? "your@email.com")
        update(\.dxPassword, defaults.string(forKey: key("dxPassword")) ?? "")
        let dxSrv = defaults.string(forKey: key("dxServer")) ?? DexcomServer.ous.url
        switch dxSrv {
        case DexcomServer.us.url:
            update(\.dxServer, .us)
        default:
            update(\.dxServer, .ous)
        }

        // Libre LinkUp
        update(\.libreUsername, defaults.string(forKey: key("libreUsername")) ?? "your@email.com")
        update(\.librePassword, defaults.string(forKey: key("librePassword")) ?? "")
        update(\.libreConnectionID, defaults.string(forKey: key("libreConnectionID")) ?? "")
        update(\.libreServer, defaults.string(forKey: key("libreServer")) ?? "")

        let storedHigh = defaults.double(forKey: key("highThreshold"))
        update(\.highThreshold, storedHigh == 0.0 ? 180 : storedHigh)

        let storedLow = defaults.double(forKey: key("lowThreshold"))
        update(\.lowThreshold, storedLow == 0.0 ? 70 : storedLow)

        let storedGraphMinutes = defaults.integer(forKey: key("graphMinutes"))
        update(\.graphMinutes, storedGraphMinutes == 0 ? 180 : storedGraphMinutes)

        update(\.showTimeSince, defaults.bool(forKey: key("showTimeSince")))
        update(\.showDelta, defaults.bool(forKey: key("showDelta")))
        update(\.showMenuBarIcon, defaults.bool(forKey: key("showMenuBarIcon")))

        if let jsonMenuBarItems = defaults.string(forKey: key("menuBarItems")),
           jsonMenuBarItems != loadedMenuBarItemsJSON {
            loadedMenuBarItemsJSON = jsonMenuBarItems
            if let data = jsonMenuBarItems.data(using: .utf8) {
                do {
                    self.menuBarItems = try JSONDecoder().decode([MenuBarItemContainer].self, from: data)
                } catch {
                    logger.dlog("Unable to decode menuBarItems object from json saved in UserDefaults: \(String(describing: error))", category: "settingsstore", level: .error)
                    self.menuBarItems = []
                }
            }
        }

        var storedMenuBarItemSpacing = defaults.float(forKey: key("menuBarItemSpacing"))
        if storedMenuBarItemSpacing == 0.0 {
            storedMenuBarItemSpacing = 8.0
        }
        update(\.menuBarItemSpacing, CGFloat(storedMenuBarItemSpacing))

        update(\.zenMode, defaults.bool(forKey: key("zenMode")))

        update(\.cgmProvider, Self.decode(defaults.string(forKey: key("cgmProvider")), [
            (CGMProvider.simulator, CGMProvider.simulator.rawValue, "Simulator"),
            (CGMProvider.nightscout, CGMProvider.nightscout.rawValue, "Nightscout"),
            (CGMProvider.dexcomshare, CGMProvider.dexcomshare.rawValue, "Dexcom Share"),
        ], fallback: .null))
        self.logger.dlog("cgmProvider loaded as \(self.cgmProvider.rawValue)", category: "settingsstore", level: .default)

        let gunit = defaults.string(forKey: key("glucoseUnit")) ?? GlucoseUnit.mmoll.presentable
        switch gunit {
        case GlucoseUnit.mmoll.presentable:
            update(\.glucoseUnit, .mmoll)
        default:
            update(\.glucoseUnit, .mgdl)
        }

        let storedTarget = defaults.double(forKey: key("glucoseTarget"))
        update(\.glucoseTarget, storedTarget == 0 ? 100.0 : storedTarget)

        update(\.glucoseColorScheme, Self.decode(defaults.string(forKey: key("glucoseColorScheme")), [
            (GlucoseColorScheme.staticColor, GlucoseColorScheme.staticColor.rawValue, "Static"),
            (GlucoseColorScheme.dynamicColor, GlucoseColorScheme.dynamicColor.rawValue, "Dynamic"),
        ], fallback: .dynamicColor))

        update(\.showHighThreshold, defaults.bool(forKey: key("showHighThreshold")))
        update(\.showLowThreshold, defaults.bool(forKey: key("showLowThreshold")))
        update(\.showTarget, defaults.bool(forKey: key("showTarget")))

        update(\.aidEnableIntegration, defaults.bool(forKey: key("trioEnableIntegration")))

        update(\.trioBarShowIOB, defaults.bool(forKey: key("trioBarShowIOB")))
        update(\.trioBarShowCOB, defaults.bool(forKey: key("trioBarShowCOB")))
        update(\.trioBarShowEventualGlucose, defaults.bool(forKey: key("trioBarShowEventualGlucose")))

        update(\.aidChartShowForecast, defaults.bool(forKey: key("trioChartShowForecast")))
        update(\.aidChartForecastDisplay, Self.decode(defaults.string(forKey: key("trioChartForecastDisplay")), [
            (ForecastDisplay.cone, ForecastDisplay.cone.rawValue, "Cone"),
            (ForecastDisplay.lines, ForecastDisplay.lines.rawValue, "Lines"),
        ], fallback: .lines))

        update(\.aidChartShowIOB, defaults.bool(forKey: key("trioChartShowIOB")))
        update(\.aidChartShowCOB, defaults.bool(forKey: key("trioChartShowCOB")))
        update(\.aidChartShowEventualGlucose, defaults.bool(forKey: key("trioChartShowEventualGlucose")))
        update(\.aidChartShowLoopStatus, defaults.bool(forKey: key("trioChartShowLoopStatus")))
    }

    /// Persists the in-memory settings.
    ///
    /// This used to re-read every key from `UserDefaults` afterwards, which
    /// re-assigned ~40 `@Published` properties and re-rendered every observing
    /// view dozens of times per save (the name field saves on every keystroke).
    /// The in-memory values are already the source of truth, so only
    /// `validSettings` needs to be reflected back.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: key("validSettings"))
        // `debugMode` is a global flag written by `setDebugMode`; writing this
        // source's (possibly stale) copy here could silently undo it.
        defaults.set(self.glucoseUnit.presentable, forKey: key("glucoseUnit"))
        // Stored as the display name for compatibility with older versions;
        // `decode` reads it back in any language.
        defaults.set(self.cgmProvider.presentable, forKey: key("cgmProvider"))


        defaults.set(self.showTimeSince, forKey: key("showTimeSince"))
        defaults.set(self.showDelta, forKey: key("showDelta"))
        defaults.set(self.showMenuBarIcon, forKey: key("showMenuBarIcon"))

        do {
            let jsonMenuBarItems = try JSONEncoder().encode(self.menuBarItems)
            if let jsonString = String(data: jsonMenuBarItems, encoding: String.Encoding.utf8) {
                defaults.set(jsonString, forKey: key("menuBarItems"))
                loadedMenuBarItemsJSON = jsonString
            } else {
                logger.dlog("Unable to convert encoded menuBarItems object to string", category: "settingsstore", level: .error)
            }

        } catch {
            logger.dlog("failed to encode menuBarItems object: \(String(describing: error))", category: "settingsstore", level: .error)
        }

        defaults.set(self.menuBarItemSpacing, forKey: key("menuBarItemSpacing"))

        defaults.set(self.zenMode, forKey: key("zenMode"))

        defaults.set(self.graphMinutes, forKey: key("graphMinutes"))

        defaults.set(self.highThreshold, forKey: key("highThreshold"))
        defaults.set(self.lowThreshold, forKey: key("lowThreshold"))

        // Nightscout
        defaults.set(self.nsURL, forKey: key("nsURL"))
        defaults.set(self.nsSecret, forKey: key("nsSecret"))

        // Dexcom Share
        defaults.set(self.dxServer.url, forKey: key("dxServer"))
        defaults.set(self.dxEmail, forKey: key("dxEmail"))
        defaults.set(self.dxPassword, forKey: key("dxPassword"))

        // Libre LinkUp
        defaults.set(self.libreServer, forKey: key("libreServer"))
        defaults.set(self.libreUsername, forKey: key("libreUsername"))
        defaults.set(self.librePassword, forKey: key("librePassword"))
        defaults.set(self.libreConnectionID, forKey: key("libreConnectionID"))

        defaults.set(self.glucoseTarget, forKey: key("glucoseTarget"))
        defaults.set(self.glucoseColorScheme.displayName, forKey: key("glucoseColorScheme"))
        defaults.set(self.showHighThreshold, forKey: key("showHighThreshold"))
        defaults.set(self.showLowThreshold, forKey: key("showLowThreshold"))
        defaults.set(self.showTarget, forKey: key("showTarget"))

        defaults.set(self.aidEnableIntegration, forKey: key("trioEnableIntegration"))
        defaults.set(self.trioBarShowIOB, forKey: key("trioBarShowIOB"))
        defaults.set(self.trioBarShowCOB, forKey: key("trioBarShowCOB"))
        defaults.set(self.trioBarShowEventualGlucose, forKey: key("trioBarShowEventualGlucose"))
        defaults.set(self.aidChartShowForecast, forKey: key("trioChartShowForecast"))
        defaults.set(self.aidChartForecastDisplay.presentable, forKey: key("trioChartForecastDisplay"))
        defaults.set(self.aidChartShowIOB, forKey: key("trioChartShowIOB"))
        defaults.set(self.aidChartShowCOB, forKey: key("trioChartShowCOB"))
        defaults.set(self.aidChartShowEventualGlucose, forKey: key("trioChartShowEventualGlucose"))
        defaults.set(self.aidChartShowLoopStatus, forKey: key("trioChartShowLoopStatus"))

        // Identity
        defaults.set(self.sourceName, forKey: key("sourceName"))
        defaults.set(self.iconSymbol, forKey: key("iconSymbol"))
        defaults.set(self.showSourceIcon, forKey: key("showSourceIcon"))
        if let data = try? JSONEncoder().encode(self.iconColor) {
            defaults.set(data, forKey: key("iconColor"))
        }

        update(\.validSettings, true)
    }

    /// Removes all UserDefaults keys for this source and reloads (returns to
    /// fresh-install defaults). Called by `SourceManager` when the user tries to
    /// delete the last remaining source.
    func resetToDefaults() {
        let prefix = "\(sourceId.uuidString)."
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: k)
        }
        loadedMenuBarItemsJSON = nil
        menuBarItems = []
        loadInternal()
    }

    func deleteCGMProvider() {
        deleteCGMProviderInternal()
    }

    private func deleteCGMProviderInternal() {
        let defaults = UserDefaults.standard

        switch self.cgmProvider {
        case .nightscout:
            self.nsURL = ""
            self.nsSecret = ""
            defaults.removeObject(forKey: key("nsURL"))
            defaults.removeObject(forKey: key("nsSecret"))
        case .dexcomshare:
            self.dxServer = .ous
            self.dxEmail = ""
            self.dxPassword = ""
            defaults.removeObject(forKey: key("dxServer"))
            defaults.removeObject(forKey: key("dxEmail"))
            defaults.removeObject(forKey: key("dxPassword"))
        default:
            // noop
            return
        }
    }

    func testCGMProvider() async -> Bool {
        var provider: Provider
        self.logger.dlog("testCGMProvider: \(self.cgmProvider.presentable)", category: "settingsstore", level: .default)
        switch self.cgmProvider {
        case .simulator:
            provider = Simulator("test auth")
        case .nightscout:
            provider = Nightscout(baseURL: self.nsURL, token: self.nsSecret, aidEnabled: false)
        case .dexcomshare:
            provider = DexcomShare(username: self.dxEmail, password: self.dxPassword, server: self.dxServer)
        default:
            provider = Simulator("")
        }

        self.logger.dlog("testCGMProvider calling verifyCredentials with provider: \(provider.type.presentable)", category: "settingsstore", level: .default)
        let result = await provider.verifyCredentials()
        // The test provider is throw-away; don't leave its socket connected.
        provider.teardown()
        return result
    }

    func resetApplication() async {
        let installID = UserDefaults.standard.string(forKey: "GlucoseBar.installID")
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        if let installID {
            UserDefaults.standard.set(installID, forKey: "GlucoseBar.installID")
        }
        UserDefaults.standard.set(true, forKey: "debugMode")
        restartApp()
    }

    // Found at: https://topscrech.medium.com/how-to-programmatically-restart-a-macos-app-in-swift-91cdb02e0ac0
    private func restartApp() {
        let bundlePath = Bundle.main.bundlePath

        let command = """
        sleep 0.1; open "\(bundlePath)"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]

        do {
            try task.run()
            exit(0)
        } catch {
            self.logger.dlog("Error restarting app: \(error)", category: "settingsstore", level: .default)
            return
        }
    }

    func disableDebugMode() async -> Bool {
        UserDefaults.standard.set(false, forKey: "debugMode")
        load()
        return true
    }
}

public enum GlucoseUnit: String, CaseIterable, Identifiable, Sendable {
    case mmoll
    case mgdl
    public var id: String { self.rawValue }
    public var presentable: String {
        switch self {
        case .mmoll:
            return "mmol/L"
        case .mgdl:
            return "mg/dL"
        }
    }
}
