import SwiftUI

/// The full archive, as a grid, behind its own button — the home card is for
/// what's waiting, not for browsing.
struct MomentLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var opened: Moment?
    @State private var filter: HistoryFilter = .all

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
