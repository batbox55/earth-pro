import Foundation
import Security

/// The key is a browser credential: restrict it in Google Cloud even though it is stored in Keychain.
enum GoogleMapsKeychain {
    private static let service = "local.earthpro.app.googlemaps"
    private static let account = "maps-javascript-api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read(allowInteraction: Bool = true) throws -> String? {
        var request = query
        // Launch-time restoration must never hold up the UI or trigger a permission dialog.
        if !allowInteraction { request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(request as CFDictionary, &result)
        var previous = request
        previous[kSecAttrService as String] = EarthAppIdentity.previousIdentifier + ".googlemaps"
        let restoring = status == errSecItemNotFound
        if restoring { status = SecItemCopyMatching(previous as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        if restoring {
            // Delete the old item only after the new Keychain item is safely stored.
            do {
                try write(value)
                previous.removeValue(forKey: kSecReturnData as String)
                previous.removeValue(forKey: kSecMatchLimit as String)
                SecItemDelete(previous as CFDictionary)
            } catch { /* Keep the readable original key if migration is unavailable. */ }
        }
        return value
    }
    static func write(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            request[kSecAttrLabel as String] = "Earth Pro — Google Maps API key"
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        var previous = query
        previous[kSecAttrService as String] = EarthAppIdentity.previousIdentifier + ".googlemaps"
        let previousStatus = SecItemDelete(previous as CFDictionary)
        guard previousStatus == errSecSuccess || previousStatus == errSecItemNotFound else { throw failure(previousStatus) }
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "GoogleMapsKeychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain could not access the Google Maps key (\(status))."])
    }
    static func normalized(_ input: String) -> String? {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 20, key.count <= 200, key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else { return nil }
        return key
    }
}

enum MapProvider: String, CaseIterable { case apple = "Apple Maps", openStreetMap = "OpenStreetMap", google = "Google Maps" }
