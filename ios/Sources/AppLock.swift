import CryptoKit
import SwiftUI

/// PIN を求めるタイミング。
enum LockInterval: Int, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600
    case launchOnly = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .immediately: return "毎回(ほかのアプリに切り替えるたび)"
        case .oneMinute: return "1分後"
        case .fiveMinutes: return "5分後"
        case .fifteenMinutes: return "15分後"
        case .oneHour: return "1時間後"
        case .launchOnly: return "アプリの起動時だけ"
        }
    }
}

/// 起動時ロック(PIN)。PIN はソルト付きのハッシュでキーチェーンに保存する。
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    private(set) var isEnabled: Bool
    var locked: Bool
    var interval: LockInterval {
        didSet { UserDefaults.standard.set(interval.rawValue, forKey: "lock.interval") }
    }
    private(set) var pinLength: Int
    private(set) var failures = 0
    private(set) var retryAt: Date?
    private var backgroundedAt: Date?

    private init() {
        let enabled = Keychain.load(account: "pin") != nil
        isEnabled = enabled
        locked = enabled
        interval = LockInterval(rawValue: UserDefaults.standard.integer(forKey: "lock.interval")) ?? .immediately
        pinLength = max(4, UserDefaults.standard.integer(forKey: "lock.length"))
    }

    // MARK: - タイミング

    func didEnterBackground() {
        if !locked { backgroundedAt = Date() }
    }

    func didBecomeActive() {
        guard isEnabled, !locked, let t = backgroundedAt else { return }
        backgroundedAt = nil
        if interval == .launchOnly { return }
        if Date().timeIntervalSince(t) >= Double(interval.rawValue) { locked = true }
    }

    // MARK: - PIN

    private static func hash(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func setPIN(_ pin: String) {
        let salt = UUID().uuidString
        Keychain.save(salt + ":" + Self.hash(pin, salt: salt), account: "pin")
        UserDefaults.standard.set(pin.count, forKey: "lock.length")
        pinLength = pin.count
        isEnabled = true
        failures = 0
        retryAt = nil
    }

    func removePIN() {
        Keychain.delete(account: "pin")
        isEnabled = false
        locked = false
        failures = 0
        retryAt = nil
    }

    /// 5回続けて間違えると30秒待ち。
    func unlock(_ pin: String) -> Bool {
        if let retryAt, retryAt > Date() { return false }
        guard let stored = Keychain.load(account: "pin"), let sep = stored.firstIndex(of: ":") else {
            locked = false
            return true
        }
        let salt = String(stored[..<sep])
        if Self.hash(pin, salt: salt) == String(stored[stored.index(after: sep)...]) {
            locked = false
            failures = 0
            retryAt = nil
            return true
        }
        failures += 1
        if failures % 5 == 0 { retryAt = Date().addingTimeInterval(30) }
        return false
    }

    /// PIN を忘れたとき: サーバーのトークンを入力できれば PIN を解除する。
    func resetWithToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.trimmingCharacters(in: .whitespacesAndNewlines) == API.shared.token else { return false }
        removePIN()
        return true
    }
}

// MARK: - 画面

/// 数字キー。
struct PinPad: View {
    @Binding var digits: String
    let maxLength: Int

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 76, height: 76)
                        } else {
                            Button {
                                if key == "⌫" {
                                    if !digits.isEmpty { digits.removeLast() }
                                } else if digits.count < maxLength {
                                    digits.append(key)
                                }
                            } label: {
                                Text(key == "⌫" ? "" : key)
                                    .font(.system(size: 30))
                                    .frame(width: 76, height: 76)
                                    .background(key == "⌫" ? Color.clear : Color(white: 0.18), in: Circle())
                                    .overlay { if key == "⌫" { Image(systemName: "delete.left").font(.title2) } }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct PinDots: View {
    let count: Int
    let filled: Int

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .strokeBorder(.white, lineWidth: 1.5)
                    .background(Circle().fill(i < filled ? Color.white : Color.clear))
                    .frame(width: 14, height: 14)
            }
        }
    }
}

struct LockScreen: View {
    @State private var lock = AppLock.shared
    @State private var digits = ""
    @State private var shake = false
    @State private var showForgot = false
    @State private var token = ""
    @State private var forgotError: String?
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var waiting: Int {
        guard let r = lock.retryAt else { return 0 }
        return max(0, Int(r.timeIntervalSince(now).rounded(.up)))
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("View Fans").font(.title2.weight(.semibold))
            Text(waiting > 0 ? "\(waiting) 秒後にもう一度入力できます" : "PIN を入力")
                .foregroundStyle(.secondary)
            PinDots(count: lock.pinLength, filled: digits.count)
                .offset(x: shake ? 12 : 0)
            PinPad(digits: $digits, maxLength: lock.pinLength)
                .disabled(waiting > 0)
                .opacity(waiting > 0 ? 0.4 : 1)
            Button("PIN を忘れた場合") { showForgot = true }
                .font(.footnote)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onReceive(timer) { now = $0 }
        .onChange(of: digits) { _, value in
            guard value.count == lock.pinLength else { return }
            if !lock.unlock(value) {
                withAnimation(.default.repeatCount(3, autoreverses: true).speed(4)) { shake = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    shake = false
                    digits = ""
                }
            } else {
                digits = ""
            }
        }
        .alert("PIN を忘れた場合", isPresented: $showForgot) {
            SecureField("サーバーのトークン", text: $token)
            Button("PIN を解除") {
                if !lock.resetWithToken(token) { forgotError = "トークンが違います" }
                token = ""
            }
            Button("キャンセル", role: .cancel) { token = "" }
        } message: {
            Text("接続に使っているトークンを入力すると、PIN を解除できます。")
        }
        .alert(forgotError ?? "", isPresented: Binding(get: { forgotError != nil }, set: { if !$0 { forgotError = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

/// PIN の設定・変更(2回入力して確かめる)。
struct PinSetupView: View {
    @State private var first: String?
    @State private var digits = ""
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text(first == nil ? "新しい PIN(4〜8桁)" : "もう一度入力")
                .font(.headline)
            if let message { Text(message).font(.footnote).foregroundStyle(.red) }
            PinDots(count: max(4, first?.count ?? max(4, digits.count)), filled: digits.count)
            PinPad(digits: $digits, maxLength: first?.count ?? 8)
            Button(first == nil ? "次へ" : "設定") { next() }
                .buttonStyle(.borderedProminent)
                .disabled(digits.count < 4 || (first != nil && digits.count != first?.count))
        }
        .padding()
        .navigationTitle("PIN の設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
        }
    }

    private func next() {
        if let first {
            if digits == first {
                AppLock.shared.setPIN(digits)
                dismiss()
            } else {
                message = "一致しません。最初からやり直してください"
                self.first = nil
                digits = ""
            }
        } else {
            first = digits
            digits = ""
            message = nil
        }
    }
}

/// 設定画面の「ロック」。
struct LockSettingsView: View {
    @State private var lock = AppLock.shared
    @State private var showSetup = false
    @State private var confirmOff = false

    var body: some View {
        Form {
            Section {
                if lock.isEnabled {
                    Button("PIN を変更") { showSetup = true }
                    Button("PIN をオフにする", role: .destructive) { confirmOff = true }
                } else {
                    Button("PIN を設定") { showSetup = true }
                }
            } footer: {
                Text("PIN を忘れたときは、ロック画面の「PIN を忘れた場合」で接続用のトークンを入力すると解除できます。")
            }
            if lock.isEnabled {
                Section("PIN を求めるタイミング") {
                    Picker("PIN を求めるタイミング", selection: $lock.interval) {
                        ForEach(LockInterval.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
        .navigationTitle("ロック")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSetup) {
            NavigationStack { PinSetupView() }
        }
        .confirmationDialog("PIN をオフにしますか?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("オフにする", role: .destructive) { lock.removePIN() }
        }
    }
}
