import Foundation
import Testing
@testable import StrataFiles

@Suite struct PreferencesMigrationTests {
    @Test func importsOnlyMissingSettingsOnce() throws {
        let old = "migration-old-\(UUID())", new = "migration-new-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: new))
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        defaults.setPersistentDomain(["favoritePaths": ["/tmp/example"], "theme": "dark"], forName: old)
        defaults.setPersistentDomain(["theme": "light"], forName: new)
        Prefs.migratePreferences(defaults: defaults, from: old, to: new)
        var migrated = try #require(defaults.persistentDomain(forName: new))
        #expect(migrated["theme"] as? String == "light")
        #expect(migrated["favoritePaths"] as? [String] == ["/tmp/example"])
        #expect(defaults.persistentDomain(forName: old)?["theme"] as? String == "dark")
        migrated.removeValue(forKey: "favoritePaths")
        defaults.setPersistentDomain(migrated, forName: new)
        Prefs.migratePreferences(defaults: defaults, from: old, to: new)
        #expect(defaults.persistentDomain(forName: new)?["favoritePaths"] == nil)
    }
}
