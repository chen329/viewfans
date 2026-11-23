import SwiftUI

struct ViewerTarget: Identifiable {
    let id = UUID()
    let index: Int
}

/// フォルダの中身(子フォルダと画像)を同じグリッドに並べる画面。folder が nil なら最上位。
struct FolderScreen: View {
    let folder: Folder?

    @State private var current: Folder?
    @State private var folders: [Folder] = []
    @State private var items: [Item] = []
    @State private var errorText: String?
    @State private var loaded = false

    @State private var columns = 5
    @State private var landscape = false
    @State private var pinchBase: Int?
    @State private var topID: String?

    @State private var viewer: ViewerTarget?
    @State private var showColumns = false
    @State private var showFolderSettings = false
    @State private var showConnection = false

    init(folder: Folder?) {
        self.folder = folder
        _current = State(initialValue: folder)
    }

    private var folderID: Int? { folder?.id }

    private var tiles: [Tile] {
        folders.map { .folder($0) } + items.enumerated().map { .image(index: $0.offset, item: $0.element) }
    }

    var body: some View {
        GeometryReader { geo in
            let side = max(1, (geo.size.width - CGFloat(columns - 1)) / CGFloat(columns))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: columns), spacing: 1) {
                        ForEach(tiles) { tile in
                            tileView(tile, side: side)
                                .aspectRatio(1, contentMode: .fit)
                                .id(tile.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $topID, anchor: .top)
                .simultaneousGesture(pinch)
                .onChange(of: columns) { _, _ in
                    restore(proxy)
                }
                .overlay {
                    if let errorText {
                        ContentUnavailableView("読み込めません", systemImage: "wifi.exclamationmark", description: Text(errorText))
                    } else if loaded && tiles.isEmpty {
                        ContentUnavailableView("空のフォルダ", systemImage: "folder")
                    } else if !loaded {
                        ProgressView()
                    }
                }
            }
            .onAppear { updateOrientation(geo.size) }
            .onChange(of: geo.size) { _, size in updateOrientation(size) }
        }
        .background(Color.black)
        .navigationTitle(current?.name ?? "View Fans")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("列数を変更", systemImage: "square.grid.3x3") { showColumns = true }
                    if folder != nil {
                        Button("フォルダの設定", systemImage: "folder.badge.gearshape") { showFolderSettings = true }
                    } else {
                        Button("接続設定", systemImage: "gearshape") { showConnection = true }
                    }
                    Button("再読み込み", systemImage: "arrow.clockwise") { Task { await load() } }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .popover(isPresented: $showColumns) {
                    ColumnPicker(columns: $columns)
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: columns) { _, value in
            ColumnStore.set(value, folder: folderID, landscape: landscape)
        }
        .fullScreenCover(item: $viewer) { target in
            PhotoViewer(items: items, start: target.index)
        }
        .sheet(isPresented: $showFolderSettings) {
            if let current {
                NavigationStack {
                    FolderSettingsView(folder: current) { updated in self.current = updated }
                }
            }
        }
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                ConnectionSettingsView(isFirstRun: false) { Task { await load() } }
            }
        }
    }

    // MARK: - マス

    @ViewBuilder
    private func tileView(_ tile: Tile, side: CGFloat) -> some View {
        switch tile {
        case .folder(let f):
            NavigationLink(value: f) {
                FolderTile(folder: f, side: side)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if f.coverIsCustom == true {
                    Button("表紙を自動に戻す", systemImage: "arrow.uturn.backward") {
                        Task { await patch(f.id, ["clear_cover": true]) }
                    }
                }
            }
        case .image(let index, let item):
            TileImage(imageId: item.imageId, side: side)
                .contentShape(Rectangle())
                .onTapGesture { viewer = ViewerTarget(index: index) }
                .contextMenu {
                    if let fid = folderID {
                        Button("このフォルダの表紙にする", systemImage: "photo.badge.checkmark") {
                            Task { await patch(fid, ["cover_image_id": item.imageId]) }
                        }
                    }
                    if let parent = current?.parentId {
                        Button("親フォルダの表紙にする", systemImage: "photo.badge.arrow.down") {
                            Task { await patch(parent, ["cover_image_id": item.imageId]) }
                        }
                    }
                }
        }
    }

    // MARK: - 列数

    /// ピンチで1列ずつ増減する。指を広げると列が減り(大きく)、つまむと列が増える。
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? columns
                if pinchBase == nil { pinchBase = base }
                let steps = Int((log(value.magnification) / log(1.3)).rounded())
                let target = min(max(base - steps, ColumnStore.range.lowerBound), ColumnStore.range.upperBound)
                if target != columns {
                    withAnimation(.easeInOut(duration: 0.15)) { columns = target }
                }
            }
            .onEnded { _ in pinchBase = nil }
    }

    /// 列数が変わっても、見ていた位置(画面上端のマス)を保つ。
    private func restore(_ proxy: ScrollViewProxy) {
        guard let keep = topID else { return }
        DispatchQueue.main.async { proxy.scrollTo(keep, anchor: .top) }
    }

    private func updateOrientation(_ size: CGSize) {
        let isLandscape = size.width > size.height
        if isLandscape != landscape || !loaded {
            landscape = isLandscape
            columns = ColumnStore.get(folder: folderID, landscape: isLandscape)
        }
    }

    // MARK: - 読み込み

    private func load() async {
        do {
            errorText = nil
            async let fs = API.shared.folders(parent: folderID)
            if let fid = folderID {
                current = try await API.shared.folder(fid)
                var all: [Item] = []
                var offset = 0
                while true {
                    let page = try await API.shared.items(folder: fid, offset: offset, limit: 1000)
                    all += page.items
                    offset += page.items.count
                    if page.items.isEmpty || offset >= page.total { break }
                }
                if all != items { items = all }
            }
            let newFolders = try await fs
            if newFolders != folders { folders = newFolders }
        } catch is CancellationError {
            return
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            errorText = error.localizedDescription
        }
        loaded = true
    }

    private func patch(_ id: Int, _ body: [String: Any]) async {
        do {
            let updated = try await API.shared.patchFolder(id, body)
            if id == current?.id { current = updated }
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct ColumnPicker: View {
    @Binding var columns: Int

    var body: some View {
        VStack(spacing: 16) {
            Text("列数 \(columns)")
                .font(.headline)
                .monospacedDigit()
            HStack {
                Button { columns = max(ColumnStore.range.lowerBound, columns - 1) } label: { Image(systemName: "minus") }
                Slider(
                    value: Binding(get: { Double(columns) }, set: { columns = Int($0.rounded()) }),
                    in: Double(ColumnStore.range.lowerBound)...Double(ColumnStore.range.upperBound),
                    step: 1
                )
                Button { columns = min(ColumnStore.range.upperBound, columns + 1) } label: { Image(systemName: "plus") }
            }
            Text("この設定はフォルダごと・縦横別に保存されます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 340)
    }
}
