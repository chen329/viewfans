import SwiftUI
import UIKit

/// 全画面の拡大表示。左右で前後、ダブルタップで拡大、下スワイプで閉じる、タップで操作ボタンの表示切り替え。
struct PhotoViewer: View {
    let items: [Item]
    @State private var index: Int
    @State private var showChrome = true
    @Environment(\.dismiss) private var dismiss

    init(items: [Item], start: Int) {
        self.items = items
        _index = State(initialValue: start)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(items.indices, id: \.self) { i in
                    ZoomablePhoto(item: items[i], onTap: { showChrome.toggle() }, onSwipeDown: { dismiss() })
                        .tag(i)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showChrome {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .tint(.white)
                    Spacer()
                    Text("\(index + 1) / \(items.count)")
                        .font(.footnote)
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showChrome)
        .statusBarHidden(!showChrome)
        .persistentSystemOverlays(showChrome ? .automatic : .hidden)
    }
}

/// 中間サイズを先に出し、元画像が届いたら差し替える。
struct ZoomablePhoto: View {
    let item: Item
    let onTap: () -> Void
    let onSwipeDown: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZoomableImageView(image: image, onTap: onTap, onSwipeDown: onSwipeDown)
            .overlay {
                if image == nil {
                    if failed {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .task(id: item.id) {
                if let m = await ImageStore.shared.image(id: item.imageId, variant: .medium, maxPixel: 1600) {
                    image = m
                }
                if Task.isCancelled { return }
                if let o = await ImageStore.shared.image(id: item.imageId, variant: .original, maxPixel: 4096) {
                    image = o
                } else if image == nil {
                    failed = true
                }
            }
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    let onTap: () -> Void
    let onSwipeDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let v = ZoomScrollView()
        v.delegate = context.coordinator

        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        v.addGestureRecognizer(double)

        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        v.addGestureRecognizer(single)

        let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeDown(_:)))
        swipe.direction = .down
        swipe.delegate = context.coordinator
        v.addGestureRecognizer(swipe)
        return v
    }

    func updateUIView(_ v: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
        v.setImage(image)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImageView

        init(_ parent: ZoomableImageView) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centerImage()
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? ZoomScrollView else { return }
            if sv.zoomScale > sv.minimumZoomScale + 0.01 {
                sv.setZoomScale(sv.minimumZoomScale, animated: true)
            } else {
                let point = g.location(in: sv.imageView)
                let scale = min(sv.maximumZoomScale, 3)
                let size = CGSize(width: sv.bounds.width / scale, height: sv.bounds.height / scale)
                sv.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
            }
        }

        @objc func singleTap() { parent.onTap() }

        @objc func swipeDown(_ g: UISwipeGestureRecognizer) {
            guard let sv = g.view as? ZoomScrollView, sv.zoomScale <= sv.minimumZoomScale + 0.01 else { return }
            parent.onSwipeDown()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ img: UIImage?) {
        guard imageView.image !== img else { return }
        if let old = imageView.image, let img, abs(old.size.width / old.size.height - img.size.width / img.size.height) < 0.01 {
            // 中間サイズ → 元画像の差し替えでは、拡大位置を保ったまま画像だけ替える
            imageView.image = img
            return
        }
        imageView.image = img
        layoutImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            layoutImage()
        }
    }

    private func layoutImage() {
        guard let img = imageView.image, bounds.width > 0, bounds.height > 0, img.size.width > 0, img.size.height > 0 else { return }
        zoomScale = 1
        let fit = min(bounds.width / img.size.width, bounds.height / img.size.height)
        let size = CGSize(width: img.size.width * fit, height: img.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        minimumZoomScale = 1
        maximumZoomScale = 6
        centerImage()
    }

    func centerImage() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }
}
