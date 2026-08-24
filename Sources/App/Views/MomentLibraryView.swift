import SwiftUI

/// The full archive, as a grid. Deliberately behind its own button: the home
/// card is for what's waiting, not for browsing everything you've ever been
/// sent.
struct MomentLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var opened: Moment?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()

                if model.history.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Anything you send each other shows up here.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(model.history) { moment in
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
            .sheet(item: $opened) { moment in
                MomentGalleryView(moments: model.history, startAt: moment)
                    .environment(model)
            }
        }
    }

    private var title: String {
        let count = model.history.count
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
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Entries older than the media cache window have no local file. They're
    /// fetched on demand when opened, not eagerly for the whole grid — that
    /// would defeat the point of the cache.
    ///
    /// A voice memo is the exception: its tile is drawn from the waveform in
    /// the index, so it looks right whether or not the audio is still here.
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
