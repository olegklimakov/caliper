import CaliperHistory
import Observation
import SwiftUI

/// Loads a span of history for the metrics on screen and keeps the result for
/// the charts to draw.
///
/// Reloads on a timer while the window is open rather than on every tick: a
/// year-wide chart does not change meaningfully in a second, and re-querying
/// the store at 1 Hz would undo the point of batching writes.
///
/// One loader for however many series are being shown, not one apiece. The
/// overview's whole claim is that its charts show the same moment; several
/// refresh tasks on their own clocks would quietly break it.
@MainActor
@Observable
final class DashboardHistory {
    enum State: Equatable {
        case loading
        /// The store works and has nothing for this span yet — a fresh install
        /// has no past, which is not a failure.
        case empty
        case loaded(HistorySlice)
        /// The store could not be opened or read. Worth saying, because "no
        /// data" and "cannot read the data" call for different reactions.
        case unavailable
    }

    private(set) var state: State = .loading

    /// What was running over the bucket the cursor is on, or `nil` when the
    /// cursor is nowhere, no tier keeps that moment, or the answer has not come
    /// back yet.
    private(set) var consumers: ProcessBucket?

    private let reader: HistoryReader?
    /// What was last asked for, so it can be asked again when the store changes
    /// under the window rather than at the next tick of the refresh clock.
    private var request: (series: [MetricSeries], span: HistorySpan)?
    private var refresh: Task<Void, Never>?
    private var inspection: Task<Void, Never>?

    init(reader: HistoryReader?) {
        self.reader = reader
    }

    /// A loader that already holds its samples and has no store behind it.
    ///
    /// For the preview harness, which renders off-screen: `ImageRenderer` draws
    /// the view once and never waits for a query to come back.
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
            // A preloaded loader has nothing to refresh from and its samples
            // are already right; only a genuine absence of a store is a failure
            // to report.
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

                // A tenth of the span: an hour-wide chart moves every six
                // minutes, a year-wide one leaves the disk alone. Never faster
                // than the ten-second tier can change.
                let interval = max(10, span.seconds / 10)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Reads what was running over the bucket holding `moment`.
    ///
    /// A query per settled cursor, not per span: one bucket is at most twenty
    /// rows found by primary key, where the span the charts draw is tens of
    /// thousands. The one in flight is cancelled when the cursor moves on, so a
    /// drag leaves at most one query outstanding.
    ///
    /// The retention and whether anything is being recorded come with the call
    /// rather than being held from when the loader was made: they are settings,
    /// and a window left open across a change to either would keep asking the
    /// old question.
    func inspect(_ moment: Date?, retention: ProcessRetention, isRecording: Bool) {
        inspection?.cancel()
        // A preloaded loader has nothing to read from and its bucket is already
        // right — the same reason `load` leaves one alone. Clearing it here is
        // what made the preview render the pane without its list.
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

    /// Asks again for whatever is on screen.
    ///
    /// For the moment the store is emptied under an open window: the refresh
    /// clock is a tenth of the span, which is eight minutes on the year view,
    /// and until then the charts would be drawing rows that no longer exist.
    func reload() {
        guard let request else { return }
        // The lookup in flight has to go as well: it was issued before the
        // store changed and would put a stale list of processes back after the
        // reload had cleared it.
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
