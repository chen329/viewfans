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
}

struct Item: Codable, Identifiable, Hashable {
    let id: Int
    let imageId: Int
    let position: Int
    let cropX: Double
    let cropY: Double
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
