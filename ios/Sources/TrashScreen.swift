import SwiftUI

/// 最近削除した項目。ここから消すと完全に削除される(30日を過ぎたものもサーバーが自動で消す)。
struct TrashScreen: View {
    @State private var contents: TrashContents?
    @State private var selectedFolders: Set<Int> = []
    @State private var selectedItems: Set<Int> = []
    @State private var errorText: String?
    @State private var confirmPurge = false
    @State private var confirmEmpty = false

    private var days: Int { contents?.days ?? 30 }
    private var selectionCount: Int { selectedFolders.count + selectedItems.count }
    private var allCount: Int { (contents?.folders.count ?? 0) + (contents?.items.count ?? 0) }

    var body: some View {
        ScrollView {
            if let contents, allCount > 0 {
                Text("項目は \(days) 日後に完全に削除されます。タップで選択します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 1)], spacing: 1) {
                    ForEach(contents.folders) { f in
                        trashTile(imageId: f.coverImageId, title: f.name, subtitle: "フォルダ・\(f.itemCount) 枚",
                                  left: daysLeft(f.deletedAt, days: days), selected: selectedFolders.contains(f.id))
                            .onTapGesture { toggle(&selectedFolders, f.id) }
                    }
                    ForEach(contents.items) { it in
                        trashTile(imageId: it.imageId, title: nil, subtitle: it.folderName,
                                  left: daysLeft(it.deletedAt, days: days), selected: selectedItems.contains(it.id))
                            .onTapGesture { toggle(&selectedItems, it.id) }
                    }
                }
            }
        }
        .background(Color.black)
        .overlay {
            if let errorText {
                ContentUnavailableView("エラー", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else if contents == nil {
                ProgressView()
            } else if allCount == 0 {
                ContentUnavailableView("最近削除した項目はありません", systemImage: "trash")
            }
        }
        .navigationTitle(selectionCount > 0 ? "\(selectionCount) 件を選択" : "最近削除した項目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(selectionCount == allCount ? "選択解除" : "すべて選択", systemImage: "checkmark.circle") {
                        if selectionCount == allCount {
                            selectedFolders = []
                            selectedItems = []
                        } else {
                            selectedFolders = Set(contents?.folders.map(\.id) ?? [])
                            selectedItems = Set(contents?.items.map(\.id) ?? [])
                        }
                    }
                    Button("すべて完全に削除", systemImage: "trash", role: .destructive) { confirmEmpty = true }
                        .disabled(allCount == 0)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("復元") { Task { await restore() } }
                    .disabled(selectionCount == 0)
                Spacer()
                Button("完全に削除", role: .destructive) { confirmPurge = true }
                    .disabled(selectionCount == 0)
            }
        }
        .confirmationDialog("\(selectionCount) 件を完全に削除しますか?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("完全に削除", role: .destructive) { Task { await purge() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("サーバーからファイルごと消え、元に戻せません。")
        }
        .confirmationDialog("すべて完全に削除しますか?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("すべて完全に削除", role: .destructive) { Task { await empty() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(allCount) 件がサーバーからファイルごと消え、元に戻せません。")
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func trashTile(imageId: Int?, title: String?, subtitle: String, left: Int, selected: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                TileImage(imageId: imageId, side: geo.size.width)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Label(title, systemImage: "folder.fill").font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Text("あと \(left) 日").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(6)
                if selected {
                    Color.white.opacity(0.15)
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.3))
                    .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
    }

    private func toggle(_ set: inout Set<Int>, _ id: Int) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func load() async {
        do {
            errorText = nil
            contents = try await API.shared.trash()
            let fids = Set(contents?.folders.map(\.id) ?? [])
            let iids = Set(contents?.items.map(\.id) ?? [])
            selectedFolders.formIntersection(fids)
            selectedItems.formIntersection(iids)
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            errorText = error.localizedDescription
        }
    }

    private func restore() async {
        await run { try await API.shared.restore(folders: Array(selectedFolders), items: Array(selectedItems)) }
    }

    private func purge() async {
        await run { try await API.shared.purge(folders: Array(selectedFolders), items: Array(selectedItems)) }
    }

    private func empty() async {
        await run { try await API.shared.emptyTrash() }
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            selectedFolders = []
            selectedItems = []
            await load()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 最上位の最後に置く「最近削除した項目」のマス。
struct TrashTile: View {
    let count: Int
    let side: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.12)
            Image(systemName: "trash")
                .font(.system(size: max(14, side * 0.25)))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if side >= 64 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("最近削除した項目").font(.system(size: min(max(side * 0.075, 10), 20), weight: .semibold)).lineLimit(1)
                    Text("\(count) 枚").font(.system(size: min(max(side * 0.06, 9), 16))).foregroundStyle(.secondary)
                }
                .padding(max(4, side * 0.06))
            }
        }
    }
}
