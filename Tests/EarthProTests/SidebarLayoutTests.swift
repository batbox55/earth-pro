import AppKit
import SwiftUI
import XCTest
@testable import EarthPro

/// Opt-in native rendering checks; synthetic library and test-process preferences only.
final class SidebarLayoutTests: XCTestCase {
    @MainActor func testCompactSidebarRendering() async throws {
        guard let output = ProcessInfo.processInfo.environment["EARTH_SIDEBAR_SNAPSHOTS"] else {
            throw XCTSkip("Set EARTH_SIDEBAR_SNAPSHOTS to inspect native compact layouts")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let keys = ["earthSidebarStacked", "earthSidebarPlacesFraction", "earthSidebarLayerGroups", "earthSidebarExpandedFolders"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, original) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        for height in [580.0, 720.0] {
        for width in [260.0, 295.0, 360.0] {
            for scenario in ["places", "layers", "data", "stacked-search"] {
                let store = EarthStore(libraryURL: directory.appendingPathComponent(UUID().uuidString))
                let folder = try store.createFolder(name: "Field survey and utility connections")
                store.features = (1...8).map { index in
                    var place = EarthFeature(name: "Survey location \(index) with a longer title", kind: .point, points: [.init(latitude: 37, longitude: -122)])
                    place.folderID = folder
                    place.notes = "Inspection notes for the selected location"
                    return place
                }
                store.customDataLayers = [CustomDataLayer(name: "Water distribution and service connections")]
                store.discoveryStatus = "Zoom closer or choose an area to find local sources."
                store.setSidebarSection(scenario == "data" ? .data : scenario == "layers" ? .layers : .places)
                defaults.set(scenario == "stacked-search", forKey: keys[0])
                defaults.set(0.5, forKey: keys[1])
                defaults.set("Map details|Terrain & 3D|Nature & transport|Photos & articles|Weather & events", forKey: keys[2])
                defaults.set("unfiled,\(folder.uuidString)", forKey: keys[3])
                if scenario == "stacked-search" {
                    store.searchHits = (1...6).map { .init(title: "Suggested location \($0)", subtitle: "Example city and street address", point: .init(latitude: 37, longitude: -122)) }
                }
                let view = NSHostingView(rootView: SidebarView(store: store).frame(width: width, height: height))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                view.frame = NSRect(x: 0, y: 0, width: width, height: height)
                try await Task.sleep(for: .milliseconds(180))
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.bounds.width, width)
                XCTAssertEqual(view.bounds.height, height)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(Int(width))-\(Int(height))-\(scenario).png"))
                func scrollViews(_ node: NSView) -> [NSScrollView] {
                    (node as? NSScrollView).map { [$0] } ?? node.subviews.flatMap(scrollViews)
                }
                let scrollers = scrollViews(view)
                XCTAssertFalse(scrollers.isEmpty, "Every pane must retain scrolling at compact sizes")
                for scroll in scrollers {
                    guard let document = scroll.documentView else { continue }
                    let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                try await Task.sleep(for: .milliseconds(150))
                view.layoutSubtreeIfNeeded()
                let bottomBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bottomBitmap)
                try XCTUnwrap(bottomBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("\(Int(width))-\(Int(height))-\(scenario)-bottom.png"))
                window.close()
                store.discoveryTask?.cancel()
            }
        }
        }
    }
}
