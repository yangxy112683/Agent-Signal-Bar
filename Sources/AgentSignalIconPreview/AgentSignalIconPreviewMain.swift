import AgentSignalLightCore
import AgentSignalLightUI
import AppKit
import Foundation

@MainActor
@main
struct AgentSignalIconPreview {
    static func main() throws {
        let outputURL = try parseOutputURL()
        let iconsURL = outputURL.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsURL, withIntermediateDirectories: true)

        let records = try renderIcons(to: iconsURL)
        try renderSheet(records: records, to: outputURL.appendingPathComponent("status-icon-preview.png"))
        try writeManifest(records: records, to: outputURL.appendingPathComponent("manifest.json"))

        print("status icon preview: \(outputURL.path)")
        print("sheet: \(outputURL.appendingPathComponent("status-icon-preview.png").path)")
        print("manifest: \(outputURL.appendingPathComponent("manifest.json").path)")
    }

    private static func parseOutputURL() throws -> URL {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            return URL(fileURLWithPath: "dist/status-icon-preview", isDirectory: true)
        }

        if args.count == 1 {
            return URL(fileURLWithPath: args[0], isDirectory: true)
        }

        if args.count == 2, args[0] == "--output" {
            return URL(fileURLWithPath: args[1], isDirectory: true)
        }

        throw PreviewError.usage
    }

    private static func renderIcons(to iconsURL: URL) throws -> [PreviewRecord] {
        var records: [PreviewRecord] = []
        for style in TrafficSignalStyle.allCases {
            for layout in TrafficSignalLayout.allCases {
                for item in previewItems {
                    let snapshot = SignalSnapshot(
                        aggregate: item.signal,
                        sessions: [],
                        stateFileURL: URL(fileURLWithPath: "/tmp/agent-signal/status.json")
                    )
                    let image = StatusBarIconRenderer.image(
                        snapshot: snapshot,
                        tick: item.tick,
                        layout: layout,
                        style: style,
                        macOSBreathingStrength: .maximum,
                        allLightsOn: item.allLightsOn
                    )
                    let filename = [
                        style.rawValue,
                        layout.rawValue,
                        item.identifier
                    ].joined(separator: "-") + ".png"
                    let fileURL = iconsURL.appendingPathComponent(filename)
                    try writePNG(image, to: fileURL)
                    records.append(
                        PreviewRecord(
                            style: style,
                            layout: layout,
                            item: item,
                            fileURL: fileURL,
                            imageSize: image.size
                        )
                    )
                }
            }
        }
        return records
    }

    private static func renderSheet(records: [PreviewRecord], to outputURL: URL) throws {
        let columns: [(TrafficSignalStyle, TrafficSignalLayout)] = TrafficSignalStyle.allCases.flatMap { style in
            TrafficSignalLayout.allCases.map { layout in (style, layout) }
        }
        let rowHeight: CGFloat = 88
        let labelWidth: CGFloat = 132
        let columnWidth: CGFloat = 178
        let headerHeight: CGFloat = 58
        let padding: CGFloat = 18
        let sheetSize = NSSize(
            width: labelWidth + CGFloat(columns.count) * columnWidth + padding * 2,
            height: headerHeight + CGFloat(previewItems.count) * rowHeight + padding * 2
        )
        let sheet = try makeBitmap(size: sheetSize, path: outputURL.path)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.14, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheetSize).fill()

        drawText(
            "Agent Signal Bar status bar preview",
            in: NSRect(x: padding, y: sheetSize.height - padding - 24, width: sheetSize.width - padding * 2, height: 22),
            font: .boldSystemFont(ofSize: 15),
            color: .white
        )

        for (columnIndex, column) in columns.enumerated() {
            let x = padding + labelWidth + CGFloat(columnIndex) * columnWidth
            let title = "\(column.0.displayName) / \(column.1.displayName)"
            drawText(
                title,
                in: NSRect(x: x, y: sheetSize.height - padding - 52, width: columnWidth - 12, height: 20),
                font: .systemFont(ofSize: 11, weight: .semibold),
                color: NSColor.white.withAlphaComponent(0.82)
            )
        }

        for (rowIndex, item) in previewItems.enumerated() {
            let rowY = sheetSize.height - padding - headerHeight - CGFloat(rowIndex + 1) * rowHeight
            let rowRect = NSRect(
                x: padding,
                y: rowY + 8,
                width: sheetSize.width - padding * 2,
                height: rowHeight - 12
            )
            NSColor.white.withAlphaComponent(rowIndex.isMultiple(of: 2) ? 0.035 : 0.018).setFill()
            NSBezierPath(roundedRect: rowRect, xRadius: 8, yRadius: 8).fill()

            drawText(
                item.label,
                in: NSRect(x: padding + 12, y: rowY + rowHeight / 2 - 2, width: labelWidth - 20, height: 18),
                font: .systemFont(ofSize: 12, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.88)
            )
            drawText(
                "tick \(item.tick)",
                in: NSRect(x: padding + 12, y: rowY + rowHeight / 2 - 22, width: labelWidth - 20, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.45)
            )

            for (columnIndex, column) in columns.enumerated() {
                guard let record = records.first(where: {
                    $0.style == column.0 && $0.layout == column.1 && $0.item.identifier == item.identifier
                }) else {
                    continue
                }

                let x = padding + labelWidth + CGFloat(columnIndex) * columnWidth
                let iconBackground = NSRect(x: x + 18, y: rowY + 22, width: columnWidth - 48, height: 34)
                NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.36, alpha: 1).setFill()
                NSBezierPath(roundedRect: iconBackground, xRadius: 7, yRadius: 7).fill()

                let image = try loadImage(record.fileURL)
                let scale: CGFloat = column.0 == .trafficLight ? 3 : 4
                let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                let drawRect = NSRect(
                    x: iconBackground.midX - drawSize.width / 2,
                    y: iconBackground.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
                NSGraphicsContext.current?.imageInterpolation = .none
                image.draw(in: drawRect)
            }
        }

        try writePNG(sheet, to: outputURL)
    }

    private static func writeManifest(records: [PreviewRecord], to outputURL: URL) throws {
        let formatter = ISO8601DateFormatter()
        let manifest = PreviewManifest(
            generatedAt: formatter.string(from: Date()),
            description: "Status bar icon previews generated from StatusBarIconRenderer.",
            records: records.map { record in
                PreviewManifest.Record(
                    style: record.style.rawValue,
                    layout: record.layout.rawValue,
                    state: record.item.identifier,
                    signal: record.item.signal.rawValue,
                    displayState: record.item.signal.displayState.rawValue,
                    tick: record.item.tick,
                    allLightsOn: record.item.allLightsOn,
                    width: Int(record.imageSize.width),
                    height: Int(record.imageSize.height),
                    path: "icons/\(record.fileURL.lastPathComponent)"
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: outputURL)
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        let rep = try makeBitmap(size: image.size, path: url.path)
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PreviewError.missingPNGRepresentation(url.path)
        }
        try png.write(to: url)
    }

    private static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PreviewError.missingPNGRepresentation(url.path)
        }
        try png.write(to: url)
    }

    private static func makeBitmap(size: NSSize, path: String) throws -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)),
            pixelsHigh: Int(ceil(size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw PreviewError.missingPNGRepresentation(path)
        }
        rep.size = size
        return rep
    }

    private static func loadImage(_ url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url) else {
            throw PreviewError.missingImage(url.path)
        }
        return image
    }

    private static func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}

private struct PreviewItem: Sendable {
    let identifier: String
    let label: String
    let signal: AgentSignal
    let tick: Int
    let allLightsOn: Bool
}

private let previewItems: [PreviewItem] = [
    PreviewItem(identifier: "idle", label: "Idle", signal: .idle, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "working-low", label: "Working low", signal: .working, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "working-mid", label: "Working mid", signal: .working, tick: 2, allLightsOn: false),
    PreviewItem(identifier: "working-high", label: "Working high", signal: .working, tick: 5, allLightsOn: false),
    PreviewItem(identifier: "done", label: "Done", signal: .done, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "attention", label: "Attention", signal: .attention, tick: 2, allLightsOn: false),
    PreviewItem(identifier: "permission", label: "Permission", signal: .permission, tick: 2, allLightsOn: false),
    PreviewItem(identifier: "blocked-on", label: "Blocked on", signal: .blocked, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "blocked-off", label: "Blocked off", signal: .blocked, tick: 1, allLightsOn: false),
    PreviewItem(identifier: "stale", label: "Stale", signal: .stale, tick: 2, allLightsOn: false),
    PreviewItem(identifier: "off", label: "Off", signal: .off, tick: 0, allLightsOn: false),
    PreviewItem(identifier: "all-lights-on", label: "All lights on", signal: .idle, tick: 0, allLightsOn: true)
]

private struct PreviewRecord {
    let style: TrafficSignalStyle
    let layout: TrafficSignalLayout
    let item: PreviewItem
    let fileURL: URL
    let imageSize: NSSize
}

private struct PreviewManifest: Encodable {
    let generatedAt: String
    let description: String
    let records: [Record]

    struct Record: Encodable {
        let style: String
        let layout: String
        let state: String
        let signal: String
        let displayState: String
        let tick: Int
        let allLightsOn: Bool
        let width: Int
        let height: Int
        let path: String
    }
}

private enum PreviewError: Error, LocalizedError {
    case usage
    case missingPNGRepresentation(String)
    case missingImage(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: agent-signal-icon-preview [output-dir] or agent-signal-icon-preview --output <dir>"
        case .missingPNGRepresentation(let path):
            return "could not create PNG representation for \(path)"
        case .missingImage(let path):
            return "could not load preview image at \(path)"
        }
    }
}
