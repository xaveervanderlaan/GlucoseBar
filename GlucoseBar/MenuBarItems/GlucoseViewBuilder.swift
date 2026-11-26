//
//  GlucoseViewBuilder.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2025-06-15.
//

import SwiftUI

/// The menu bar label. `MenuBarExtra` labels can't show colored, multi-part
/// SwiftUI content, so the configured items are rendered into a bitmap.
///
/// Rendering is comparatively expensive, so it only happens when something
/// that is visible in the image changes (see `MenuBarRenderKey`). Previously
/// five overlapping publishers each triggered a render, including on every
/// change of the glucose model, whether or not the label would look different.
struct MenuBarView: View {

    @EnvironmentObject var s: SettingsStore
    @EnvironmentObject var g: Glucose

    @Environment(\.colorScheme) private var colorScheme

    @State private var renderedImage: CGImage?
    @State private var defaultItems: [MenuBarItemContainer] = [
        MenuBarItemContainer(type: .glucosedot),
        MenuBarItemContainer(type: .glucosevalue),
        MenuBarItemContainer(type: .glucosetrend),
        MenuBarItemContainer(type: .glucosedelta)
    ]

    private var menuBarItems: [MenuBarItemContainer] {
        s.menuBarItems.isEmpty ? defaultItems : s.menuBarItems
    }

    /// Everything that influences what the rendered label looks like.
    private var renderKey: MenuBarRenderKey {
        let extras = g.provider.GlucoseSourceExtras
        return MenuBarRenderKey(
            zenMode: s.zenMode,
            items: s.zenMode ? [] : menuBarItems.map { MenuBarItemSnapshot(type: $0.type, settings: $0.settings) },
            spacing: s.menuBarItemSpacing,
            showSourceIcon: s.showSourceIcon,
            iconSymbol: s.iconSymbol,
            iconColor: s.iconColor,
            unit: s.glucoseUnit,
            highThreshold: s.highThreshold,
            lowThreshold: s.lowThreshold,
            glucoseTarget: s.glucoseTarget,
            cgmProvider: s.cgmProvider,
            aidEnabled: s.aidEnableIntegration,
            glucose: g.glucose,
            delta: g.delta,
            trend: g.trend,
            isStale: g.glucoseTime.timeIntervalSinceNow < -360,
            aid: extras.aid,
            iob: extras.iob,
            cob: extras.cob,
            eventualGlucose: extras.eventualGlucose,
            loopAge: extras.enactedAt.map { relativeTime(time: $0) },
            colorScheme: colorScheme
        )
    }

    var body: some View {
        Group {
            if let renderedImage {
                Image(renderedImage, scale: 2, label: Text(accessibilityLabel))
            } else {
                Image(systemName: "questionmark.circle.dashed")
            }
        }
        .onChange(of: renderKey, initial: true) {
            renderedImage = render()
        }
    }

    private var accessibilityLabel: String {
        "\(formatGlucoseForDisplay(settings: s, glucose: g.glucose)) \(s.glucoseUnit.presentable) \(g.trend)"
    }

    private func render() -> CGImage? {
        let content: AnyView = s.zenMode ? AnyView(zenMode) : AnyView(menuStack)
        let renderer = ImageRenderer(content: content)
        return renderer.cgImage
    }

    @ViewBuilder
    func drawMenuBarItem(_ item: MenuBarItemContainer) -> some View {
        Group {
            switch item.type {
            case .glucosevalue:
                GlucoseValueView(viewSettings: item).environmentObject(s).environmentObject(g)
            case .glucosetrend:
                GlucoseTrendView(viewSettings: item).environmentObject(s).environmentObject(g)
            case .glucosedelta:
                GlucoseDeltaView(viewSettings: item).environmentObject(s).environmentObject(g)
            case .glucosedot:
                ZenModeView().environmentObject(s).environmentObject(g)

            case .loopstatus:
                LoopStatusView(viewSettings: item).environmentObject(s).environmentObject(g)
            case .eventualglucose:
                EventualGlucoseView(viewSettings: item).environmentObject(s).environmentObject(g)
            case .cob:
                COBView(viewSettings: item).environmentObject(s).environmentObject(g)
            case .iob:
                IOBView(viewSettings: item).environmentObject(s).environmentObject(g)

            case MenuBarItem.separator:
                SeparatorView(viewSettings: item).environmentObject(s).environmentObject(g)
            }
        }.environment(\.colorScheme, colorScheme == .light ? .light : .dark)
    }

    var menuStack: some View {
        HStack(spacing: s.menuBarItemSpacing) {
            if s.showSourceIcon {
                Image(systemName: s.iconSymbol)
                    .foregroundStyle(s.iconColor.color)
                    .font(.system(size: 22))
                    .padding(.horizontal, 4)
            }
            ForEach(menuBarItems, id: \.id) { item in
                // aid integration only works with nightscout, so don't draw it's views for other providers
                if (s.cgmProvider != .nightscout || !s.aidEnableIntegration) && [.loopstatus, .eventualglucose, .cob, .iob].contains(item.type) {
                    EmptyView()
                // loop doesn't have quite as many bells and whistles as oref, so filter out the things we can't render
                } else if (s.cgmProvider == .nightscout && s.aidEnableIntegration && g.provider.GlucoseSourceExtras.aid == .loop && [.loopstatus, .eventualglucose].contains(item.type)) {
                    EmptyView()
                } else {
                    drawMenuBarItem(item)
                        .fixedSize()
                        .font(.system(size: 26))
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    var zenMode: some View {
        HStack(spacing: s.menuBarItemSpacing) {
            ZenModeView().environmentObject(s).environmentObject(g)
        }
    }
}

private struct MenuBarItemSnapshot: Equatable {
    var type: MenuBarItem
    var settings: [MenuBarItemSetting]
}

private struct MenuBarRenderKey: Equatable {
    var zenMode: Bool
    var items: [MenuBarItemSnapshot]
    var spacing: CGFloat
    var showSourceIcon: Bool
    var iconSymbol: String
    var iconColor: CodableColor
    var unit: GlucoseUnit
    var highThreshold: Double
    var lowThreshold: Double
    var glucoseTarget: Double
    var cgmProvider: CGMProvider
    var aidEnabled: Bool
    var glucose: Double
    var delta: Double
    var trend: String
    var isStale: Bool
    var aid: GlucoseSourceDevice
    var iob: Double?
    var cob: Double?
    var eventualGlucose: Double?
    var loopAge: String?
    var colorScheme: ColorScheme
}
