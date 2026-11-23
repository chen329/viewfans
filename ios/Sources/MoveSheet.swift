import SwiftUI

/// 移動の対象。
enum MoveTarget: Identifiable {
    case items([Int])
    case folder(Folder)

    var id: String {
        switch self {
        case .items(let ids): return "i" + ids.map(String.init).joined(separator: ",")
        case .folder(let f): return "f\(f.id)"
        }
    }
}

struct MoveSheet: View {
    let target: MoveTarget
    let onDone: () -> Void

    @State private var dest: RecentFolder?
    @State private var roots: [Folder] = []
    /// フォルダの移動先。nil は最上位
    @State private var parent: Int??
    @State private var errorText: String?
    @State private var moving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch target {
            case .items:
                FolderPickerView(selection: $dest)
            case .folder(let f):
                List {
                    Section {
                        row(nil, title: "最上位")
                        ForEach(roots.filter { $0.id != f.id }) { r in row(r.id, title: r.name) }
                    } footer: {
                        Text(f.childCount > 0 ? "子フォルダを持つフォルダは最上位にだけ置けます(2段まで)。" : "フォルダは2段までなので、最上位のフォルダの中にだけ入れられます。")
                    }
                }
                .task { roots = (try? await API.shared.folders(parent: nil)) ?? [] }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red).padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("移動") { Task { await move() } }.disabled(!canMove || moving)
            }
        }
    }

    private var title: String {
        switch target {
        case .items(let ids): return "\(ids.count) 枚の移動先"
        case .folder(let f): return "「\(f.name)」の移動先"
        }
    }

    private var canMove: Bool {
        switch target {
        case .items: return dest != nil
        case .folder: return parent != nil
        }
    }

    private func row(_ id: Int?, title: String) -> some View {
        Button {
            parent = .some(id)
        } label: {
            HStack {
                Label(title, systemImage: id == nil ? "square.grid.2x2" : "folder")
                    .foregroundStyle(.primary)
                Spacer()
                if parent == .some(id) {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func move() async {
        moving = true
        defer { moving = false }
        do {
            switch target {
            case .items(let ids):
                guard let dest else { return }
                RecentFolders.add(dest)
                try await API.shared.moveItems(ids, to: dest.id)
            case .folder(let f):
                guard let parent else { return }
                try await API.shared.moveFolder(f.id, toParent: parent)
            }
            onDone()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
