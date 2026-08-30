import SwiftUI

/// Direction filter shared by the moment library and the status history.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case received
    case sent

    var id: String { rawValue }

    func label(partnerName: String) -> String {
        switch self {
        case .all: return "All"
        case .received: return "From \(partnerName)"
        case .sent: return "From me"
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
