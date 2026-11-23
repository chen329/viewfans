import ImageIO
import UIKit

/// 画像の取得とキャッシュ。サムネイル・中間サイズは端末にキャッシュし、元画像は保存しない。
actor ImageStore {
    static let shared = ImageStore()
    static let diskLimit = 2 * 1024 * 1024 * 1024  // 2GB

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.totalCostLimit = 300 * 1024 * 1024
    }

    /// maxPixel: 表示に必要な長辺のピクセル数。これに合わせて縮小してメモリを節約する。
    func image(id: Int, variant: ImageVariant, maxPixel: Int) async -> UIImage? {
        let fileKey = "\(variant.rawValue)-\(id)"
        let memKey = "\(fileKey)@\(maxPixel)"
        if let hit = memory.object(forKey: memKey as NSString) { return hit }
        if let running = inflight[memKey] { return await running.value }

        let file = dir.appendingPathComponent(fileKey)
        let cacheToDisk = variant != .original
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            var data = cacheToDisk ? try? Data(contentsOf: file) : nil
            if data == nil {
                data = try? await API.shared.imageData(id, variant: variant)
                if cacheToDisk, let d = data { try? d.write(to: file, options: .atomic) }
            }
            guard let d = data else { return nil }
            return ImageStore.downsample(d, maxPixel: maxPixel)
        }
        inflight[memKey] = task
        let img = await task.value
        inflight[memKey] = nil
        if let img, variant != .original {
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
            memory.setObject(img, forKey: memKey as NSString, cost: cost)
        }
        return img
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - ディスクキャッシュの管理

    private func entries() -> [(url: URL, date: Date, size: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return files.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (url: url, date: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0)
        }
    }

    func diskUsage() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// 上限を超えていたら古いものから消して、上限の8割まで減らす。
    func trim(limit: Int = ImageStore.diskLimit) {
        var list = entries()
        var total = list.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        list.sort { $0.date < $1.date }
        for e in list {
            if total <= limit / 10 * 8 { break }
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }

    func clear() {
        memory.removeAllObjects()
        for e in entries() { try? FileManager.default.removeItem(at: e.url) }
    }

    func forgetMemory() {
        memory.removeAllObjects()
    }
}
