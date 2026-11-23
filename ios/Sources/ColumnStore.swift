import Foundation

/// 列数をフォルダごと・縦横別に端末へ保存する。
enum ColumnStore {
    static let range = 1...20

    private static func key(folder: Int?, landscape: Bool) -> String {
        "columns.\(folder.map(String.init) ?? "root").\(landscape ? "landscape" : "portrait")"
    }

    static func get(folder: Int?, landscape: Bool) -> Int {
        let v = UserDefaults.standard.integer(forKey: key(folder: folder, landscape: landscape))
        return v == 0 ? defaultColumns(landscape: landscape) : min(max(v, range.lowerBound), range.upperBound)
    }

    /// 列数を変えたことのないフォルダで使う列数(設定画面で変更できる)
    static func defaultColumns(landscape: Bool) -> Int {
        let v = UserDefaults.standard.integer(forKey: "columns.default.\(landscape ? "landscape" : "portrait")")
        return v == 0 ? (landscape ? 7 : 5) : v
    }

    static func setDefault(_ value: Int, landscape: Bool) {
        UserDefaults.standard.set(value, forKey: "columns.default.\(landscape ? "landscape" : "portrait")")
    }

    static func set(_ value: Int, folder: Int?, landscape: Bool) {
        UserDefaults.standard.set(value, forKey: key(folder: folder, landscape: landscape))
    }
}
