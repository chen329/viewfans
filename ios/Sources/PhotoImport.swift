import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// アプリ内の「写真から追加」用。共有拡張では使わない。
enum PhotoImport {
    static func load(_ item: PhotosPickerItem) async throws -> PendingUpload {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw APIError(message: "画像を読めません")
        }
        let ext = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })?.preferredFilenameExtension ?? "jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return PendingUpload(fileURL: url, filename: originalName(item.itemIdentifier) ?? "photo.\(ext)",
                             assetID: item.itemIdentifier)
    }

    /// 写真へのアクセスが許可済みなら、元のファイル名(IMG_1234.HEIC など)を使う。ファイル名順の並びに使うため。
    private static func originalName(_ id: String?) -> String? {
        guard let id else { return nil }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    /// 写真アプリから削除する。iPadOS の確認が出て、「最近削除した項目」に移る。
    static func deleteFromLibrary(_ ids: [String]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw APIError(message: "写真へのアクセスが許可されていません(設定 → View Fans → 写真)")
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { throw APIError(message: "削除する写真が見つかりません") }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
