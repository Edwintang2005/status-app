import SwiftUI

/// The full archive, as a grid, behind its own button — the home card is for
/// what's waiting, not for browsing.
struct MomentLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var opened: Moment?
    /// Failed tiles and their retry count — held here, not in the tile, so the
    /// cell can offer Retry to VoiceOver (it reads the cell as one element).
    @State private var failedTiles: Set<String> = []
    @State private var retries: [String: Int] = [:]
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
                        .zIndex(1)

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
                        .topBarBacking()
                    }
                }
                .topBarBackingCeiling()
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
                        // Says its choice, rather than a bare glyph that read as a
                        // menu button. Not a Label: the toolbar would drop its title.
                        HStack(spacing: 5) {
                            Image(systemName: "line.3.horizontal.decrease")
                            Text(kind.label)
                        }
                        .font(Theme.rounded(15, .semibold))
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
        return count == 0 ? String(localized: "Moments") : String(localized: "Moments · \(count)")
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
                        .fill(Theme.warmDeep)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // Un-uploaded sends wear a clock (cleared by `Outbox.retryPendingUploads`);
                // seen-by-partner (read receipts on, both sides) wears an eye. A
                // plain sent tile wears nothing: sent is every own tile's normal state.
                if moment.fromMe, let symbol = sentBadgeSymbol(moment) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
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
        .contextMenu { reportAction(moment) }
        // Guideline 1.2: reachable under VoiceOver and Voice Control, not only by long-press.
        .accessibilityActions {
            if failedTiles.contains(moment.id) {
                Button("Retry") { retry(moment) }
            }
            reportAction(moment)
        }
    }

    @ViewBuilder
    private func reportAction(_ moment: Moment) -> some View {
        if !moment.fromMe {
            Button(role: .destructive) {
                reporting = moment
            } label: {
                Label("Report…", systemImage: "flag")
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

    private func sentBadgeSymbol(_ moment: Moment) -> String? {
        guard moment.uploaded else { return "clock.fill" }
        if model.readReceiptsEnabled, moment.seenByPartnerAt != nil { return "eye.fill" }
        return nil
    }

    /// Voice tiles draw from the indexed waveform, so they render without audio.
    @ViewBuilder
    private func thumbnail(_ moment: Moment) -> some View {
        if moment.isVoice {
            VoiceMomentTile(moment: moment)
        } else {
            LibraryThumbnail(moment: moment,
                             attempt: retries[moment.id, default: 0],
                             unavailable: Binding(get: { failedTiles.contains(moment.id) },
                                                  set: { failed in
                                                      if failed { failedTiles.insert(moment.id) } else { failedTiles.remove(moment.id) }
                                                  }),
                             retry: { retry(moment) })
        }
    }

    private func retry(_ moment: Moment) {
        retries[moment.id, default: 0] += 1
    }
}

/// A photo or drawing tile. Past the media cache window the thumbnail is
/// fetched as the tile scrolls into view — the grid is lazy, so only what's on
/// screen is asked for, batched with its neighbours (`ThumbnailFetcher`), and
/// scrolling away withdraws it. Decoded off the main thread at tile size.
private struct LibraryThumbnail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let moment: Moment
    /// Bumped by a retry; the load re-runs on it.
    let attempt: Int
    @Binding var unavailable: Bool
    let retry: () -> Void

    @State private var image: UIImage?

    /// The grid's widest column, in pixels: no tile draws bigger.
    private var maxPixel: CGFloat { 140 * displayScale }

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .overlay {
                    if unavailable {
                        // Its own button over the tile's: retrying beats opening a blank page.
                        Button(action: retry) {
                            VStack(spacing: 4) {
                                Image(systemName: model.isOffline ? "wifi.slash" : "arrow.clockwise")
                                    .font(.system(size: 18))
                                Text("Retry")
                                    .font(Theme.rounded(11, .semibold))
                            }
                            .foregroundStyle(Theme.mutedText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Couldn't load. Retry")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                // Keyed on the connection too: a tile that missed offline tries again on reconnect.
                .task(id: "\(moment.id)-\(model.isOffline)-\(attempt)") { await load() }
        }
    }

    private func load() async {
        image = await MomentStore.shared.gridThumbnail(for: moment.id, maxPixel: maxPixel)
        guard image == nil, !Task.isCancelled else { return }
        // The spinner, not last pass's failure glyph, while this one runs.
        unavailable = false
        _ = await model.ensureThumbnail(for: moment)
        guard !Task.isCancelled else { return }
        image = await MomentStore.shared.gridThumbnail(for: moment.id, maxPixel: maxPixel)
        guard !Task.isCancelled else { return }
        unavailable = image == nil
    }
}

#if DEBUG
#Preview("Library") {
    MomentLibraryView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
