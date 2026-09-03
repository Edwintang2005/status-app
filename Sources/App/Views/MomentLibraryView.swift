import SwiftUI

/// The full archive, as a grid, behind its own button — the home card is for
/// what's waiting, not for browsing.
struct MomentLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var opened: Moment?
    @State private var filter: HistoryFilter = .all
    @State private var reporting: Moment?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    private var filtered: [Moment] {
        model.history.filter { filter.allows(fromMe: $0.fromMe) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()

                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text(filter == .all
                             ? "Anything you send each other shows up here."
                             : "Nothing in this direction yet.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(filtered) { moment in
                                cell(moment)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                HistoryFilterPicker(filter: $filter, partnerName: model.partnerName)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .sheet(item: $opened) { moment in
                // The filtered list, so paging stays within what was on screen.
                MomentGalleryView(moments: filtered, startAt: moment)
                    .environment(model)
            }
            .confirmationDialog("Report this \(reporting?.noun ?? "moment")?",
                                isPresented: Binding(get: { reporting != nil },
                                                     set: { if !$0 { reporting = nil } }),
                                titleVisibility: .visible) {
                Button("Report", role: .destructive) {
                    if let reporting { model.report(reporting) }
                    reporting = nil
                }
                Button("Cancel", role: .cancel) { reporting = nil }
            } message: {
                Text("It's removed from this iPhone straight away, and the details go to us by email. We act on reports within 24 hours.")
            }
        }
    }

    private var title: String {
        let count = filtered.count
        return count == 0 ? "History" : "History · \(count)"
    }

    private func cell(_ moment: Moment) -> some View {
        Button {
            opened = moment
        } label: {
            ZStack(alignment: .topTrailing) {
                SquareFill { thumbnail(moment) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if !moment.seen && !moment.fromMe {
                    Circle()
                        .fill(Theme.warm)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if moment.fromMe {
                    // Un-uploaded sends wear a clock (cleared by retryPendingUploads);
                    // seen-by-partner (read receipts on, both sides) wears an eye.
                    Image(systemName: sentBadgeSymbol(moment))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(moment.uploaded ? AnyShapeStyle(.black.opacity(0.35))
                                                    : AnyShapeStyle(Theme.warm),
                                    in: Circle())
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: moment))
        .accessibilityHint("Opens it")
        .contextMenu {
            if !moment.fromMe {
                Button(role: .destructive) {
                    reporting = moment
                } label: {
                    Label("Report…", systemImage: "flag")
                }
            }
        }
    }

    /// Kind, sender, age, and whichever badge the tile is wearing.
    private func accessibilityLabel(for moment: Moment) -> String {
        let sender = moment.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = moment.fromMe
            ? String(localized: "you")
            : (sender.isEmpty ? model.partnerName : sender)
        var parts = [String(localized: "\(moment.noun) from \(who)"),
                     moment.sentAt.formatted(.relative(presentation: .named))]
        if !moment.seen && !moment.fromMe { parts.append(String(localized: "new")) }
        if moment.fromMe {
            if !moment.uploaded {
                parts.append(String(localized: "waiting to send"))
            } else if model.readReceiptsEnabled, moment.seenByPartnerAt != nil {
                parts.append(String(localized: "seen"))
            }
        }
        return parts.joined(separator: ", ")
    }

    private func sentBadgeSymbol(_ moment: Moment) -> String {
        guard moment.uploaded else { return "clock.fill" }
        if model.readReceiptsEnabled, moment.seenByPartnerAt != nil { return "eye.fill" }
        return "arrow.up.right"
    }

    /// Entries past the media cache window are fetched on demand when opened,
    /// never eagerly. Voice tiles draw from the indexed waveform, so they render without audio.
    @ViewBuilder
    private func thumbnail(_ moment: Moment) -> some View {
        if moment.isVoice {
            VoiceMomentTile(moment: moment)
        } else if let image = MomentStore.shared.thumbnail(for: moment.id) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .overlay {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
        }
    }
}

#if DEBUG
#Preview("Library") {
    MomentLibraryView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
