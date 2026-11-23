import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ViewerTarget: Identifiable {
    let id = UUID()
    let index: Int
}

/// 削除の確認で使う対象。
enum DeleteTarget: Identifiable {
    case items([Int])
    case folder(Folder)

    var id: String {
        switch self {
        case .items(let ids): return "i" + ids.map(String.init).joined(separator: ",")
        case .folder(let f): return "f\(f.id)"
        }
    }
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
    @State private var showPhotoPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploadJob: UploadJob?

    @State private var dragging: Item?
    @State private var cropTarget: Item?
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var deleteTarget: DeleteTarget?
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    init(folder: Folder?) {
        self.folder = folder
        _current = State(initialValue: folder)
    }

    private var folderID: Int? { folder?.id }
    /// 子フォルダを作れるのは最上位と、最上位直下のフォルダだけ(2段まで)
    private var canCreateFolder: Bool { folder == nil || folder?.parentId == nil }

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
                    // マスの外で指を離したときも、その時点の並びで確定する
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(target: nil, items: $items, dragging: $dragging, onCommit: commitMove))
                }
                .scrollPosition(id: $topID, anchor: .top)
                .simultaneousGesture(pinch)
                .onChange(of: columns) { _, _ in restore(proxy) }
                .overlay {
                    if let errorText {
                        ContentUnavailableView("エラー", systemImage: "exclamationmark.triangle", description: Text(errorText))
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
        .navigationTitle(selecting ? "\(selected.count) 枚を選択" : (current?.name ?? "View Fans"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        .toolbar { toolbarContent }
        .refreshable { await load() }
        .task {
            dragging = nil
            await load()
        }
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, matching: .images, photoLibrary: .shared())
        .onChange(of: pickerItems) { _, picked in
            guard !picked.isEmpty, let fid = folderID else { return }
            pickerItems = []
            let job = UploadJob()
            uploadJob = job
            Task {
                await job.run(folder: fid, count: picked.count) { i in try await PhotoImport.load(picked[i]) }
                await load()
            }
        }
        .sheet(item: $uploadJob) { job in
            NavigationStack {
                UploadProgressView(job: job, deleteFromPhotos: PhotoImport.deleteFromLibrary) { uploadJob = nil }
            }
        }
        .sheet(item: $cropTarget) { item in
            NavigationStack {
                CropEditor(item: item) { crop in
                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                        items[i].cropX = crop.x
                        items[i].cropY = crop.y
                        items[i].cropZoom = crop.zoom
                    }
                }
            }
        }
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                ConnectionSettingsView(isFirstRun: false) { Task { await load() } }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { target in
            Button("完全に削除", role: .destructive) { Task { await performDelete(target) } }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("サーバーからも消え、元に戻せません。ほかのフォルダにも入っている画像は、そちらには残ります。")
        }
        .alert(folder == nil ? "新しいフォルダ" : "「\(current?.name ?? "")」の中に新しいフォルダ", isPresented: $showNewFolder) {
            TextField("名前", text: $newFolderName)
            Button("作成") { Task { await createFolder() } }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("完了") { selecting = false; selected = [] }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selected.count == items.count ? "選択解除" : "すべて選択") {
                    selected = selected.count == items.count ? [] : Set(items.map(\.id))
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("削除", systemImage: "trash", role: .destructive) {
                    deleteTarget = .items(Array(selected))
                }
                .disabled(selected.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("列数を変更", systemImage: "square.grid.3x3") { showColumns = true }
                    if folder != nil {
                        Button("写真から追加", systemImage: "photo.badge.plus") { showPhotoPicker = true }
                    }
                    if canCreateFolder {
                        Button("新しいフォルダ", systemImage: "folder.badge.plus") {
                            newFolderName = ""
                            showNewFolder = true
                        }
                    }
                    if !items.isEmpty {
                        Button("選択", systemImage: "checkmark.circle") { selecting = true }
                    }
                    if current?.sortMode == "manual" {
                        Button("ファイル名順に並べ直す", systemImage: "textformat.123") { Task { await sortByName() } }
                    }
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
            .disabled(selecting)
            .opacity(selecting ? 0.4 : 1)
            .contextMenu {
                if f.coverIsCustom == true {
                    Button("表紙を自動に戻す", systemImage: "arrow.uturn.backward") {
                        Task { await patch(f.id, ["clear_cover": true]) }
                    }
                }
                Button("フォルダを削除", systemImage: "trash", role: .destructive) { deleteTarget = .folder(f) }
            }
        case .image(let index, let item):
            if selecting {
                TileImage(imageId: item.imageId, side: side, crop: Crop(item))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: max(14, min(side * 0.15, 28))))
                            .foregroundStyle(.white, selected.contains(item.id) ? Color.accentColor : Color.black.opacity(0.3))
                            .padding(4)
                    }
                    .overlay {
                        if selected.contains(item.id) { Color.white.opacity(0.15) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                    }
            } else {
                TileImage(imageId: item.imageId, side: side, crop: Crop(item))
                    .contentShape(Rectangle())
                    .onTapGesture { viewer = ViewerTarget(index: index) }
                    // 長押しでメニュー、長押しのまま指を動かすとドラッグで並べ替え(ホーム画面と同じ操作)
                    .onDrag {
                        dragging = item
                        return NSItemProvider(object: String(item.id) as NSString)
                    } preview: {
                        TileImage(imageId: item.imageId, side: side, crop: Crop(item))
                            .frame(width: side, height: side)
                    }
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(target: item, items: $items, dragging: $dragging, onCommit: commitMove))
                    .contextMenu { imageMenu(item) }
            }
        }
    }

    @ViewBuilder
    private func imageMenu(_ item: Item) -> some View {
        Button("表示位置を調整", systemImage: "crop") { cropTarget = item }
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
        Button("削除", systemImage: "trash", role: .destructive) { deleteTarget = .items([item.id]) }
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

    // MARK: - 読み込み・操作

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

    private func commitMove(_ item: Item, _ index: Int) {
        Task {
            do {
                current = try await API.shared.moveItem(item.id, toIndex: index)
            } catch {
                errorText = error.localizedDescription
                await load()
            }
        }
    }

    private func sortByName() async {
        guard let fid = folderID else { return }
        do {
            current = try await API.shared.setSort(fid, mode: "name")
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var deleteTitle: String {
        switch deleteTarget {
        case .items(let ids): return "\(ids.count) 枚を削除しますか?"
        case .folder(let f):
            let children = f.childCount > 0 ? "子フォルダ \(f.childCount) 個と" : ""
            return "「\(f.name)」(\(children)中の画像)を削除しますか?"
        case nil: return ""
        }
    }

    private func performDelete(_ target: DeleteTarget) async {
        do {
            switch target {
            case .items(let ids):
                try await API.shared.deleteItems(ids)
                selected.subtract(ids)
                if selected.isEmpty { selecting = false }
            case .folder(let f):
                try await API.shared.deleteFolder(f.id)
            }
            deleteTarget = nil
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try await API.shared.createFolder(name: name, parent: folderID)
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// ドラッグ中のマスが別のマスに重なったら、その場で並びを入れ替える。指を離したら確定してサーバーに送る。
struct ReorderDropDelegate: DropDelegate {
    let target: Item?
    @Binding var items: [Item]
    @Binding var dragging: Item?
    let onCommit: (Item, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let target, let d = dragging, d.id != target.id,
              let from = items.firstIndex(where: { $0.id == d.id }),
              let to = items.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let d = dragging, let index = items.firstIndex(where: { $0.id == d.id }) {
            onCommit(d, index)
        }
        dragging = nil
        return true
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
