import Foundation
import Network

/// MCP Streamable HTTP (2025-11-25), JSON responses, no unsolicited server messages.
/// Loopback binding, exact Host/Origin checks and a per-enable bearer token protect local control.
@MainActor final class EarthMCPServer {
    private weak var store: EarthStore?
    let addressImporter = AddressPinImporter()
    private var addressImportJobID: UUID?
    private var listener: NWListener?
    private var connections: [UUID:NWConnection]=[:]
    private var generation=UUID()
    private(set) var port: UInt16
    let token=UUID().uuidString+UUID().uuidString
    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }
    init(store: EarthStore, port: UInt16=18794) { self.store=store;self.port=port }
    func start() throws {
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        let listener=try NWListener(using:parameters); self.listener=listener; let epoch=generation
        listener.stateUpdateHandler={ [weak self] state in MainActor.assumeIsolated {
            guard let self,self.generation==epoch else { return }
            switch state {
            case .ready: self.port=self.listener?.port?.rawValue ?? self.port;self.store?.mcpStatus="On · \(self.endpoint)"
            case .failed: self.stop();self.store?.mcpEnabled=false;self.store?.mcpStatus="Could not open the local MCP port. Close another app using it and retry."
            default:break
            }
        }}
        listener.newConnectionHandler={ [weak self] c in MainActor.assumeIsolated { self?.accept(c) }}
        listener.start(queue:.main)
    }
    func stop() {
        if addressImporter.jobID == addressImportJobID { addressImporter.stop() }
        generation=UUID();listener?.cancel();listener=nil
        let active=connections.values;connections=[:];active.forEach{$0.cancel()}
    }
    private func accept(_ c: NWConnection) {
        guard connections.count<12 else { c.cancel();return }
        let id=UUID();connections[id]=c
        c.stateUpdateHandler={ [weak self] state in MainActor.assumeIsolated { if case .cancelled=state { self?.connections.removeValue(forKey:id) } }}
        c.start(queue:.main);receive(c,Data(),generation)
        DispatchQueue.main.asyncAfter(deadline:.now()+15) { c.cancel() }
    }
    private func reply(_ c: NWConnection,_ status: String,_ value: Any?=nil) {
        let body=value.flatMap{try? JSONSerialization.data(withJSONObject:$0,options:[.sortedKeys])} ?? Data()
        var data=Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8);data.append(body)
        c.send(content:data,completion:.contentProcessed{_ in c.cancel()})
    }
    private func receive(_ c: NWConnection,_ previous: Data,_ epoch: UUID) {
        c.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] chunk,_,complete,error in MainActor.assumeIsolated {
            guard let self,self.generation==epoch,self.store?.mcpEnabled==true else { c.cancel();return }
            var data=previous;if let chunk { data.append(chunk) }
            guard data.count<=1_048_576 else { self.reply(c,"413 Payload Too Large");return }
            guard let separator=data.range(of:Data("\r\n\r\n".utf8)) else {
                if data.count>8192 || complete || error != nil { c.cancel() } else { self.receive(c,data,epoch) };return
            }
            guard let header=String(data:data[..<separator.lowerBound],encoding:.utf8) else { self.reply(c,"400 Bad Request");return }
            let lines=header.components(separatedBy:"\r\n"), first=lines[0].components(separatedBy:" ")
            var headers:[String:String]=[:]
            for line in lines.dropFirst() { guard let colon=line.firstIndex(of:":") else { continue };let key=line[..<colon].lowercased();if headers[key] != nil { self.reply(c,"400 Bad Request");return };headers[key]=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces) }
            guard headers["host"]=="127.0.0.1:\(self.port)", headers["origin"]==nil || headers["origin"]=="http://127.0.0.1:\(self.port)" else { self.reply(c,"403 Forbidden");return }
            guard headers["authorization"]=="Bearer \(self.token)" else { self.reply(c,"401 Unauthorized");return }
            guard first.count==3,first[1]=="/mcp" else { self.reply(c,"404 Not Found");return }
            guard first[0]=="POST" else { self.reply(c,"405 Method Not Allowed");return }
            guard headers["content-type"]?.lowercased().hasPrefix("application/json")==true,
                  headers["transfer-encoding"]==nil,let count=Int(headers["content-length"] ?? ""),count>=0,count<=1_000_000 else { self.reply(c,"400 Bad Request");return }
            let body=data[separator.upperBound...]
            if body.count<count { if complete || error != nil { c.cancel() } else { self.receive(c,data,epoch) };return }
            guard body.count==count,let request=try? JSONSerialization.jsonObject(with:Data(body)) as? [String:Any] else { self.reply(c,"400 Bad Request");return }
            if let version=headers["mcp-protocol-version"], !["2025-11-25","2025-06-18"].contains(version) { self.reply(c,"400 Bad Request");return }
            Task { [weak self] in
                guard let self,self.generation==epoch,self.store?.mcpEnabled==true else { c.cancel();return }
                let result=await self.rpc(request)
                guard self.generation==epoch else { c.cancel();return }
                self.reply(c,result == nil ? "202 Accepted" : "200 OK",result)
            }
        }}
    }
    func rpc(_ request: [String:Any]) async -> [String:Any]? {
        let id=request["id"] ?? NSNull()
        func error(_ code:Int,_ message:String)->[String:Any] { ["jsonrpc":"2.0","id":id,"error":["code":code,"message":message]] }
        guard request["jsonrpc"] as? String=="2.0", let method=request["method"] as? String else { return error(-32600,"Invalid JSON-RPC request") }
        if request["id"]==nil { return nil }
        let params=request["params"] as? [String:Any] ?? [:]
        var result:[String:Any]
        switch method {
        case "initialize":
            let requested=params["protocolVersion"] as? String ?? "2025-11-25"
            result=["protocolVersion":requested=="2025-06-18" ? requested : "2025-11-25","capabilities":["tools":[:]],"serverInfo":["name":"earth-pro-local","version":"1.0"]]
        case "ping":result=[:]
        case "tools/list":result=["tools":Self.tools]
        case "tools/call":
            guard let store,store.mcpEnabled else { return error(-32000,"Local MCP is off") }
            do {
                let value=try await execute(params["name"] as? String ?? "",params["arguments"] as? [String:Any] ?? [:],store)
                let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
                result=["content":[["type":"text","text":String(decoding:data,as:UTF8.self)]]]
            } catch { result=["isError":true,"content":[["type":"text","text":error.localizedDescription]]] }
        default:return error(-32601,"Method not found")
        }
        return ["jsonrpc":"2.0","id":id,"result":result]
    }
    static var tools:[[String:Any]] {
        func tool(_ name:String,_ description:String,_ properties:[String:Any]=[:],_ required:[String]=[])->[String:Any] {
            ["name":name,"description":description,"inputSchema":["type":"object","properties":properties,"required":required,"additionalProperties":false]]
        }
        let number:[String:Any]=["type":"number"], string:[String:Any]=["type":"string"], boolean:[String:Any]=["type":"boolean"]
        return [
            tool("get_state","Read camera, provider, layers, styled pins, search results/suggestions, address-import progress, image overlays and recording state. API keys are never returned."),
            tool("fly_to","Move the camera to a coordinate. Distance is meters.",["latitude":number,"longitude":number,"distance":number,"heading":number,"pitch":number],["latitude","longitude"]),
            tool("set_provider","Select Apple Maps, OpenStreetMap, or Google Maps. Google requires a user-configured key.",["provider":["type":"string","enum":MapProvider.allCases.map(\.rawValue)]],["provider"]),
            tool("set_layer","Toggle a named layer (buildings, borders, labels, places, photos, roads, clouds, earthquakes, parks, transit, traffic, water, wikipedia, primary, terrain, grid, saved_places).",["layer":string,"enabled":boolean],["layer","enabled"]),
            tool("search","Search for a place and zoom to its highlighted pin, or request typing suggestions only. Read get_state afterward for asynchronous results/suggestions.",["query":string,"suggestions_only":boolean],["query"]),
            tool("add_geometry","Save a styled placemark, path or polygon. Points use latitude/longitude; pin_shape and pin_icon apply to point geometry.",Self.geometryProperties.merging(["name":string,"kind":["type":"string","enum":["point","path","polygon"]],"points":Self.pointsSchema]) { _, new in new },["name","kind","points"]),
            tool("image_overlay","Add a local image, update georeferencing/opacity/visibility, or remove an overlay. File paths are only read as images, never executed.",["action":["type":"string","enum":["add","update","remove"]],"path":string,"id":string,"north":number,"south":number,"east":number,"west":number,"rotation":number,"opacity":number,"visible":boolean],["action"]),
            tool("record_video","Start or stop recording the map view. MCP recordings are saved under Movies/EarthPro with unique filenames.",["action":["type":"string","enum":["start","stop"]]],["action"])
        ] + Self.recentFeatureTools + Self.dataTools
    }
    private func execute(_ name:String,_ a:[String:Any],_ s:EarthStore) async throws -> [String:Any] {
        func invalid(_ text:String)->Error { KMLError.invalid(text) }
        func number(_ key:String,_ fallback:Double?=nil) throws -> Double {
            guard let n=a[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else { if let fallback { return fallback };throw invalid("Expected finite number: \(key)") };return n.doubleValue
        }
        switch name {
        case "get_state":
            let features=try JSONSerialization.jsonObject(with:JSONEncoder().encode(s.features))
            var state: [String: Any] = ["latitude":s.latitude,"longitude":s.longitude,"distance":s.distance,"heading":s.heading,"pitch":s.pitch,"provider":s.provider.rawValue,"mode":s.mode.rawValue,"layers":s.layers.enabled,"features":features,"overlays":s.imageOverlays.map{["id":$0.id.uuidString,"name":$0.name,"visible":$0.isVisible,"opacity":$0.opacity,"north":$0.north,"south":$0.south,"east":$0.east,"west":$0.west,"rotation":$0.rotation] as [String:Any]},"recording":s.recording,"status":s.status,"searchResults":s.searchHits.map{["title":$0.title,"latitude":$0.point.latitude,"longitude":$0.point.longitude] as [String:Any]}]
            state.merge(try recentFeatureState(s)) { _, new in new }; state.merge(try dataFeatureState(s)) { _, new in new }; return state
        case "fly_to":
            let p=try GeoPoint(latitude:number("latitude"),longitude:number("longitude")), distance=try number("distance",s.distance),heading=try number("heading",s.heading),pitch=try number("pitch",s.pitch)
            guard p.isValid,(100...45_000_000).contains(distance),(0...80).contains(pitch) else { throw invalid("Invalid coordinate, distance (100–45000000 m) or pitch (0–80°)") }
            s.fly(to:p,distance:distance);s.heading=GeoMath.normalizedLongitude(heading);s.setPitch(pitch)
        case "set_provider":
            guard let text=a["provider"] as? String,let p=MapProvider(rawValue:text) else { throw invalid("Unknown provider") }
            if p == .google && s.googleKey == nil { throw invalid("Connect Google Maps in the app first") }
            s.chooseProvider(p);s.setMode(.map)
        case "set_layer":
            guard let layer=a["layer"] as? String,let enabled=a["enabled"] as? Bool else { throw invalid("Expected layer and enabled") }
            if layer=="buildings" { guard !enabled || s.provider != .openStreetMap else { throw invalid("OpenStreetMap raster tiles do not support 3D buildings") };s.setBuildingsLayer(enabled) }
            else if layer=="terrain" { s.terrain=enabled }
            else if layer=="grid" { s.grid=enabled }
            else if layer=="saved_places" { s.showPlaces=enabled }
            else if let key=zip(["borders","labels","places","photos","roads","buildings","clouds","earthquakes","parks","transit","traffic","water","wikipedia"],EarthLayers.selectionKeys).first(where:{$0.0==layer})?.1 { s.layers[keyPath:key]=enabled }
            else if layer=="primary" { s.layers.primary=enabled }
            else { throw invalid("Unknown layer") }
        case "search":
            guard let query=a["query"] as? String,!query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,query.count<=300 else { throw invalid("Expected query (1–300 characters)") }
            if let value = a["suggestions_only"] { guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw invalid("suggestions_only must be a boolean") } }
            guard !addressImporter.running else { throw invalid("Stop the address import before starting another search") }
            if a["suggestions_only"] as? Bool == true { s.suggestSearch(query) }
            else { s.searchText=query; s.search() }
        case "add_geometry":
            guard let title=a["name"] as? String,let raw=a["kind"] as? String,let kind=FeatureKind(rawValue:raw) else { throw invalid("Invalid geometry arguments") }
            var feature=EarthFeature(name:title,kind:kind,points:try Self.geometryPoints(a["points"]))
            try Self.applyGeometryOptions(a, to:&feature)
            guard feature.isValid else { throw invalid("Invalid geometry") };s.save(feature);return ["id":feature.id.uuidString]
        case "image_overlay":
            let action=a["action"] as? String
            var item:EarthImageOverlay
            if action=="add" { guard let path=a["path"] as? String,path.hasPrefix("/") else { throw invalid("Expected absolute local image path") };item=try s.makeImageOverlay(url:URL(fileURLWithPath:path)) }
            else { guard let text=a["id"] as? String,let id=UUID(uuidString:text),let found=s.imageOverlays.first(where:{$0.id==id}) else { throw invalid("Unknown overlay ID") };item=found }
            if action=="remove" { s.imageOverlays.removeAll{$0.id==item.id};s.persistImageOverlays();return ["removed":true] }
            guard action=="add" || action=="update" else { throw invalid("Unknown overlay action") }
            if a["north"] != nil { item.north=try number("north") };if a["south"] != nil { item.south=try number("south") };if a["east"] != nil { item.east=try number("east") };if a["west"] != nil { item.west=try number("west") };if a["rotation"] != nil { item.rotation=try number("rotation") };if a["opacity"] != nil { item.opacity=try number("opacity") };if let flag=a["visible"] as? Bool { item.isVisible=flag }
            try s.saveImageOverlay(item);return ["id":item.id.uuidString]
        case "record_video":
            if a["action"] as? String=="start" {
                let folder=FileManager.default.urls(for:.moviesDirectory,in:.userDomainMask)[0].appendingPathComponent("EarthPro")
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try await s.startVideoRecording(url:folder.appendingPathComponent("Earth-\(UUID().uuidString).mp4"))
            } else if a["action"] as? String=="stop" { guard await s.stopVideoRecording() else { throw invalid(s.error ?? "No active recording") } }
            else { throw invalid("Expected start or stop") }
            return ["recording":s.recording,"path":s.recordingURL?.path ?? ""]
        default:
            if let result = try await executeDataFeature(name, a, s) { return result }
            let result = try executeRecentFeature(name, a, s)
            if name == "address_import", a["action"] as? String == "start" { addressImportJobID = addressImporter.jobID }
            return result
        }
        return ["ok":true]
    }
}

enum LocalMCPPreference {
    static let key = "earthLocalMCPEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func save(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

@MainActor extension EarthStore {
    /// Restore once per store, so view appearances do not replace live client connections.
    func restoreMCPPreference() {
        guard !mcpPreferenceRestored else { return }
        mcpPreferenceRestored = true
        applyMCPEnabled(LocalMCPPreference.isEnabled())
    }

    func setMCPEnabled(_ enabled:Bool) {
        mcpPreferenceRestored = true
        LocalMCPPreference.save(enabled)
        applyMCPEnabled(enabled)
    }

    private func applyMCPEnabled(_ enabled: Bool) {
        if enabled, mcpEnabled, localMCP != nil { return }
        localMCP?.stop();localMCP=nil;mcpEnabled=false;mcpStatus="Off"
        guard enabled else { return }
        let server=EarthMCPServer(store:self);localMCP=server;mcpEnabled=true;mcpStatus="Starting…"
        do { try server.start() } catch { mcpEnabled=false;mcpStatus=error.localizedDescription;localMCP=nil }
    }
}
