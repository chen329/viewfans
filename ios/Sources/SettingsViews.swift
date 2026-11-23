import SwiftUI

/// サーバーの URL とトークンの設定。初回起動時にも使う。
struct ConnectionSettingsView: View {
    let isFirstRun: Bool
    let onSaved: () -> Void

    @State private var url = API.shared.baseURL
    @State private var token = API.shared.token
    @State private var status: String?
    @State private var testing = false
    @State private var cacheBytes: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("サーバー") {
                TextField("URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("トークン", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Button(testing ? "確認中…" : "接続を確認") { Task { await test() } }
                    .disabled(testing || token.isEmpty)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            if !isFirstRun {
                Section("キャッシュ") {
                    LabeledContent("使用量", value: cacheBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                    Button("キャッシュを消去", role: .destructive) {
                        Task {
                            await ImageStore.shared.clear()
                            cacheBytes = await ImageStore.shared.diskUsage()
                        }
                    }
                }
            }
        }
        .navigationTitle(isFirstRun ? "View Fans の接続設定" : "接続設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isFirstRun {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    API.shared.save(baseURL: url, token: token)
                    onSaved()
                    if !isFirstRun { dismiss() }
                }
                .disabled(token.isEmpty || url.isEmpty)
            }
        }
        .task { if !isFirstRun { cacheBytes = await ImageStore.shared.diskUsage() } }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let n = try await API.shared.test(baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
                                              token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            status = "接続できました(最上位のフォルダ \(n) 個)"
        } catch {
            status = "接続できません: \(error.localizedDescription)"
        }
    }
}

/// フォルダの設定。今は名前と表紙だけ。
struct FolderSettingsView: View {
    let folder: Folder
    let onUpdated: (Folder) -> Void

    @State private var name: String
    @State private var errorText: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(folder: Folder, onUpdated: @escaping (Folder) -> Void) {
        self.folder = folder
        self.onUpdated = onUpdated
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        Form {
            Section("名前") {
                TextField("名前", text: $name)
            }
            Section {
                HStack {
                    Text("表紙")
                    Spacer()
                    TileImage(imageId: folder.coverImageId, side: 56)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if folder.coverIsCustom == true {
                    Button("表紙を自動に戻す") { Task { await save(["clear_cover": true]) } }
                }
            } footer: {
                Text("表紙は、画像を長押しして「このフォルダの表紙にする」で変更できます。")
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
        }
        .navigationTitle("フォルダの設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save(["name": name]) } }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || name == folder.name)
            }
        }
    }

    private func save(_ body: [String: Any]) async {
        saving = true
        defer { saving = false }
        do {
            let updated = try await API.shared.patchFolder(folder.id, body)
            onUpdated(updated)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
