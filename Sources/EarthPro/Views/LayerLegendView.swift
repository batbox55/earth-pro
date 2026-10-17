import SwiftUI

struct LayerLegendView: View {
    let entries: [LayerLegendEntry]
    let notice: String?
    var body: some View {
        if !entries.isEmpty {
            DisclosureGroup("Legend · \(entries.count) \(entries.count == 1 ? "style" : "styles")") {
                VStack(alignment: .leading, spacing: 5) {
                    if let notice { Text(notice).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 7) {
                            Group {
                                if entry.style.symbolKind == .path {
                                    Rectangle().fill(Color(nsColor:NSColor(earthHex:entry.style.stroke)).opacity(entry.style.strokeOpacity))
                                        .frame(height:max(1,min(5,entry.style.width)))
                                } else if entry.style.symbolKind == .point {
                                    Circle().fill(Color(nsColor:NSColor(earthHex:entry.style.fill)).opacity(entry.style.fillOpacity))
                                        .overlay(Circle().stroke(Color(nsColor:NSColor(earthHex:entry.style.stroke)).opacity(entry.style.strokeOpacity),lineWidth:min(2,entry.style.width))).padding(.horizontal,3)
                                } else {
                                    RoundedRectangle(cornerRadius:2)
                                        .fill(Color(nsColor:NSColor(earthHex:entry.style.fill)).opacity(entry.style.fillOpacity))
                                        .overlay(RoundedRectangle(cornerRadius:2).stroke(Color(nsColor:NSColor(earthHex:entry.style.stroke)).opacity(entry.style.strokeOpacity),lineWidth:min(2,entry.style.width)))
                                }
                            }.frame(width:18,height:12)
                            Text(entry.label).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }.accessibilityElement(children: .combine)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.font(.caption)
        } else if let notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
    }
}
