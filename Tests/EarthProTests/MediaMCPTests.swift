import MapKit

import XCTest
import AppKit
import AVFoundation
@testable import EarthPro

final class MediaMCPTests: XCTestCase {
    func testLLMPromptHasUsableConnectionAndOffInstructions() throws {
        let endpoint = "http://127.0.0.1:18794/mcp", token = "test-token"
        let config = EarthMCPInstructions.configuration(endpoint: endpoint, token: token)
        let decoded = try JSONSerialization.jsonObject(with: Data(config.utf8)) as! [String: Any]
        let servers = decoded["mcpServers"] as! [String: [String: Any]]
        XCTAssertEqual(servers["earth-pro"]?["url"] as? String, endpoint)
        XCTAssertEqual((servers["earth-pro"]?["headers"] as? [String: String])?["Authorization"], "Bearer test-token")
        let on = EarthMCPInstructions.prompt(appPath: "/Applications/Earth Pro.app", configuration: config)
        XCTAssertTrue(on.contains(config)); XCTAssertTrue(on.contains("tools/list")); XCTAssertTrue(on.contains("get_state"))
        XCTAssertTrue(on.contains("/Applications/Earth Pro.app"))
        let off = EarthMCPInstructions.prompt(appPath: "/Applications/Earth Pro.app", configuration: nil)
        XCTAssertTrue(off.contains("server is currently off")); XCTAssertFalse(off.contains(token))
    }
    private func sampleImage() throws -> CGImage {
        let context=CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));context.fill(CGRect(x:0,y:0,width:64,height:64))
        context.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:0,y:32,width:32,height:32))
        return context.makeImage()!
    }
    @MainActor func testOverlayGeoreferencingPersistenceAndValidation() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let data=NSBitmapImageRep(cgImage:try sampleImage()).representation(using:.png,properties:[:])!
        let file=folder.appendingPathComponent("overlay.png");try data.write(to:file)
        let store=EarthStore(libraryURL:folder.appendingPathComponent("library.json"))
        var item=try store.addImageOverlay(url:file)
        item.north=10;item.south=0;item.west=170;item.east = -170;item.rotation=0
        XCTAssertTrue(item.isValid);XCTAssertEqual(item.center.longitude,-180)
        XCTAssertEqual(item.point(u:0,v:0).latitude,0);XCTAssertEqual(item.point(u:1,v:1).latitude,10)
        XCTAssertEqual(item.point(u:1,v:1).longitude,-170)
        item.rotation=30;item.opacity=0.35;try store.saveImageOverlay(item)
        let reloaded=EarthStore(libraryURL:folder.appendingPathComponent("library.json"));reloaded.loadImageOverlays()
        XCTAssertEqual(reloaded.imageOverlays,[item]);XCTAssertNotNil(item.globeNode(terrain:false))
        let ground=EarthGroundImage(item)!;XCTAssertLessThan(ground.boundingMapRect.width,MKMapRect.world.width/2)
        item.north=item.south;XCTAssertThrowsError(try store.saveImageOverlay(item))
        XCTAssertEqual(reloaded.imageOverlays.count,1)
    }
    func testMovieEncoderProducesPlayableH264AndRefusesOverwrite() async throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        defer { try? FileManager.default.removeItem(at:file) }
        let writer=try EarthMovieWriter(url:file,width:320,height:180),image=try sampleImage()
        for frame in 0..<10 { try await writer.append(image,seconds:Double(frame)/15);try await Task.sleep(for:.milliseconds(10)) }
        try await writer.finish()
        let asset=AVURLAsset(url:file),tracks=try await asset.loadTracks(withMediaType:.video)
        XCTAssertEqual(tracks.count,1)
        let duration=try await asset.load(.duration);XCTAssertGreaterThan(duration.seconds,0.4)
        let generator=AVAssetImageGenerator(asset:asset)
        let decoded=try await generator.image(at:CMTime(seconds:0.2,preferredTimescale:600)).image
        XCTAssertEqual(decoded.width,320);XCTAssertEqual(decoded.height,180)
        XCTAssertThrowsError(try EarthMovieWriter(url:file,width:320,height:180))
    }
    @MainActor func testRecordingLifecycleOnlyReportsCompletedMovies() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=EarthStore(libraryURL:folder.appendingPathComponent("library.json"))
        let image=NSImage(cgImage:try sampleImage(),size:NSSize(width:64,height:64))
        store.globeSnapshot={image}
        let url=folder.appendingPathComponent("capture.mp4")
        try await store.startVideoRecording(url:url)
        XCTAssertTrue(store.recording);XCTAssertNil(store.recordedVideoURL)
        try await Task.sleep(for:.milliseconds(250))
        let completed=await store.stopVideoRecording()
        XCTAssertTrue(completed);XCTAssertFalse(store.recording);XCTAssertFalse(store.recordingFinishing)
        XCTAssertEqual(store.recordedVideoURL,url)
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
    }
    @MainActor func testMCPToolsValidateArgumentsAndNeverReturnCredentials() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=EarthStore(libraryURL:folder.appendingPathComponent("library.json"))
        let mcp=EarthMCPServer(store:store)
        func call(_ name:String,_ arguments:[String:Any]=[:]) async -> [String:Any] { await mcp.rpc(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":name,"arguments":arguments]])! }
        let off=await call("get_state");XCTAssertNotNil(off["error"])
        store.mcpEnabled=true
        _ = await call("fly_to",["latitude":37.77,"longitude":-122.42,"distance":2500,"pitch":60])
        XCTAssertEqual(store.latitude,37.77);XCTAssertEqual(store.pitch,60)
        let bad=await call("fly_to",["latitude":999,"longitude":0]);XCTAssertEqual((bad["result"] as? [String:Any])?["isError"] as? Bool,true)
        let state=await call("get_state"),data=try JSONSerialization.data(withJSONObject:state)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("googleKey"))
        store.mcpEnabled=false
        let disabled=await call("fly_to",["latitude":0,"longitude":0]);XCTAssertNotNil(disabled["error"]);XCTAssertEqual(store.latitude,37.77)
    }
    @MainActor func testMCPHTTPAuthOriginProtocolAndShutdown() async throws {
        let store=EarthStore(libraryURL:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.mcpEnabled=true;let server=EarthMCPServer(store:store,port:0);try server.start()
        defer { server.stop() }
        for _ in 0..<100 { if server.port != 0 { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotEqual(server.port,0)
        func request(auth:Bool,origin:String?=nil) async throws -> (Data,HTTPURLResponse) {
            var request=URLRequest(url:URL(string:server.endpoint)!);request.httpMethod="POST";request.timeoutInterval=3
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            if auth { request.setValue("Bearer "+server.token,forHTTPHeaderField:"Authorization") }
            if let origin { request.setValue(origin,forHTTPHeaderField:"Origin") }
            request.httpBody=try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-11-25","clientInfo":["name":"test","version":"1"],"capabilities":[:]]])
            let (data,response)=try await URLSession.shared.data(for:request);return(data,response as! HTTPURLResponse)
        }
        let unauthorized=try await request(auth:false);XCTAssertEqual(unauthorized.1.statusCode,401)
        let evil=try await request(auth:true,origin:"https://example.com");XCTAssertEqual(evil.1.statusCode,403)
        let valid=try await request(auth:true);XCTAssertEqual(valid.1.statusCode,200)
        let json=try JSONSerialization.jsonObject(with:valid.0) as! [String:Any];XCTAssertNotNil(json["result"])
        store.mcpEnabled=false;server.stop()
        do { _ = try await request(auth:true);XCTFail("MCP port should be closed") } catch { }
    }
}
