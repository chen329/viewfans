import SwiftUI

/// 全体設定。今は情報表示と少しの設定だけ。今後の設定はここに足していく。
struct AppSettingsView: View {
    let onConnectionChanged: () -> Void

    @State private var stats: ServerStats?
    @State private var statsError: String?
    @State private var cacheBytes: Int?
    @State private var portrait = ColumnStore.defaultColumns(landscape: false)
    @State private var landscape = ColumnStore.defaultColumns(landscape: true)
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    var body: some View {
        Form {
            Section("サーバー") {
                NavigationLink {
                    ConnectionSettingsView(isFirstRun: false, onSaved: onConnectionChanged)
                } label: {
                    LabeledContent("接続先", value: API.shared.baseURL)
                }
            }
            Section("ライブラリ") {
                if let stats {
                    LabeledContent("画像", value: "\(stats.items) 枚")
                    LabeledContent("フォルダ", value: "\(stats.folders) 個")
                    LabeledContent("最近削除した項目", value: "\(stats.trashItems) 枚")
                    LabeledContent("元画像の合計", value: bytes(stats.originalsBytes))
                    LabeledContent("サーバーのディスク", value: "\(bytes(stats.diskUsed)) / \(bytes(stats.diskTotal))")
                } else if let statsError {
                    Text(statsError).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            Section {
                Stepper("縦向き \(portrait) 列", value: $portrait, in: ColumnStore.range)
                Stepper("横向き \(landscape) 列", value: $landscape, in: ColumnStore.range)
            } header: {
                Text("表示")
            } footer: {
                Text("列数を変えたことのないフォルダで使う列数です。")
            }
            Section("キャッシュ") {
                LabeledContent("使用量", value: cacheBytes.map { bytes(Int64($0)) } ?? "…")
                Button("キャッシュを消去", role: .destructive) {
                    Task {
                        await ImageStore.shared.clear()
                        cacheBytes = await ImageStore.shared.diskUsage()
                    }
                }
            }
            Section("情報") {
                LabeledContent("バージョン", value: "\(version)(\(build))")
                NavigationLink("変更履歴") { ChangelogView() }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
        }
        .onChange(of: portrait) { _, v in ColumnStore.setDefault(v, landscape: false) }
        .onChange(of: landscape) { _, v in ColumnStore.setDefault(v, landscape: true) }
        .task {
            cacheBytes = await ImageStore.shared.diskUsage()
            do {
                stats = try await API.shared.stats()
            } catch {
                statsError = error.localizedDescription
            }
        }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

struct ChangelogView: View {
    struct Entry: Identifiable {
        let version: String
        let date: String
        let notes: [String]
        var id: String { version }
    }

    static let entries: [Entry] = [
        Entry(version: "0.6.0", date: "2026-11-23", notes: [
            "最近削除した項目(30日後に完全に削除、復元・完全に削除)",
            "選択モードでスワイプしてまとめて選択",
            "画像・フォルダの移動",
            "設定画面と変更履歴",
        ]),
        Entry(version: "0.5.0", date: "2026-11-23", notes: [
            "フォルダの並べ替えと表紙の表示位置の調整",
            "ドラッグ中は元の場所を空白で表示",
        ]),
        Entry(version: "0.4.0", date: "2026-11-23", notes: [
            "ドラッグで並べ替え(ホーム画面と同じ操作)",
            "タイルの表示位置と拡大率の調整",
            "画像・フォルダの削除、フォルダの作成",
            "初期の並びをファイル名順に",
        ]),
        Entry(version: "0.3.0", date: "2026-11-23", notes: [
            "共有シートから送信",
            "写真から追加と、送信後に写真アプリから削除",
        ]),
        Entry(version: "0.2.0", date: "2026-11-23", notes: [
            "フォルダとタイル一覧、拡大表示",
            "ピンチで列数を変更(フォルダごと・縦横別)",
            "表紙の設定、アプリスイッチャーで中身を隠す",
        ]),
        Entry(version: "0.0.1", date: "2026-11-23", notes: ["最初のビルド(TileView M0)"]),
    ]

    var body: some View {
        List(Self.entries) { e in
            Section("\(e.version)(\(e.date))") {
                ForEach(e.notes, id: \.self) { Text($0) }
            }
        }
        .navigationTitle("変更履歴")
        .navigationBarTitleDisplayMode(.inline)
    }
}
