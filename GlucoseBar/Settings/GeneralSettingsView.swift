//
//  GeneralSettingsView.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2025-06-03.
//

import Foundation
import SwiftUI
import AppKit
import OSLog
import LaunchAtLogin

/// App-wide interface language override.
///
/// Stored as `AppleLanguages` in the app's own defaults domain, which is the
/// same mechanism macOS uses for a per-app language chosen in System Settings
/// (General > Language & Region > Applications), so the two stay in sync. The
/// language is resolved at launch, so a change takes effect after a restart.
@MainActor
enum AppLanguage {
    /// Tag used for "follow the system language".
    static let systemDefault = ""

    private static let defaultsKey = "AppleLanguages"

    /// Languages the app ships translations for.
    static let available: [String] = Bundle.main.localizations
        .filter { $0 != "Base" }
        .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }

    /// The language's name in that language, e.g. "Nederlands", "Dansk".
    static func displayName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The override stored for this app, or `systemDefault` when there is none.
    static var current: String {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?[defaultsKey] as? [String],
              let preferred = languages.first
        else { return systemDefault }
        return available.first { preferred == $0 || preferred.hasPrefix("\($0)-") } ?? systemDefault
    }

    /// The override that was in effect when the app launched.
    static let atLaunch: String = current

    static func set(_ code: String) {
        if code == systemDefault {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set([code], forKey: defaultsKey)
        }
    }

    /// Starts a fresh instance of the app and quits this one.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                NSApp.terminate(nil)
            } catch {
                Logger(subsystem: "tools.t1d.GlucoseBar", category: "language")
                    .dlog("Unable to relaunch: \(error.localizedDescription)", category: "language", level: .error)
            }
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var sourceManager: SourceManager

    @State private var showDebugConfirmation = false
    @State private var language: String = AppLanguage.current

    var body: some View {
        ScrollView {
            VStack {
                GroupBox {
                    HStack {
                        if let image = NSImage(named: "AppIcon") {
                            Image(nsImage: image)
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture(count: 4) {
                                    guard sourceManager.sources.first?.settings.debugMode != true else { return }
                                    showDebugConfirmation = true
                                }
                                .alert("Enable Debug Mode?", isPresented: $showDebugConfirmation) {
                                    Button("Enable") {
                                        sourceManager.sources.first?.settings.setDebugMode(true)
                                        sourceManager.refreshToken = UUID()
                                    }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Debug mode logs additional information for troubleshooting purposes.")
                                }
                        }
                        Spacer()
                        VStack {
                            Text("Hi,\nI'm GlucoseBar.").font(.title).multilineTextAlignment(.center)
                            Text(verbatim: "Version: \(Bundle.main.appVersionLong) (\(Bundle.main.appBuild)) ").font(.footnote)
                            Text(verbatim: DistributionChannel.current == .appStore ? "Mac App Store" : DistributionChannel.current == .testFlight ? "TestFlight" : "Direct Download").font(.footnote).foregroundStyle(.secondary)
                            Button(action: {
                                NSWorkspace.shared.open(URL(string: "https://glucosebar.t1d.tools")!)
                            }) {
                                HStack {
                                    Text(verbatim: "glucosebar.t1d.tools").font(.footnote)
                                }
                            }.buttonStyle(.plain).foregroundStyle(.blue).padding(.top, 2)
                            Button(action: {
                                NSWorkspace.shared.open(URL(string: "https://github.com/t1dtools/glucosebar")!)
                            }) {
                                HStack {
                                    Text(verbatim: "GitHub").font(.footnote)
                                }
                            }.buttonStyle(.plain).foregroundStyle(.blue).padding(.top, 2)
                        }
                        Spacer()
                    }.padding()
                }

                Text("Launch Behavior").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                            Text("Automatically start GlucoseBar when you log in to your Mac")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        LaunchAtLogin.Toggle("").toggleStyle(.switch).tint(.blue).fixedSize()
                            .scaleEffect(0.7, anchor: .trailing)
                    }.padding()
                }

                Text("Language").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                GroupBox {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("App Language")
                                Text("The language GlucoseBar uses for all profiles and settings")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Picker("", selection: $language) {
                                Text("System Default").tag(AppLanguage.systemDefault)
                                Divider()
                                ForEach(AppLanguage.available, id: \.self) { code in
                                    Text(verbatim: AppLanguage.displayName(code)).tag(code)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            .onChange(of: language) { _, newValue in
                                AppLanguage.set(newValue)
                            }
                        }
                        .padding()

                        if language != AppLanguage.atLaunch {
                            Divider()
                            HStack {
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundStyle(.secondary)
                                Text("Restart GlucoseBar to apply the new language.")
                                    .font(.caption)
                                Spacer()
                                Button("Restart Now") {
                                    AppLanguage.relaunch()
                                }
                            }
                            .padding()
                        }
                    }
                }
            }.padding()
        }
    }
}
