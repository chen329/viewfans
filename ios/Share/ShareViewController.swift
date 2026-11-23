import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 共有シートの「View Fans」。保存先フォルダを選んで、受け取った画像を順番に送る。
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let inputs = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = inputs
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        let root = ShareFlowView(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ShareFlowView: View {
    let providers: [NSItemProvider]
    let close: () -> Void

    @State private var configured = API.shared.isConfigured
    @State private var target: RecentFolder?
    @State private var job: UploadJob?

    var body: some View {
        NavigationStack {
            Group {
                if !configured {
                    ShareSetupView { configured = API.shared.isConfigured }
                } else if let job {
                    UploadProgressView(job: job, onClose: close)
                } else {
                    FolderPickerView(selection: $target)
                        .navigationTitle("\(providers.count) 枚の保存先")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("キャンセル", action: close) }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("送信", action: start).disabled(target == nil || providers.isEmpty)
                            }
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func start() {
        guard let target else { return }
        RecentFolders.add(target)
        let j = UploadJob()
        job = j
        let list = providers
        Task { await j.run(folder: target.id, count: list.count) { i in try await ShareFile.load(list[i]) } }
    }
}

enum ShareFile {
    /// 共有元から元のファイルを受け取り、一時ファイルにコピーする。
    static func load(_ provider: NSItemProvider) async throws -> PendingUpload {
        let type = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: .image) } ?? .image
        do {
            return try await loadFile(provider, type: type)
        } catch {
            return try await loadData(provider, type: type)
        }
    }

    private static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    private static func loadFile(_ provider: NSItemProvider, type: UTType) async throws -> PendingUpload {
        try await withCheckedThrowingContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    cont.resume(throwing: error ?? APIError(message: "画像を読めません"))
                    return
                }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "jpg") : url.pathExtension
                let dst = tempURL(ext: ext)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    cont.resume(returning: PendingUpload(fileURL: dst, filename: url.lastPathComponent, assetID: nil))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> PendingUpload {
        try await withCheckedThrowingContinuation { cont in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                guard let data else {
                    cont.resume(throwing: error ?? APIError(message: "画像を読めません"))
                    return
                }
                let ext = type.preferredFilenameExtension ?? "jpg"
                let dst = tempURL(ext: ext)
                do {
                    try data.write(to: dst)
                    cont.resume(returning: PendingUpload(fileURL: dst, filename: "image.\(ext)", assetID: nil))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

/// 共有拡張は本体と設定を共有できない(無料 Apple ID では App Group が使えない)ため、初回だけ入力する。
struct ShareSetupView: View {
    let onSaved: () -> Void
    @State private var url = API.shared.baseURL
    @State private var token = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("トークン", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("サーバー")
            } footer: {
                Text("共有からの送信用に、初回だけ入力してください。本体アプリと同じトークンで使えます。")
            }
            Section {
                Button(testing ? "確認中…" : "接続を確認") {
                    Task {
                        testing = true
                        defer { testing = false }
                        do {
                            let n = try await API.shared.test(baseURL: url, token: token)
                            status = "接続できました(最上位のフォルダ \(n) 個)"
                        } catch {
                            status = "接続できません: \(error.localizedDescription)"
                        }
                    }
                }
                .disabled(testing || token.isEmpty)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("接続設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    API.shared.save(baseURL: url, token: token)
                    onSaved()
                }
                .disabled(token.isEmpty || url.isEmpty)
            }
        }
    }
}
