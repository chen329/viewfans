import SwiftUI

/// 正方形のマスに画像を中央で切り抜いて表示する。
struct TileImage: View {
    let imageId: Int?
    let side: CGFloat
    var crop = Crop()
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    private var pixel: Int { Int(side * scale * max(1, crop.zoom)) }
    /// サムネイルは長辺 600px。それより大きく表示するときは中間サイズを使う。
    private var variant: ImageVariant { pixel > 660 ? .medium : .thumb }
    /// メモリ節約のため、表示サイズに合わせて 100px 単位で縮小する。
    private var bucket: Int {
        let cap = variant == .thumb ? 600 : 1600
        return min(cap, ((pixel + 99) / 100) * 100)
    }

    var body: some View {
        Color(white: 0.1)
            .overlay {
                if let image {
                    let l = crop.layout(imageSize: image.size, side: side)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: l.size.width, height: l.size.height)
                        .offset(x: l.origin.x, y: l.origin.y)
                        .frame(width: side, height: side, alignment: .topLeading)
                } else if imageId == nil {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: max(12, side * 0.2)))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: "\(imageId ?? -1)-\(variant.rawValue)-\(bucket)") {
                guard let imageId else { image = nil; return }
                // 列数を変えたときは、新しい画像が届くまで今の画像を出したままにする
                if let img = await ImageStore.shared.image(id: imageId, variant: variant, maxPixel: bucket) {
                    image = img
                }
            }
    }
}

/// フォルダのマス。表紙画像の上に名前と枚数を重ねる。
struct FolderTile: View {
    let folder: Folder
    let side: CGFloat

    private var fontSize: CGFloat { min(max(side * 0.075, 10), 20) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TileImage(imageId: folder.coverImageId, side: side)
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            if side >= 64 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: fontSize, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if folder.childCount > 0 {
                            Label("\(folder.childCount)", systemImage: "folder")
                        }
                        Label("\(folder.itemCount)", systemImage: "photo")
                    }
                    .font(.system(size: fontSize * 0.8))
                    .foregroundStyle(.secondary)
                    .labelStyle(CompactLabelStyle())
                }
                .padding(max(4, side * 0.06))
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .padding(3)
            }
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
