import SwiftUI

/// タイルに映る範囲の調整。枠の中で画像を指で動かし、ピンチで拡大率を変える。
struct CropEditor: View {
    let item: Item
    let onSaved: (Crop) -> Void

    @State private var crop: Crop
    @State private var start: Crop?
    @State private var image: UIImage?
    @State private var saving = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(item: Item, onSaved: @escaping (Crop) -> Void) {
        self.item = item
        self.onSaved = onSaved
        _crop = State(initialValue: Crop(item))
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 40, geo.size.height - 160, 640)
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                ZStack(alignment: .topLeading) {
                    Color(white: 0.1)
                    if let image {
                        let l = crop.layout(imageSize: image.size, side: side)
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: l.size.width, height: l.size.height)
                            .offset(x: l.origin.x, y: l.origin.y)
                    } else {
                        ProgressView().frame(width: side, height: side)
                    }
                }
                .frame(width: side, height: side)
                .clipped()
                .overlay(Rectangle().stroke(.white.opacity(0.6), lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(drag(side: side).simultaneously(with: magnify))

                VStack(spacing: 6) {
                    Slider(value: $crop.zoom, in: 1...8)
                    Text("拡大率 \(crop.zoom, specifier: "%.1f") 倍")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: side)
                if let errorText { Text(errorText).foregroundStyle(.red).font(.footnote) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
        .navigationTitle("表示位置を調整")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .principal) {
                Button("中央に戻す") { withAnimation { crop = Crop() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }.disabled(saving)
            }
        }
        .task {
            image = await ImageStore.shared.image(id: item.imageId, variant: .medium, maxPixel: 1600)
        }
    }

    /// 指を動かした方向に画像が動くよう、中心位置を逆向きにずらす。
    private func drag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard let image else { return }
                let base = start ?? crop
                if start == nil { start = crop }
                let size = base.layout(imageSize: image.size, side: side).size
                var next = crop
                next.x = clamp(base.x - Double(v.translation.width / size.width), half: Double(side / size.width) / 2)
                next.y = clamp(base.y - Double(v.translation.height / size.height), half: Double(side / size.height) / 2)
                crop = next
            }
            .onEnded { _ in start = nil }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let base = start ?? crop
                if start == nil { start = crop }
                crop.zoom = min(max(base.zoom * v.magnification, 1), 8)
            }
            .onEnded { _ in start = nil }
    }

    /// 枠が画像の外にはみ出さない範囲に収める。
    private func clamp(_ v: Double, half: Double) -> Double {
        min(max(v, half), 1 - half)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await API.shared.patchItem(item.id, crop: crop)
            onSaved(crop)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
