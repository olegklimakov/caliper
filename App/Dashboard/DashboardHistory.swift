import CaliperHistory
import Observation
import SwiftUI

/// Loads a span of history for the metrics on screen and keeps the result for
/// the charts to draw.
///
/// On a timer rather than every tick: a year-wide chart does not change in a
/// second, and re-querying at 1 Hz would undo the point of batching writes. One
/// loader for however many series are shown, or the overview's claim that its
/// charts show the same moment quietly breaks.
@MainActor
@Observable
final class DashboardHistory {
    enum State: Equatable {
        case loading
        /// The store works and has nothing for this span yet.
        case empty
        case loaded(HistorySlice)
        /// Distinct from `empty`: "no data" and "cannot read the data" call for
        /// different reactions.
        case unavailable
    }

    private(set) var state: State = .loading

    /// `nil` when the cursor is nowhere, no tier keeps that moment, or the
    /// answer has not come back.
    private(set) var consumers: ProcessBucket?

    private let reader: HistoryReader?
    /// So it can be asked again when the store changes under the window, rather
    /// than at the next tick of the refresh clock.
    private var request: (series: [MetricSeries], span: HistorySpan)?
    private var refresh: Task<Void, Never>?
    private var inspection: Task<Void, Never>?

    init(reader: HistoryReader?) {
        self.reader = reader
    }

    /// For the preview harness: `ImageRenderer` draws the view once and never
    /// waits for a query.
    init(preloaded slice: HistorySlice, consumers: ProcessBucket? = nil) {
        reader = nil
        state = .loaded(slice)
        self.consumers = consumers
    }

    var slice: HistorySlice? {
        if case .loaded(let slice) = state { return slice }
        return nil
    }

    func load(_ series: [MetricSeries], span: HistorySpan) {
        request = (series, span)
        refresh?.cancel()
        guard let reader else {
            // A preloaded loader's samples are already right; only a genuine
            // absence of a store is a failure.
            if case .loaded = state { return }
            state = .unavailable
            return
        }
        if slice == nil {
            state = .loading
        }

        refresh = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let loaded = try await reader.slice(series, span: span.seconds)
                    guard let self, !Task.isCancelled else { return }
                    state = loaded.isEmpty ? .empty : .loaded(loaded)
                } catch {
                    guard let self else { return }
                    state = .unavailable
                }

                // A tenth of the span, floored at the ten-second tier: an hour
                // moves every six minutes, a year leaves the disk alone.
                let interval = max(10, span.seconds / 10)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Reads what was running over the bucket holding `moment`.
    ///
    /// A query per settled cursor: one bucket is twenty rows by primary key,
    /// where the charted span is tens of thousands. The one in flight is
    /// cancelled when the cursor moves on.
    ///
    /// Retention and whether anything is recording come with the call rather
    /// than being held from when the loader was made — they are settings.
    func inspect(_ moment: Date?, retention: ProcessRetention, isRecording: Bool) {
        inspection?.cancel()
        // As in `load`: a preloaded loader's bucket is already right, and
        // clearing it renders the pane without its list.
        guard let reader else { return }
        guard let moment else {
            consumers = nil
            return
        }
        inspection = Task { [weak self] in
            let bucket = try? await reader.consumers(at: moment, retention: retention, isRecording: isRecording)
            guard let self, !Task.isCancelled else { return }
            consumers = bucket
        }
    }

    /// For the store being emptied under an open window: the refresh clock is
    /// eight minutes on the year view, and until then the charts draw rows that
    /// no longer exist.
    func reload() {
        guard let request else { return }
        // The lookup in flight was issued before the store changed and would
        // put a stale list back after the reload cleared it.
        inspection?.cancel()
        consumers = nil
        load(request.series, span: request.span)
    }

    func stop() {
        refresh?.cancel()
        refresh = nil
        inspection?.cancel()
        inspection = nil
    }
}
