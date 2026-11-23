import Foundation
import SwiftUI

/// 送信待ちの1枚。fileURL は一時ファイルで、送信後に消す。
struct PendingUpload {
    let fileURL: URL
    let filename: String
    /// 写真ライブラリの識別子(アプリ内の「写真から追加」のときだけ。送信後の削除に使う)
    let assetID: String?
}

/// 1枚ずつ順番に送る。途中で失敗しても、送れた分はサーバーに保存済みになる。
@MainActor
@Observable
final class UploadJob: Identifiable {
    let id = UUID()
    var total = 0
    var done = 0
    var added = 0
    var duplicates = 0
    var failures: [String] = []
    var finished = false
    var uploadedAssetIDs: [String] = []

    func run(folder: Int, count: Int, next: @escaping (Int) async throws -> PendingUpload) async {
        total = count
        for i in 0..<count {
            do {
                let p = try await next(i)
                defer { try? FileManager.default.removeItem(at: p.fileURL) }
                let r = try await API.shared.upload(fileURL: p.fileURL, filename: p.filename, folder: folder)
                if r.duplicate { duplicates += 1 } else { added += 1 }
                if let a = p.assetID { uploadedAssetIDs.append(a) }
            } catch {
                failures.append("\(i + 1)枚目: \(error.localizedDescription)")
            }
            done += 1
        }
        finished = true
    }
}

struct UploadProgressView: View {
    let job: UploadJob
    /// 写真アプリから削除する処理。共有拡張では nil(仕組み上削除できない)。
    var deleteFromPhotos: (([String]) async throws -> Void)? = nil
    let onClose: () -> Void

    @State private var deleteState: String?
    @State private var deleting = false

    var body: some View {
        List {
            Section {
                if job.finished {
                    LabeledContent("保存", value: "\(job.added) 枚")
                    if job.duplicates > 0 { LabeledContent("保存済みだった", value: "\(job.duplicates) 枚") }
                    if !job.failures.isEmpty { LabeledContent("失敗", value: "\(job.failures.count) 枚") }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("送信中 \(job.done) / \(job.total)").monospacedDigit()
                        ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                    }
                    .padding(.vertical, 4)
                }
            }
            if job.finished, let deleteFromPhotos, !job.uploadedAssetIDs.isEmpty {
                Section {
                    Button(role: .destructive) {
                        Task {
                            deleting = true
                            defer { deleting = false }
                            do {
                                try await deleteFromPhotos(job.uploadedAssetIDs)
                                deleteState = "写真アプリから削除しました(「最近削除した項目」に30日間残ります)"
                            } catch {
                                deleteState = "削除できませんでした: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Text("写真アプリから \(job.uploadedAssetIDs.count) 枚を削除")
                    }
                    .disabled(deleting || deleteState != nil)
                } footer: {
                    Text(deleteState ?? "送信できた画像だけを削除します。iPadOS の確認が出ます。")
                }
            }
            if job.finished, !job.failures.isEmpty {
                Section("失敗の内容") {
                    ForEach(job.failures, id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
        .navigationTitle(job.finished ? "送信完了" : "送信中")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる", action: onClose).disabled(!job.finished)
            }
        }
        .interactiveDismissDisabled(!job.finished)
    }
}

/// 最近使った保存先(本体と共有拡張でそれぞれ別に保存される)。
struct RecentFolder: Codable, Identifiable, Equatable {
    let id: Int
    let label: String
}

enum RecentFolders {
    private static let key = "recentFolders"

    static func load() -> [RecentFolder] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentFolder].self, from: data)) ?? []
    }

    static func add(_ f: RecentFolder) {
        var list = load().filter { $0.id != f.id }
        list.insert(f, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(5))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
