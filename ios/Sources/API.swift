import Foundation
import Security

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// サーバーとの通信。URL は UserDefaults、トークンはキーチェーンに保存する。
final class API: @unchecked Sendable {
    static let shared = API()

    private(set) var baseURL: String
    private(set) var token: String
    let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "https://vfan.home.arpa"
        token = Keychain.load() ?? ""
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    var isConfigured: Bool { !token.isEmpty && URL(string: baseURL) != nil }

    func save(baseURL: String, token: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.baseURL, forKey: "baseURL")
        Keychain.save(self.token)
    }

    // MARK: - 共通

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: Any? = nil,
                         baseURL: String? = nil, token: String? = nil) throws -> URLRequest {
        guard var comps = URLComponents(string: (baseURL ?? self.baseURL) + path) else {
            throw APIError(message: "URL が正しくありません")
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError(message: "URL が正しくありません") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token ?? self.token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private struct Detail: Decodable { let detail: String }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "応答が不正です") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(Detail.self, from: data))?.detail ?? "HTTP \(http.statusCode)"
            throw APIError(message: msg)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try decoder.decode(T.self, from: try await send(try request(path, query: query)))
    }

    // MARK: - API

    /// 入力中の URL・トークンで接続を確かめる(保存はしない)。
    func test(baseURL: String, token: String) async throws -> Int {
        let req = try request("/api/folders", baseURL: baseURL, token: token)
        let folders = try decoder.decode([Folder].self, from: try await send(req))
        return folders.count
    }

    func folders(parent: Int?) async throws -> [Folder] {
        try await get("/api/folders", query: parent.map { [URLQueryItem(name: "parent_id", value: String($0))] } ?? [])
    }

    func folder(_ id: Int) async throws -> Folder {
        try await get("/api/folders/\(id)")
    }

    func items(folder: Int, offset: Int, limit: Int) async throws -> ItemsPage {
        try await get("/api/folders/\(folder)/items", query: [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    func patchFolder(_ id: Int, _ body: [String: Any]) async throws -> Folder {
        let data = try await send(try request("/api/folders/\(id)", method: "PATCH", json: body))
        return try decoder.decode(Folder.self, from: data)
    }

    func createFolder(name: String, parent: Int?) async throws -> Folder {
        var body: [String: Any] = ["name": name]
        if let parent { body["parent_id"] = parent }
        let data = try await send(try request("/api/folders", method: "POST", json: body))
        return try decoder.decode(Folder.self, from: data)
    }

    struct UploadResult: Decodable {
        let imageId: Int
        let itemId: Int?
        let duplicate: Bool
    }

    /// 画像を元のデータのまま送る。本文は一時ファイルに書いてから送り、メモリを使いすぎないようにする。
    func upload(fileURL: URL, filename: String, folder: Int) async throws -> UploadResult {
        let boundary = "viewfans-\(UUID().uuidString)"
        let ext = (filename as NSString).pathExtension
        let safeName = filename.allSatisfy { $0.isASCII && $0 != "\"" } ? filename : "image.\(ext.isEmpty ? "jpg" : ext)"
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("body-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        do {
            try out.write(contentsOf: Data((
                "--\(boundary)\r\n" +
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n" +
                "Content-Type: application/octet-stream\r\n\r\n"
            ).utf8))
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try out.close()
        } catch {
            try? out.close()
            throw error
        }

        var req = try request("/api/folders/\(folder)/items", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let (data, resp) = try await session.upload(for: req, fromFile: bodyURL)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "応答が不正です") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(Detail.self, from: data))?.detail ?? "HTTP \(http.statusCode)"
            throw APIError(message: msg)
        }
        return try decoder.decode(UploadResult.self, from: data)
    }

    func patchItem(_ id: Int, crop: Crop) async throws {
        _ = try await send(try request("/api/items/\(id)", method: "PATCH",
                                       json: ["crop_x": crop.x, "crop_y": crop.y, "crop_zoom": crop.zoom]))
    }

    func moveItem(_ id: Int, toIndex: Int) async throws -> Folder {
        let data = try await send(try request("/api/items/\(id)/move", method: "POST", json: ["to_index": toIndex]))
        return try decoder.decode(Folder.self, from: data)
    }

    func moveFolder(_ id: Int, toIndex: Int) async throws {
        _ = try await send(try request("/api/folders/\(id)/move", method: "POST", json: ["to_index": toIndex]))
    }

    func sortChildren(parent: Int?, mode: String) async throws {
        var body: [String: Any] = ["mode": mode]
        if let parent { body["parent_id"] = parent }
        _ = try await send(try request("/api/folders/sort-children", method: "POST", json: body))
    }

    func trash() async throws -> TrashContents {
        try await get("/api/trash")
    }

    func restore(folders: [Int], items: [Int]) async throws {
        _ = try await send(try request("/api/trash/restore", method: "POST", json: ["folder_ids": folders, "item_ids": items]))
    }

    func purge(folders: [Int], items: [Int]) async throws {
        _ = try await send(try request("/api/trash/purge", method: "POST", json: ["folder_ids": folders, "item_ids": items]))
    }

    func emptyTrash() async throws {
        _ = try await send(try request("/api/trash/empty", method: "POST"))
    }

    func moveItems(_ ids: [Int], to folder: Int) async throws {
        _ = try await send(try request("/api/items/move-to", method: "POST", json: ["ids": ids, "folder_id": folder]))
    }

    func moveFolder(_ id: Int, toParent parent: Int?) async throws {
        let body: [String: Any] = ["parent_id": parent.map { $0 as Any } ?? NSNull()]
        _ = try await send(try request("/api/folders/\(id)/move-to", method: "POST", json: body))
    }

    func stats() async throws -> ServerStats {
        try await get("/api/stats")
    }

    func deleteItems(_ ids: [Int]) async throws {
        _ = try await send(try request("/api/items/delete", method: "POST", json: ["ids": ids]))
    }

    func deleteFolder(_ id: Int) async throws {
        _ = try await send(try request("/api/folders/\(id)", method: "DELETE"))
    }

    func setSort(_ folder: Int, mode: String) async throws -> Folder {
        let data = try await send(try request("/api/folders/\(folder)/sort", method: "POST", json: ["mode": mode]))
        return try decoder.decode(Folder.self, from: data)
    }

    func imageData(_ imageId: Int, variant: ImageVariant) async throws -> Data {
        try await send(try request("/api/images/\(imageId)/\(variant.rawValue)"))
    }
}

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.chen329.viewfans",
        kSecAttrAccount as String: "token",
    ]

    static func save(_ value: String) {
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
