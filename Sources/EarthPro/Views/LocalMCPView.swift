import SwiftUI
import AppKit

struct LocalMCPView: View {
    @ObservedObject var store: EarthStore
    @Environment(\.dismiss) private var dismiss
    @State private var copiedPrompt = false
    private var configuration: String? {
        guard store.mcpEnabled, let server = store.localMCP else { return nil }
        return EarthMCPInstructions.configuration(endpoint: server.endpoint, token: server.token)
    }
    private var llmPrompt: String {
        EarthMCPInstructions.prompt(appPath: Bundle.main.bundleURL.path, configuration: configuration)
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("Local MCP Control").font(.title2);Spacer();Button("Done"){dismiss()} }
            Toggle("Allow local LLM control",isOn:Binding(get:{store.mcpEnabled},set:{store.setMCPEnabled($0)})).toggleStyle(.switch)
            Text(store.mcpStatus).font(.callout).textSelection(.enabled)
            Text("When enabled, a local MCP client can navigate, get search suggestions, choose results, customize and manage pins, plot address lists, toggle layers, add shapes and image overlays, and start or stop video recording. Your Google API key is never returned to the client.").fixedSize(horizontal:false,vertical:true)
            Text("Off by default on every launch. Listens only on 127.0.0.1. Switching off closes connections and revokes this session’s token.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if store.mcpEnabled,let server=store.localMCP {
                Text("Add this Streamable HTTP connection to your MCP client:").font(.headline)
                Text(server.endpoint).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                Button("Copy MCP Configuration") {
                    if let configuration { copy(configuration) }
                }
                Text("The copied configuration contains the local control token. Keep it local; copy a new configuration after re-enabling MCP.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Text("Prompt for your LLM").font(.headline)
            ScrollView {
                Text(llmPrompt).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(10)
            }.frame(height: 170).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(copiedPrompt ? "Copied LLM Prompt" : "Copy LLM Prompt") {
                    copy(llmPrompt); copiedPrompt = true
                }.accessibilityIdentifier("copy-llm-prompt")
                Text(store.mcpEnabled ? "Includes this session’s local control token." : "Enable MCP to include live connection details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width:580)
            .onChange(of: store.mcpEnabled) { copiedPrompt = false }
    }
}
