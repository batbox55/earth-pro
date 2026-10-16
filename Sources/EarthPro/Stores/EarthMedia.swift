import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor extension EarthStore {
    var imageOverlayURL: URL { libraryURL.deletingLastPathComponent().appendingPathComponent("image-overlays.json") }
    func loadImageOverlays() {
        guard FileManager.default.fileExists(atPath:imageOverlayURL.path) else { return }
        do {
            let decoded = try JSONDecoder().decode([EarthImageOverlay].self,from:Data(contentsOf:imageOverlayURL))
            guard decoded.allSatisfy(\.isValid) else { throw KMLError.invalid("Invalid image overlay data") }
            imageOverlays=decoded
        } catch { self.error="Image overlays could not be loaded. The saved file has been preserved: \(error.localizedDescription)"; imageOverlaysWritable=false }
    }
    func persistImageOverlays() {
        guard imageOverlaysWritable else { error="The existing overlay library could not be read. It has been preserved."; return }
        do {
            try FileManager.default.createDirectory(at:imageOverlayURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(imageOverlays).write(to:imageOverlayURL,options:.atomic)
        } catch { self.error=error.localizedDescription }
    }
    func saveImageOverlay(_ item: EarthImageOverlay) throws {
        guard item.isValid, NSImage(data:item.imageData) != nil else { throw KMLError.invalid("Check the image, name, bounds, rotation and opacity. Bounds must be within ±85° latitude and span at most 180° longitude.") }
        guard imageOverlaysWritable else { throw KMLError.invalid("The saved overlay library is unavailable and has been preserved.") }
        if let index=imageOverlays.firstIndex(where:{$0.id==item.id}) { imageOverlays[index]=item } else { imageOverlays.append(item) }
        persistImageOverlays()
    }
    @discardableResult func addImageOverlay(url: URL) throws -> EarthImageOverlay {
        let item=try makeImageOverlay(url:url)
        try saveImageOverlay(item);overlayEditingID=item.id;return item
    }
    func makeImageOverlay(url: URL) throws -> EarthImageOverlay {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 20_000_000,
              let image=NSImage(contentsOf:url), image.size.width>0, image.size.height>0 else { throw KMLError.invalid("Choose an image under 20 MB.") }
        let scale=min(1,2048/max(image.size.width,image.size.height)), size=NSSize(width:max(1,image.size.width*scale),height:max(1,image.size.height*scale))
        let resized=NSImage(size:size); resized.lockFocus(); image.draw(in:NSRect(origin:.zero,size:size)); resized.unlockFocus()
        guard let tiff=resized.tiffRepresentation, let png=NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]) else { throw KMLError.invalid("The image could not be decoded.") }
        let span=min(30,max(0.001,distance/111_000*0.3)), lat=max(-65,min(65,latitude))
        let item=EarthImageOverlay(name:url.deletingPathExtension().lastPathComponent,imageData:png,north:lat+span/2,south:lat-span/2,east:GeoMath.normalizedLongitude(longitude+span/2),west:GeoMath.normalizedLongitude(longitude-span/2))
        return item
    }
    func importImageOverlay() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.png,.jpeg,.tiff,.heic]; panel.canChooseDirectories=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do { try addImageOverlay(url:url); showImageOverlays=true } catch { self.error=error.localizedDescription }
    }
    func captureMapImage() async throws -> NSImage {
        if mode == .globe, let snapshot=globeSnapshot {
            let image=snapshot(),credit=imageryInformation+" · NASA / Goddard SVS · Natural Earth · Terrain: Mapzen / USGS / NOAA"
            return NSImage(size:image.size,flipped:false) { rect in
                image.draw(in:rect)
                (credit as NSString).draw(at:NSPoint(x:8,y:8),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.white,.backgroundColor:NSColor.black.withAlphaComponent(0.65)])
                return true
            }
        }
        if let snapshot=mapSnapshot { return try await snapshot() }
        throw KMLError.invalid("The map is not ready to capture.")
    }
    func recordVideo() {
        if recording { Task { await stopVideoRecording() }; return }
        let panel=NSSavePanel(); panel.allowedContentTypes=[.mpeg4Movie]; panel.nameFieldStringValue="Earth Recording.mp4"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        Task { do { try await startVideoRecording(url:url) } catch { self.error=error.localizedDescription } }
    }
    func startVideoRecording(url: URL) async throws {
        guard !recording && !recordingFinishing else { throw KMLError.invalid("A recording is already in progress.") }
        let writer=try EarthMovieWriter(url:url,width:1280,height:720)
        movieWriter=writer; recording=true; recordingStarted=Date(); recordingURL=url
        recordingTask=Task { [weak self] in
            let start=ProcessInfo.processInfo.systemUptime
            do {
                while !Task.isCancelled {
                    guard let self else { return }
                    let frameStart=ProcessInfo.processInfo.systemUptime
                    let image=try await self.captureMapImage()
                    guard !Task.isCancelled else { return }
                    guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw KMLError.invalid("The map frame could not be captured.") }
                    try await writer.append(cg,seconds:ProcessInfo.processInfo.systemUptime-start)
                    let delay=max(0.001,1.0/15-(ProcessInfo.processInfo.systemUptime-frameStart))
                    try await Task.sleep(for:.seconds(delay))
                }
            } catch {
                if !Task.isCancelled { self?.error="Recording stopped: \(error.localizedDescription)"; await self?.stopVideoRecording() }
            }
        }
    }
    @discardableResult func stopVideoRecording() async -> Bool {
        guard let writer=movieWriter, !recordingFinishing else { return false }
        recordingTask?.cancel(); recordingTask=nil; recording=false; recordingFinishing=true
        let success: Bool
        do { try await writer.finish(); recordedVideoURL=recordingURL; status="Video saved: \(recordingURL?.path ?? "")"; success=true }
        catch { self.error="Video could not be finalized: \(error.localizedDescription)"; success=false }
        movieWriter=nil; recordingFinishing=false; return success
    }
}
