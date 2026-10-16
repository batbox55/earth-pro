import Foundation

/// The previous identifier is used only to restore existing preferences and credentials.
enum EarthAppIdentity {
    static let previousIdentifier = "local.earthpro.swiftclone"
    static func restorePreferences() {
        let preferences = UserDefaults.standard
        guard !preferences.bool(forKey: "earthProIdentityRestored") else { return }
        if let previous = preferences.persistentDomain(forName: previousIdentifier) {
            for (key, value) in previous where preferences.object(forKey: key) == nil {
                preferences.set(value, forKey: key)
            }
        }
        preferences.set(true, forKey: "earthProIdentityRestored")
    }
}
