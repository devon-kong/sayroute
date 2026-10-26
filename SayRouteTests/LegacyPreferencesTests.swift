import Foundation
import XCTest
@testable import SayRoute

final class LegacyPreferencesTests: XCTestCase {
    private func fixture() -> (UserDefaults, String, String) {
        let domain = "test.sayroute." + UUID().uuidString
        let legacy = domain + ".legacy"
        let defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: domain)
            defaults.removePersistentDomain(forName: legacy)
        }
        return (defaults, domain, legacy)
    }

    func testImportsOnlyValidatedPreferencesAndKeepsLegacyDomain() {
        let (defaults, domain, legacy) = fixture()
        let original: [String: Any] = ["uuRemotePasteMode": "direct", "overlayPositionMode": "screenTop",
                                       "pasteQuietPeriodSeconds": 2.5, "unrelated": "do not copy"]
        defaults.setPersistentDomain(original, forName: legacy)
        LegacyPreferences.migrate(defaults: defaults, domain: domain, legacyDomain: legacy)
        XCTAssertEqual(defaults.string(forKey: "uuRemotePasteMode"), "direct")
        XCTAssertEqual(defaults.string(forKey: "overlayPositionMode"), "screenTop")
        XCTAssertEqual(defaults.double(forKey: "pasteQuietPeriodSeconds"), 2.5)
        XCTAssertNil(defaults.object(forKey: "unrelated"))
        XCTAssertEqual(defaults.persistentDomain(forName: legacy)?["unrelated"] as? String, "do not copy")
    }

    func testExistingChoicesWinAndMigrationDoesNotReplay() {
        let (defaults, domain, legacy) = fixture()
        defaults.setPersistentDomain(["uuRemotePasteMode": "direct", "overlayPositionMode": "screenTop"], forName: legacy)
        defaults.set("compatibility", forKey: "uuRemotePasteMode")
        LegacyPreferences.migrate(defaults: defaults, domain: domain, legacyDomain: legacy)
        XCTAssertEqual(defaults.string(forKey: "uuRemotePasteMode"), "compatibility")
        defaults.removeObject(forKey: "overlayPositionMode")
        LegacyPreferences.migrate(defaults: defaults, domain: domain, legacyDomain: legacy)
        XCTAssertNil(defaults.object(forKey: "overlayPositionMode"))
        XCTAssertTrue(defaults.bool(forKey: "legacyPreferencesImportedV1"))
    }

    func testInvalidLegacyTypesAndValuesAreIgnored() {
        for bad in ["fast", "", "unknown"] {
            let (defaults, domain, legacy) = fixture()
            defaults.setPersistentDomain(["uuRemotePasteMode": bad, "overlayPositionMode": "sideways",
                                          "pasteQuietPeriodSeconds": true], forName: legacy)
            LegacyPreferences.migrate(defaults: defaults, domain: domain, legacyDomain: legacy)
            XCTAssertNil(defaults.object(forKey: "uuRemotePasteMode"))
            XCTAssertNil(defaults.object(forKey: "overlayPositionMode"))
            XCTAssertNil(defaults.object(forKey: "pasteQuietPeriodSeconds"))
            XCTAssertTrue(defaults.bool(forKey: "legacyPreferencesImportedV1"))
        }
    }

    func testInvalidQuietPeriodsDoNotChangeDefault() {
        for value: Any in [-1.0, 0.0, 10.1, "2.5"] {
            let (defaults, domain, legacy) = fixture()
            defaults.setPersistentDomain(["pasteQuietPeriodSeconds": value], forName: legacy)
            LegacyPreferences.migrate(defaults: defaults, domain: domain, legacyDomain: legacy)
            XCTAssertNil(defaults.object(forKey: "pasteQuietPeriodSeconds"))
        }
    }
}
