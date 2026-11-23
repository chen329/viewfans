import SwiftUI
import UIKit

/// M3 の事前確認用。共有拡張が無料 Apple ID で動くか、App Group で本体と値を共有できるかを表示する。
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let inputs = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let count = inputs.reduce(0) { $0 + ($1.attachments?.count ?? 0) }
        let shared = UserDefaults(suiteName: "group.com.chen329.viewfans")?.string(forKey: "probe")
        let probe = ProbeView(count: count, shared: shared) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: probe)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ProbeView: View {
    let count: Int
    let shared: String?
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("受け取った画像", value: "\(count) 枚")
                LabeledContent("App Group", value: shared == nil ? "読めません" : "読めました")
                if let shared {
                    Text(shared).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("View Fans 共有テスト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる", action: onClose) }
            }
        }
        .preferredColorScheme(.dark)
    }
}
