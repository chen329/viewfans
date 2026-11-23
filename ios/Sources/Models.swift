import Foundation

struct Folder: Codable, Identifiable, Hashable {
    let id: Int
    let parentId: Int?
    var name: String
    let position: Int
    let itemCount: Int
    let childCount: Int
    var coverImageId: Int?
    var coverIsCustom: Bool?
    var sortMode: String?
    var childSortMode: String?
    var coverCropX: Double?
    var coverCropY: Double?
    var coverCropZoom: Double?
}

struct Item: Codable, Identifiable, Hashable {
    let id: Int
    let imageId: Int
    let position: Int
    var cropX: Double
    var cropY: Double
    var cropZoom: Double?
    let originalName: String?
    let width: Int
    let height: Int
    let ext: String
}

struct ItemsPage: Codable {
    let total: Int
    let offset: Int
    let items: [Item]
}

/// グリッドに並べる1マス。フォルダと画像を同じ並びで扱う。
enum Tile: Identifiable, Hashable {
    case folder(Folder)
    case image(index: Int, item: Item)
    /// 最上位の最後に置く「最近削除した項目」
    case trash(count: Int)

    var id: String {
        switch self {
        case .folder(let f): return "f\(f.id)"
        case .image(_, let it): return "i\(it.id)"
        case .trash: return "trash"
        }
    }
}

struct TrashRoute: Hashable {}

struct TrashFolder: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let parentId: Int?
    let itemCount: Int
    let coverImageId: Int?
    let deletedAt: String
}

struct TrashItem: Codable, Identifiable, Hashable {
    let id: Int
    let imageId: Int
    let folderId: Int
    let folderName: String
    let originalName: String?
    let deletedAt: String
}

struct TrashContents: Codable {
    let days: Int
    let folders: [TrashFolder]
    let items: [TrashItem]
}

struct ServerStats: Codable {
    let images: Int
    let items: Int
    let folders: Int
    let trashItems: Int
    let originalsBytes: Int64
    let diskTotal: Int64
    let diskUsed: Int64
}

/// 削除日時から、完全に削除されるまでの残り日数
func daysLeft(_ deletedAt: String, days: Int) -> Int {
    guard let d = ISO8601DateFormatter().date(from: deletedAt) else { return days }
    let passed = Int(Date().timeIntervalSince(d) / 86400)
    return max(0, days - passed)
}

enum ImageVariant: String {
    case thumb, medium, original
}

/// タイルに映る範囲。x・y は画像の中で枠の中心に来る位置(0〜1)、zoom は枠いっぱいからの拡大率。
struct Crop: Equatable {
    var x: Double = 0.5
    var y: Double = 0.5
    var zoom: Double = 1

    init(x: Double = 0.5, y: Double = 0.5, zoom: Double = 1) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    init(_ item: Item) {
        self.init(x: item.cropX, y: item.cropY, zoom: item.cropZoom ?? 1)
    }

    init(cover folder: Folder) {
        self.init(x: folder.coverCropX ?? 0.5, y: folder.coverCropY ?? 0.5, zoom: folder.coverCropZoom ?? 1)
    }

    /// 枠(side × side)に画像を置くときの大きさと左上の位置。枠が必ず埋まるように中心をずらす。
    func layout(imageSize: CGSize, side: CGFloat) -> (size: CGSize, origin: CGPoint) {
        guard imageSize.width > 0, imageSize.height > 0 else { return (CGSize(width: side, height: side), .zero) }
        let scale = side / min(imageSize.width, imageSize.height) * max(1, zoom)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        let ox = min(0, max(side - w, side / 2 - CGFloat(x) * w))
        let oy = min(0, max(side - h, side / 2 - CGFloat(y) * h))
        return (CGSize(width: w, height: h), CGPoint(x: ox, y: oy))
    }
}
