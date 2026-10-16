import Foundation

enum EarthMCPInstructions {
    static func configuration(endpoint: String, token: String) -> String {
        let config: [String: Any] = ["mcpServers": ["earth-pro": [
            "type": "http", "url": endpoint,
            "headers": ["Authorization": "Bearer \(token)"]
        ]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func prompt(appPath: String, configuration: String?) -> String {
        let connection = configuration.map {
            """
            MCP is enabled for this app session. Add this Streamable HTTP server to your local MCP client configuration, then connect:

            \($0)

            This configuration contains a local control token. Keep it local and out of logs or shared messages. Disabling MCP, re-enabling it, or restarting Earth Pro invalidates this connection; ask me to copy a fresh prompt from the app.
            """
        } ?? """
        In Earth Pro, click the network icon in the top toolbar (or Tools → Local MCP Control), enable “Allow local LLM control”, and click “Copy LLM Prompt” again. The new prompt will contain the authenticated Streamable HTTP configuration for http://127.0.0.1:18794/mcp. The server is currently off; do not assume you are connected.
        """
        return """
        Help me control the Earth Pro macOS app locally through MCP.

        Find or open Earth Pro at this local path:
        \(appPath)

        \(connection)

        You need an MCP-capable client running on this Mac that supports Streamable HTTP and Authorization headers. A remote chat alone cannot reach my Mac's localhost. If you cannot configure or connect MCP, explain the client setup I need; do not claim you have controlled the app.

        Once connected, initialize MCP, discover tools with tools/list, and call get_state before making changes. Use the returned tool schemas for arguments. Available tools:
        • get_state: inspect the current camera, provider, layers, styled places, selected search pin, search results/suggestions with IDs, address-import progress, overlays, and recording state.
        • fly_to: navigate, zoom, tilt, and change heading.
        • set_provider and set_layer: select map providers and enable or disable layers.
        • search: find a location and zoom to its colored pin; set suggestions_only=true to request typing suggestions. Read get_state for asynchronous results.
        • select_search_result: choose a result_id from get_state, or a suggestion_index together with its exact query. Selecting a result zooms closely to its highlighted pin.
        • add_geometry and update_geometry: create or edit places, including color (#RRGGBB), pin_shape (pin/circle/square/diamond), pin_icon (location/star/home/flag/mountain/camera/food/car), notes, coordinates, and visibility. update_geometry can edit the temporary search pin; set save=true to keep it in My Places.
        • remove_geometry and undo_redo: remove a place or undo/redo saved-place changes. Preserve unrelated places.
        • address_import: action=start accepts either newline-separated text or an addresses array, plus an optional color. Up to 250 unique addresses are resolved using the selected provider, saved as pins, and framed together. This returns a job_id immediately: poll action=status (or get_state) until running=false, then inspect plotted_ids and each row's match/error. action=stop keeps already resolved matches. A successful start is not a completed import. Coordinate pairs work without network lookups; Apple/OpenStreetMap address lookup needs no key.
        • image_overlay: add an image from an absolute local file path, update its bounds/rotation/opacity/visibility, or remove it by ID.
        • record_video: start or stop an MP4 recording; report the saved path after stopping.

        Act on my requested task, preserve unrelated places and layers, and inspect get_state afterward to confirm the result. Google Maps requires a key already configured in Earth Pro; free providers work without one. Never request or expose my Google API key. If the connection fails, ask me to check that Earth Pro is running and MCP is enabled, then copy a fresh prompt. Do not scan other ports, bypass authentication, or open the server to the network.

        Start by connecting and reporting the current view and available tools. Then ask what I would like to do in Earth Pro.
        """
    }
}
