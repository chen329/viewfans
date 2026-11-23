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

    var id: String {
        switch self {
        case .folder(let f): return "f\(f.id)"
        case .image(_, let it): return "i\(it.id)"
        }
    }
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
