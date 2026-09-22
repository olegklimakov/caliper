import AppKit
import CaliperHistory
import SwiftUI

/// Takes a moment out of the window.
///
/// Four files in one folder: one place for the user to choose, and what a bug
/// report wants — the series as numbers, what was running around the moment, the
/// picture that shows why the moment was worth picking, and a note saying what
/// each of them covers.
@MainActor
enum IncidentExporter {
    enum Failure: Error {
        case couldNotRender
        case couldNotWrite(any Error)
    }

    /// Asks where, then writes. `nil` when the user cancelled.
    ///
    /// The panel comes first on purpose: a cancelled export reads nothing out of
    /// the store and renders nothing.
    static func export(
        cursor: Date,
        span: HistorySpan,
        loader: DashboardHistory,
        metrics: LiveMetrics,
        history: HistoryReader?,
        retention: ProcessRetention,
        appearance: NSAppearance
    ) async throws -> URL? {
        guard let folder = await destination(for: cursor) else { return nil }
        // Read after the panel, not before it: a modal sheet can stand open for
        // minutes, and `historyDidChange` reloads the loader underneath it. The
        // picture is drawn from the same loader on the same turn of the main
        // actor, so the numbers and the picture cannot be two different reads.
        guard let slice = loader.slice else { throw Failure.couldNotRender }

        let window = IncidentExport.window(around: cursor)
        let buckets = try await history?.consumers(
            from: window.start,
            to: window.end,
            retention: retention
        )

        guard
            let image = PanelPreview.renderOverview(
                metrics: metrics,
                history: loader,
                span: span,
                cursor: cursor,
                appearance: appearance,
                scale: 2,
                showsControls: false
            ),
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { throw Failure.couldNotRender }

        do {
            // Not a delete and recreate, though the panel's own word is
            // "replace": the user may have aimed at a folder that holds other
            // things, and four known filenames overwriting four is a smaller
            // promise to keep than a directory this app removed.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(IncidentExport.series(slice), "series.csv", into: folder)
            try write(IncidentExport.processes(buckets ?? []), "processes.csv", into: folder)
            try write(
                IncidentExport.notes(
                    cursor: cursor,
                    span: span,
                    slice: slice,
                    window: window,
                    buckets: buckets,
                    retention: retention
                ),
                "notes.txt",
                into: folder
            )
            try png.write(to: folder.appendingPathComponent("overview.png"))
        } catch {
            throw Failure.couldNotWrite(error)
        }

        return folder
    }

    private static func write(_ text: String, _ name: String, into folder: URL) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    /// The save panel. A folder rather than a file: four files from one choice
    /// written as siblings would be three the user never named.
    private static func destination(for cursor: Date) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = IncidentExport.folderName(for: cursor)
        panel.nameFieldLabel = "Folder:"
        panel.prompt = "Export"
        panel.message =
            "Caliper writes the charted series, what was running, and a picture of the pane into this folder."
        panel.canCreateDirectories = true

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        return response == .OK ? panel.url : nil
    }
}

extension IncidentExporter.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .couldNotRender:
            "Caliper could not draw the overview."
        case .couldNotWrite(let error):
            error.localizedDescription
        }
    }
}
