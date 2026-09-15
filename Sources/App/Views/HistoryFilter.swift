import SwiftUI

/// Direction filter shared by the moment library and the status history.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case received
    case sent

    var id: String { rawValue }

    func label(partnerName: String) -> String {
        switch self {
        case .all: return String(localized: "All")
        case .received: return String(localized: "From \(partnerName)")
        case .sent: return String(localized: "From me")
        }
    }

    func allows(fromMe: Bool) -> Bool {
        switch self {
        case .all: return true
        case .received: return !fromMe
        case .sent: return fromMe
        }
    }
}

/// The library's second axis: what kind of moment. Combines with the
/// direction tabs rather than replacing them.
enum MomentKindFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case drawings
    case voice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "All types")
        case .photos: return String(localized: "Photos")
        case .drawings: return String(localized: "Drawings")
        case .voice: return String(localized: "Voice memos")
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .photos: return "camera.fill"
        case .drawings: return "scribble"
        case .voice: return "waveform"
        }
    }

    func allows(_ kind: Moment.Kind) -> Bool {
        switch self {
        case .all: return true
        case .photos: return kind == .photo
        case .drawings: return kind == .drawing
        case .voice: return kind == .voice
        }
    }
}

/// The segmented control for a `HistoryFilter`.
struct HistoryFilterPicker: View {
    @Binding var filter: HistoryFilter
    let partnerName: String

    var body: some View {
        Picker("Filter", selection: $filter) {
            ForEach(HistoryFilter.allCases) { choice in
                Text(choice.label(partnerName: partnerName)).tag(choice)
            }
        }
        .pickerStyle(.segmented)
    }
}
