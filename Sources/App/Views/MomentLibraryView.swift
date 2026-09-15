import SwiftUI

/// The full archive, as a grid, behind its own button — the home card is for
/// what's waiting, not for browsing.
struct MomentLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var opened: Moment?
    @State private var filter: HistoryFilter = .all
    @State private var kind: MomentKindFilter = .all
    @State private var reporting: Moment?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    private var filtered: [Moment] {
        model.history.filter { filter.allows(fromMe: $0.fromMe) && kind.allows($0.kind) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()

                // A plain stack, not `.safeAreaInset(edge: .top)` — see `StatusHistoryView`.
                VStack(spacing: 0) {
                    HistoryFilterPicker(filter: $filter, partnerName: model.partnerName)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    if filtered.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing here yet", systemImage: "photo.on.rectangle.angled")
                        } description: {
                            Text(filter == .all && kind == .all
                                 ? "Anything you send each other shows up here."
                                 : "Nothing matches these filters yet.")
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
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Type", selection: $kind) {
                            ForEach(MomentKindFilter.allCases) { choice in
                                Label(choice.label, systemImage: choice.symbolName).tag(choice)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: kind == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter by type")
                    .accessibilityValue(kind.label)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
        return count == 0 ? String(localized: "History") : String(localized: "History · \(count)")
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
                                                    : AnyShapeStyle(Theme.warmDeep),
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
        let who = moment.fromMe
            ? String(localized: "you")
            : moment.displaySenderName(fallback: model.partnerName)
        var parts = [String(localized: "\(moment.noun) from \(who)"),
                     moment.sentAt.relativeWording()]
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

    /// Voice tiles draw from the indexed waveform, so they render without audio.
    @ViewBuilder
    private func thumbnail(_ moment: Moment) -> some View {
        if moment.isVoice {
            VoiceMomentTile(moment: moment)
        } else {
            LibraryThumbnail(moment: moment)
        }
    }
}

/// A photo or drawing tile. Past the media cache window the thumbnail is
/// fetched as the tile scrolls into view — the grid is lazy, so only what's on
/// screen is asked for, and scrolling away cancels the task.
private struct LibraryThumbnail: View {
    @Environment(AppModel.self) private var model
    let moment: Moment

    @State private var image: UIImage?
    @State private var unavailable = false

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .overlay {
                    if unavailable {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .task(id: moment.id) {
                    image = MomentStore.shared.thumbnail(for: moment.id)
                    guard image == nil else { return }
                    let fetched = await model.ensureThumbnail(for: moment)
                    guard !Task.isCancelled else { return }
                    image = MomentStore.shared.thumbnail(for: moment.id)
                    unavailable = !fetched && image == nil
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
