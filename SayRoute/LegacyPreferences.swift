import Foundation
import CoreFoundation

enum LegacyPreferences {
    static func migrate(defaults: UserDefaults = .standard, domain: String = "com.devonkong.sayroute",
                        legacyDomain: String = "com.doubao.murmur") {
        var current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current["legacyPreferencesImportedV1"] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let choices = ["uuRemotePasteMode": ["compatibility", "direct"],
                       "overlayPositionMode": ["followMouse", "screenTop"]]
        for (key, allowed) in choices {
            if current[key] == nil, let value = legacy[key] as? String, allowed.contains(value) {
                current[key] = value
            }
        }
        let key = "pasteQuietPeriodSeconds"
        if current[key] == nil, let value = legacy[key] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
           (0.1...10.0).contains(value.doubleValue) {
            current[key] = value
        }
        current["legacyPreferencesImportedV1"] = true
        defaults.setPersistentDomain(current, forName: domain)
    }
}
