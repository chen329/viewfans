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
