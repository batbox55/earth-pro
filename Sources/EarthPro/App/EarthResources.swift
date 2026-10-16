import Foundation

#if !SWIFT_PACKAGE
// Xcode embeds these resources directly in the app; SwiftPM uses its resource bundle.
extension Bundle {
    static var module: Bundle { .main }
}
#endif
