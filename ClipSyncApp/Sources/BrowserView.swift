import AppKit
import ClipKit
import SwiftUI

struct BrowserView: View {
    let controller: SyncController
    @State private var model: LibraryModel
    @State private var selection = Set<PhotoLibrary.Photo.ID>()
    @State private var selectionAnchor: PhotoLibrary.Photo.ID?
    @State private var viewing: PhotoLibrary.Photo?
    @State private var errorMessage: String?
    @AppStorage("thumbnailSize") private var thumbnailSize = 180.0

    init(controller: SyncController) {
        self.controller = controller
        _model = State(initialValue: LibraryModel(root: controller.destination))
    }

    private var photos: [PhotoLibrary.Photo] { model.selectedDay?.photos ?? [] }
    private var selectedPhotos: [PhotoLibrary.Photo] { photos.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationSplitView {
            DayList(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            ZStack {
                if model.days.isEmpty && !model.isLoading {
                    ContentUnavailableView("No Photos Yet", systemImage: "camera",
                                           description: Text("Photos appear here after you connect your Narrative Clip."))
                } else {
                    grid
                }
                if let photo = viewing {
                    PhotoViewer(photos: photos, current: photo,
                                onClose: { viewing = nil },
                                onNavigate: { viewing = $0; selection = [$0.id] },
                                onDelete: deleteFromViewer)
                }
            }
        }
        .navigationTitle(model.selectedDay.map { DayList.title(for: $0) } ?? "Narrative Clip")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .alert("Couldn't Delete", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            model.reload()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .onChange(of: controller.libraryVersion) { model.reload() }
        .onChange(of: controller.destination) { model.setRoot(controller.destination) }
        .onChange(of: model.selectedDayID) {
            selection = []
            selectionAnchor = nil
            viewing = nil
        }
    }

    private var subtitle: String {
        guard let day = model.selectedDay else { return "" }
        return selection.isEmpty
            ? String(localized: "\(day.photos.count) photos")
            : String(localized: "\(selection.count) of \(day.photos.count) selected")
    }

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.6), spacing: 6)],
                          spacing: 6) {
                    ForEach(photos) { photo in
                        Thumbnail(photo: photo, size: thumbnailSize, isSelected: selection.contains(photo.id))
                            .id(photo.id)
                            .onTapGesture { click(photo) }
                            .contextMenu { contextMenu(for: photo) }
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand { deleteSelection() }
            .onKeyPress(.space) { openSelection() }
            .onKeyPress(.return) { openSelection() }
            .onChange(of: model.selectedDayID) { proxy.scrollTo(photos.first?.id, anchor: .top) }
        }
    }

    /// Finder-style selection: click selects one, ⌘-click toggles, ⇧-click extends;
    /// a double click opens the viewer.
    private func click(_ photo: PhotoLibrary.Photo) {
        let event = NSApp.currentEvent
        if event?.clickCount == 2 {
            selection = [photo.id]
            viewing = photo
            return
        }
        let flags = event?.modifierFlags ?? []
        if flags.contains(.command) {
            if selection.contains(photo.id) { selection.remove(photo.id) } else { selection.insert(photo.id) }
            selectionAnchor = photo.id
        } else if flags.contains(.shift), let anchor = selectionAnchor,
                  let a = photos.firstIndex(where: { $0.id == anchor }),
                  let b = photos.firstIndex(where: { $0.id == photo.id }) {
            selection = Set(photos[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [photo.id]
            selectionAnchor = photo.id
        }
    }

    private func openSelection() -> KeyPress.Result {
        guard viewing == nil, let first = selectedPhotos.first else { return .ignored }
        viewing = first
        return .handled
    }

    @ViewBuilder
    private func contextMenu(for photo: PhotoLibrary.Photo) -> some View {
        let targets = selection.contains(photo.id) ? selectedPhotos : [photo]
        Button("View") { selection = [photo.id]; viewing = photo }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url)) }
        Divider()
        let title: LocalizedStringKey = targets.count > 1 ? "Move \(targets.count) Photos to Trash" : "Move to Trash"
        Button(title, role: .destructive) {
            delete(targets)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Slider(value: $thumbnailSize, in: 100...360) {
                Text("Thumbnail Size")
            } minimumValueLabel: {
                Image(systemName: "square.grid.3x3").imageScale(.small)
            } maximumValueLabel: {
                Image(systemName: "square.grid.2x2").imageScale(.small)
            }
            .frame(width: 140)
            .padding(.horizontal, 8)   // keep the end icons off the toolbar capsule's rounded edge
            .help("Thumbnail Size")
        }
        ToolbarItem {
            Button("Move to Trash", systemImage: "trash") { deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selection.isEmpty)
                .help("Move the selected photos and their .json and .snap files to the Trash (⌘⌫)")
        }
    }

    // MARK: Deleting

    private func deleteSelection() {
        delete(selectedPhotos)
    }

    private func delete(_ targets: [PhotoLibrary.Photo]) {
        errorMessage = model.delete(targets)
        selection.subtract(targets.map(\.id))
    }

    /// Deletes the photo shown in the viewer and moves on to its neighbour.
    private func deleteFromViewer(_ photo: PhotoLibrary.Photo) {
        let index = photos.firstIndex(of: photo) ?? 0
        let remaining = photos.filter { $0 != photo }
        delete([photo])
        if remaining.isEmpty {
            viewing = nil
        } else {
            viewing = remaining[min(index, remaining.count - 1)]
            selection = [viewing!.id]
        }
    }
}

// MARK: - Sidebar

private struct DayList: View {
    @Bindable var model: LibraryModel

    var body: some View {
        let years = Dictionary(grouping: model.days, by: \.year).sorted { $0.key > $1.key }
        List(selection: $model.selectedDayID) {
            ForEach(years, id: \.key) { year, days in
                Section(year) {
                    ForEach(days) { day in
                        HStack {
                            Text(Self.rowTitle(for: day))
                            Spacer()
                            Text("\(day.photos.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(day.id)
                    }
                }
            }
        }
        .overlay {
            if model.isLoading && model.days.isEmpty { ProgressView() }
        }
    }

    static func rowTitle(for day: LibraryModel.Day) -> String {
        day.date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))
    }

    static func title(for day: LibraryModel.Day) -> String {
        day.date.formatted(.dateTime.year().month(.wide).day().weekday(.wide))
    }
}

// MARK: - Thumbnail

private struct Thumbnail: View {
    let photo: PhotoLibrary.Photo
    let size: Double
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Color.secondary.opacity(0.08)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(3)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            Text(photo.date.formatted(date: .omitted, time: .standard))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .task(id: photo.url) {
            // Decode at 2x for Retina, bucketed so resizing the grid doesn't re-decode constantly.
            let pixels = size > 220 ? 720 : 440
            image = ThumbnailLoader.shared.cached(photo.url, maxPixels: pixels)
            if image == nil { image = await ThumbnailLoader.shared.image(for: photo.url, maxPixels: pixels) }
        }
    }
}

// MARK: - Viewer

private struct PhotoViewer: View {
    let photos: [PhotoLibrary.Photo]
    let current: PhotoLibrary.Photo
    let onClose: () -> Void
    let onNavigate: (PhotoLibrary.Photo) -> Void
    let onDelete: (PhotoLibrary.Photo) -> Void
    @State private var image: NSImage?
    @FocusState private var focused: Bool

    private var index: Int? { photos.firstIndex(of: current) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(.vertical, 44).padding(.horizontal, 60)
            } else {
                ProgressView().controlSize(.large)
            }
            VStack {
                HStack {
                    Button("Close", systemImage: "xmark", action: onClose)
                    Spacer()
                    Text(current.date.formatted(date: .abbreviated, time: .standard))
                        .monospacedDigit()
                    if let index { Text("(\(index + 1) of \(photos.count))").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Move to Trash", systemImage: "trash") { onDelete(current) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .foregroundStyle(.white)
                .padding(12)
                Spacer()
                HStack {
                    navButton("chevron.left", offset: -1)
                    Spacer()
                    navButton("chevron.right", offset: 1)
                }
                .padding(.horizontal, 12)
                Spacer()
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.space) { onClose(); return .handled }
        .onDeleteCommand { onDelete(current) }
        .task(id: current.url) {
            image = ThumbnailLoader.shared.cached(current.url, maxPixels: 720)
            if let full = await ThumbnailLoader.shared.image(for: current.url, maxPixels: 2592) { image = full }
            prefetch()
        }
    }

    private func navButton(_ symbol: String, offset: Int) -> some View {
        Button { _ = step(offset) } label: {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(.borderless)
        .disabled(neighbour(offset) == nil)
    }

    private func neighbour(_ offset: Int) -> PhotoLibrary.Photo? {
        guard let index, photos.indices.contains(index + offset) else { return nil }
        return photos[index + offset]
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let next = neighbour(offset) else { return .ignored }
        onNavigate(next)
        return .handled
    }

    private func prefetch() {
        for offset in [1, -1] {
            if let url = neighbour(offset)?.url {
                Task { _ = await ThumbnailLoader.shared.image(for: url, maxPixels: 2592) }
            }
        }
    }
}
