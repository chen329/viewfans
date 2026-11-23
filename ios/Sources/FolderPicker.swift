import SwiftUI

/// 保存先フォルダの選択。親 → 子の2段で、その場で新しいフォルダも作れる。
struct FolderPickerView: View {
    @Binding var selection: RecentFolder?

    @State private var roots: [Folder] = []
    @State private var children: [Int: [Folder]] = [:]
    @State private var expanded: Set<Int> = []
    @State private var recents = RecentFolders.load()
    @State private var errorText: String?
    @State private var showNew = false
    @State private var newName = ""
    @State private var newParent: Folder?

    var body: some View {
        List {
            if !recents.isEmpty {
                Section("最近使ったフォルダ") {
                    ForEach(recents) { r in row(id: r.id, label: r.label, title: r.label) }
                }
            }
            Section("すべてのフォルダ") {
                ForEach(roots) { f in
                    DisclosureGroup(isExpanded: expandBinding(f.id)) {
                        ForEach(children[f.id] ?? []) { c in
                            row(id: c.id, label: "\(f.name) / \(c.name)", title: c.name)
                        }
                        Button {
                            newParent = f
                            newName = ""
                            showNew = true
                        } label: {
                            Label("「\(f.name)」の中に新しいフォルダ", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        row(id: f.id, label: f.name, title: f.name)
                    }
                }
                Button {
                    newParent = nil
                    newName = ""
                    showNew = true
                } label: {
                    Label("新しいフォルダ", systemImage: "folder.badge.plus")
                }
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.footnote)
            }
        }
        .alert(newParent.map { "「\($0.name)」の中に新しいフォルダ" } ?? "新しいフォルダ", isPresented: $showNew) {
            TextField("名前", text: $newName)
            Button("作成") { Task { await create() } }
            Button("キャンセル", role: .cancel) {}
        }
        .task { await loadRoots() }
    }

    private func row(id: Int, label: String, title: String) -> some View {
        Button {
            selection = RecentFolder(id: id, label: label)
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selection?.id == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func expandBinding(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { open in
                if open {
                    expanded.insert(id)
                    Task { await loadChildren(id) }
                } else {
                    expanded.remove(id)
                }
            }
        )
    }

    private func loadRoots() async {
        do {
            roots = try await API.shared.folders(parent: nil)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadChildren(_ id: Int) async {
        do {
            children[id] = try await API.shared.folders(parent: id)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let f = try await API.shared.createFolder(name: name, parent: newParent?.id)
            if let parent = newParent {
                expanded.insert(parent.id)
                await loadChildren(parent.id)
                selection = RecentFolder(id: f.id, label: "\(parent.name) / \(f.name)")
            } else {
                await loadRoots()
                selection = RecentFolder(id: f.id, label: f.name)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
