import CaliperHistory
import SwiftUI

/// Every name the machine has run, searched — the ones not running now
/// included.
///
/// The registry's only reader, and the reason it is written at all: a top-N
/// tier is structurally blind to a program that is deliberately cheap, because
/// being cheap is how it never ranks. "What was that thing called that ate the
/// battery on Tuesday" is asked afterwards, of a name that may no longer exist
/// on the machine, and no ranking can answer it.
struct ProcessesPane: View {
    let history: HistoryReader?
    /// Says how far back the answers go, which a search with no hits has to
    /// state: "not found" and "aged out on Sunday" are different answers.
    let processRetention: ProcessRetention
    let recordsProcesses: Bool
    /// A row opens its process's card. The registry keys on the name alone, so
    /// most of what it holds opens on a process that no longer runs — which is
    /// the point.
    let openCard: (ProcessCardTarget) -> Void

    @State private var query = ""
    @State private var found: ProcessNameSearch?

    /// Handed in by the preview harness, which renders off-screen and can
    /// neither run a query nor type into a field.
    private let preloaded: ProcessNameSearch?

    init(
        history: HistoryReader?,
        processRetention: ProcessRetention,
        recordsProcesses: Bool,
        openCard: @escaping (ProcessCardTarget) -> Void
    ) {
        self.history = history
        self.processRetention = processRetention
        self.recordsProcesses = recordsProcesses
        self.openCard = openCard
        preloaded = nil
    }

    init(preloaded: ProcessNameSearch, query: String = "") {
        history = nil
        processRetention = .twoWeeks
        recordsProcesses = true
        openCard = { _ in }
        self.preloaded = preloaded
        _query = State(initialValue: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Processes")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(countLine)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            searchField

            results

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 560, alignment: .topLeading)
        // Keyed on the query, so a keystroke cancels the query before it and
        // the store is asked once for a word rather than once a letter.
        .task(id: query) {
            guard let history else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            found = try? await history.searchProcessNames(matching: query)
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) { _ in
            // The delete button empties the registry too, and a list still
            // showing what was deleted is the one thing that button must not
            // leave behind.
            found = nil
            Task { found = try? await history?.searchProcessNames(matching: query) }
        }
    }

    private var active: ProcessNameSearch? { found ?? preloaded }

    /// The size of the record, which is what tells "no such name" from
    /// "nothing recorded yet" — and the sentence the whole room is justified
    /// by: six hundred names, against the twenty a bucket ranks.
    private var countLine: String {
        guard let active else { return " " }
        guard active.matched < active.recorded else {
            return "\(active.recorded) names · kept for \(processRetention.label)"
        }
        return "\(active.matched) of \(active.recorded) names"
    }

    // MARK: - The field

    /// A field of our own rather than `.searchable`, whose box the window draws
    /// in a toolbar this window does not have.
    ///
    /// A `TextField` is AppKit underneath and `ImageRenderer` draws those as a
    /// placeholder, so the harness is handed the query as plain text instead.
    /// What that leaves unchecked is a stock control; the chrome around it, and
    /// everything under it, is ours and is drawn the same either way.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            if preloaded == nil {
                TextField("Search recorded names and paths", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            } else {
                Text(query.isEmpty ? "Search recorded names and paths" : query)
                    .font(.system(size: 13))
                    .foregroundStyle(query.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - The results

    @ViewBuilder
    private var results: some View {
        if !recordsProcesses {
            note(
                "Process history is switched off",
                "Nothing is being recorded, so there is nothing to search. Settings turns it on."
            )
        } else if let active {
            if active.matches.isEmpty {
                emptyResult(active)
            } else {
                list(active)
            }
        } else {
            note("Loading…", "")
        }
    }

    @ViewBuilder
    private func emptyResult(_ search: ProcessNameSearch) -> some View {
        if search.recorded == 0 {
            note("No names recorded yet", "The registry is written every ten minutes.")
        } else {
            note(
                "Nothing recorded matches “\(query)”",
                // Not "no such process": the registry only ever held what the
                // retention keeps, and a name that ran last month is gone
                // rather than absent.
                "\(search.recorded) names are recorded, going back \(processRetention.label)."
            )
        }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func list(_ search: ProcessNameSearch) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            scrolling {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.matches, id: \.name) { appearance in
                        row(appearance)
                        Divider().opacity(0.4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if search.matches.count < search.matched {
                Text(
                    "Showing the \(search.matches.count) most recently seen of \(search.matched) — narrow the search."
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            }
        }
    }

    /// `ImageRenderer` draws a `ScrollView` blank — the same blind spot that
    /// keeps the overview's charts out of one — so the harness is given the
    /// rows laid out straight. A stock container goes unchecked; the rows in it
    /// are what the picture exists to check.
    @ViewBuilder
    private func scrolling(@ViewBuilder _ rows: () -> some View) -> some View {
        if preloaded == nil {
            ScrollView { rows() }
        } else {
            rows()
        }
    }

    private func row(_ appearance: ProcessAppearance) -> some View {
        Button {
            openCard(.name(appearance.name))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appearance.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // The path where there is one, and a plain statement where
                    // there is not: an unreadable path is another user's
                    // process, not a missing field.
                    Text(appearance.path ?? "path not readable")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    // Labelled, both of them: two bare dates one above the
                    // other are two dates, and which is which is the whole
                    // answer to "it appeared on Tuesday and never since".
                    Text("last \(RegistryDate.moment(appearance.lastSeen))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                    Text("first \(RegistryDate.day(appearance.firstSeen))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text("\u{203A}")
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(
            "\(appearance.name), last seen \(RegistryDate.moment(appearance.lastSeen)),"
                + " first seen \(RegistryDate.day(appearance.firstSeen))"
        )
    }
}

/// When a name was seen, as a list of hundreds of them can be read down.
///
/// Widths that narrow with age rather than "5 minutes ago": the registry is
/// written every ten minutes, so a relative time to the minute would claim a
/// precision the record does not have.
enum RegistryDate {
    /// Last seen, where the time of day is the answer — "it was running an
    /// hour ago" and "it was running at four this morning" are different
    /// facts.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if now.timeIntervalSince(date) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// First seen, where only the day is: what anyone wants from it is "this
    /// arrived on Tuesday", and a minute of precision on that is noise.
    static func day(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "today"
        }
        if now.timeIntervalSince(date) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
