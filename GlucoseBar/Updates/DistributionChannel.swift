//
//  DistributionChannel.swift
//  GlucoseBar
//
//  Created by Andreas Stokholm on 2026-05-24.
//
//  The update checker that used to live here (which polled the upstream
//  project's version manifest and showed "Update available" reminders) was
//  removed: this fork ships its own builds.
//

import Foundation

enum DistributionChannel {
    case appStore
    case testFlight
    case direct

    /// The channel this build was installed through, detected once per launch.
    static let current: DistributionChannel = detect()

    static func detect() -> DistributionChannel {
        let bundlePath = Bundle.main.bundlePath

        // Check for TestFlight via extended attribute metadata
        let attrName = "com.apple.appstore.metadata"
        let bufSize = getxattr(bundlePath, attrName, nil, 0, 0, 0)
        if bufSize > 0 {
            var buffer = [UInt8](repeating: 0, count: bufSize)
            if getxattr(bundlePath, attrName, &buffer, bufSize, 0, 0) > 0 {
                let data = Data(buffer)
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let metadata = plist["iTunesMetadata"] as? [String: Any],
                   metadata["betaExternalVersionIdentifier"] != nil {
                    return .testFlight
                }
            }
        }

        // Fall back to receipt-based App Store vs direct detection
        guard let receiptURL = Bundle.main.appStoreReceiptURL,
              FileManager.default.fileExists(atPath: receiptURL.path) else {
            return .direct
        }
        return .appStore
    }

    var displayName: String {
        switch self {
        case .appStore: return "App Store"
        case .testFlight: return "TestFlight"
        case .direct: return "Direct"
        }
    }
}
