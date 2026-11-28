import SwiftUI

/// What's waiting to send, from the offline card or the footer's "waiting"
/// pill — and "Don't send" for a moment sent by mistake (`AppModel.cancelSend`).
struct PendingSendsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cancelling: Moment?

    var body: some View {
        let pending = model.pendingSends
        NavigationStack {
            List {
                Section {
                    if let status = pending.status {
                        HStack(spacing: 12) {
                            Text(status.emoji).font(.system(size: 30)).frame(width: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your status").font(Theme.rounded(16, .semibold))
                                if !status.message.isEmpty {
                                    Text(status.message).font(Theme.rounded(14)).foregroundStyle(Theme.mutedText)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(pending.moments) { item in
                        row(item)
                    }
                } header: {
                    Text(model.isOffline ? "Sends when you're back online" : "Waiting to send")
                } footer: {
                    if pending.others > 0 {
                        Text(pending.others == 1
                             ? "And 1 other change, like a caption edit or a delete."
                             : "And \(pending.others) other changes, like caption edits or deletes.")
                    }
                }
                if pending.isEmpty {
                    Label("Everything's sent", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.mutedText)
                }
            }
            .navigationTitle("Waiting to send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !model.isOffline, !pending.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Send now") { Task { await model.retryPendingNow() } }
                            .font(Theme.rounded(16, .semibold))
                    }
                }
            }
            .confirmationDialog(cancelling.map { String(localized: "Don't send this \($0.noun.lowercased())?") } ?? "",
                                isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                                titleVisibility: .visible, presenting: cancelling) { moment in
                Button("Don't send", role: .destructive) {
                    Task { await model.cancelSend(moment) }
                }
                Button("Keep it", role: .cancel) {}
            } message: { _ in
                Text("It's removed from this iPhone and won't reach \(model.partnerName).")
            }
        }
    }

    private func row(_ item: PendingSends.Item) -> some View {
        HStack(spacing: 12) {
            PendingThumbnail(moment: item.moment)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.moment.noun).font(Theme.rounded(16, .semibold))
                Text(item.moment.caption.isEmpty ? item.moment.sentAt.relativeWording()
                                                 : "\(item.moment.caption) · \(item.moment.sentAt.relativeWording())")
                    .font(Theme.rounded(14))
                    .foregroundStyle(Theme.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.sending {
                Text("Sending…").font(Theme.rounded(14)).foregroundStyle(Theme.mutedText)
            } else {
                Button("Don't send", role: .destructive) { cancelling = item.moment }
                    .buttonStyle(.borderless)
                    .font(Theme.rounded(14, .semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The moment's own file — it's still only here — or its kind's symbol.
private struct PendingThumbnail: View {
    let moment: Moment
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: moment.symbolName).foregroundStyle(Theme.mutedText)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            .task(id: moment.id) {
                guard moment.isPicture else { return }
                image = await MomentStore.shared.gridThumbnail(for: moment.id, maxPixel: 44 * displayScale)
            }
    }
}
