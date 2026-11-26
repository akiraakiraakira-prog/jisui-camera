import SwiftUI
import VisionKit

@main
struct JisuiApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let pagesURL: URL = {
    let u = docsURL.appendingPathComponent("pages")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

func pageFiles() -> [URL] {
    let fs = (try? FileManager.default.contentsOfDirectory(at: pagesURL, includingPropertiesForKeys: nil)) ?? []
    return fs.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func median(_ a: [Double]) -> Double {
    if a.count < 3 { return 0 }
    return a.sorted()[a.count / 2]
}

// 鮮明度(ラプラシアン分散)。値そのものではなく、直近ページとの相対比較に使う
func sharpness(_ a: [UInt8], _ w: Int, _ h: Int) -> Double {
    let st = max(1, Int((Double(max(w, h)) / 800).rounded()))
    var n = 0.0, s = 0.0, s2 = 0.0
    var y = st
    while y < h - st {
        var x = st
        while x < w - st {
            let i = y * w + x
            let l = 4 * Int(a[i]) - Int(a[i - st]) - Int(a[i + st]) - Int(a[i - st * w]) - Int(a[i + st * w])
            let d = Double(l)
            n += 1; s += d; s2 += d * d
            x += st
        }
        y += st
    }
    return n > 0 ? s2 / n - (s / n) * (s / n) : 0
}

func grayScaled(_ cg: CGImage, long: Int) -> (CGImage, [UInt8], Int, Int)? {
    let k = min(1.0, Double(long) / Double(max(cg.width, cg.height)))
    let w = max(1, Int(Double(cg.width) * k)), h = max(1, Int(Double(cg.height) * k))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let out = ctx.makeImage(), let p = ctx.data else { return nil }
    let buf = UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: w * h)
    return (out, Array(buf), w, h)
}

// JPEGヘッダから (幅, 高さ, 成分数) を読む
func jpegInfo(_ d: Data) -> (Int, Int, Int)? {
    let b = [UInt8](d)
    var i = 2
    while i + 9 < b.count {
        if b[i] != 0xFF { i += 1; continue }
        let m = b[i + 1]
        if m == 0xC0 || m == 0xC1 || m == 0xC2 {
            let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
            let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
            return (w, h, Int(b[i + 9]))
        }
        let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
        i += 2 + len
    }
    return nil
}

// JPEGを再エンコードせずそのままPDFに埋め込む
func makePDF(_ files: [URL]) -> Data? {
    var out = Data()
    var xs = [Int: Int]()
    func put(_ s: String) { out.append(s.data(using: .ascii)!) }
    func obj(_ id: Int, _ body: String) { xs[id] = out.count; put("\(id) 0 obj\n\(body)\nendobj\n") }
    put("%PDF-1.4\n")
    let n = files.count
    obj(1, "<</Type/Catalog/Pages 2 0 R>>")
    obj(2, "<</Type/Pages/Count \(n)/Kids[" + (0..<n).map { "\(3 + 3 * $0) 0 R" }.joined(separator: " ") + "]>>")
    for (i, f) in files.enumerated() {
        guard let d = try? Data(contentsOf: f), let info = jpegInfo(d) else { return nil }
        let id = 3 + 3 * i
        let w = String(format: "%.2f", Double(info.0) * 0.24), h = String(format: "%.2f", Double(info.1) * 0.24)
        let cs = "q \(w) 0 0 \(h) 0 0 cm /I Do Q"
        let space = info.2 == 1 ? "/DeviceGray" : "/DeviceRGB"
        obj(id, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 \(w) \(h)]/Resources<</XObject<</I \(id + 2) 0 R>>>>/Contents \(id + 1) 0 R>>")
        obj(id + 1, "<</Length \(cs.count)>>\nstream\n\(cs)\nendstream")
        xs[id + 2] = out.count
        put("\(id + 2) 0 obj\n<</Type/XObject/Subtype/Image/Width \(info.0)/Height \(info.1)/ColorSpace\(space)/BitsPerComponent 8/Filter/DCTDecode/Length \(d.count)>>\nstream\n")
        out.append(d)
        put("\nendstream\nendobj\n")
    }
    let total = 3 * n + 3, xo = out.count
    var x = "xref\n0 \(total)\n0000000000 65535 f \n"
    for i in 1..<total { x += String(format: "%010d", xs[i] ?? 0) + " 00000 n \n" }
    put(x + "trailer\n<</Size \(total)/Root 1 0 R>>\nstartxref\n\(xo)\n%%EOF")
    return out
}

final class Store: ObservableObject {
    @Published var count = pageFiles().count
    @Published var status = ""
    @Published var busy = false
    @Published var pdf: URL?
    var lastAdded = 0
    var recent: [Double] = []

    func ingest(_ scan: VNDocumentCameraScan, spread: Bool, rtl: Bool, cut: Double, long: Int, q: Int) {
        busy = true; status = "処理中…"; pdf = nil
        let base = median(recent)
        var next = (pageFiles().last.flatMap { Int($0.deletingPathExtension().lastPathComponent) } ?? 0) + 1
        DispatchQueue.global(qos: .userInitiated).async {
            var added = 0, low = false
            var scores: [Double] = []
            for i in 0..<scan.pageCount {
                autoreleasepool {
                    guard let cg = scan.imageOfPage(at: i).cgImage else { return }
                    var parts = [cg]
                    if spread {
                        let cx = Int(Double(cg.width) * cut / 100)
                        if let l = cg.cropping(to: CGRect(x: 0, y: 0, width: cx, height: cg.height)),
                           let r = cg.cropping(to: CGRect(x: cx, y: 0, width: cg.width - cx, height: cg.height)) {
                            parts = rtl ? [r, l] : [l, r]
                        }
                    }
                    for p in parts {
                        guard let t = grayScaled(p, long: long) else { continue }
                        let s = sharpness(t.1, t.2, t.3)
                        if base > 0 && s < base * 0.5 { low = true }
                        scores.append(s)
                        guard let jpg = UIImage(cgImage: t.0).jpegData(compressionQuality: CGFloat(q) / 100) else { continue }
                        let u = pagesURL.appendingPathComponent(String(format: "%06d.jpg", next))
                        if (try? jpg.write(to: u)) != nil { next += 1; added += 1 }
                    }
                }
            }
            DispatchQueue.main.async {
                self.recent = Array((self.recent + scores).suffix(10))
                self.lastAdded = added
                self.count = pageFiles().count
                self.busy = false
                self.status = low ? "ブレている可能性があります。「直前を削除」で撮り直してください" : "\(added) ページ追加"
            }
        }
    }

    func undo() {
        for u in pageFiles().suffix(lastAdded) { try? FileManager.default.removeItem(at: u) }
        lastAdded = 0; count = pageFiles().count; status = "直前の撮影を削除しました"; pdf = nil
    }

    func clear() {
        for u in pageFiles() { try? FileManager.default.removeItem(at: u) }
        lastAdded = 0; recent = []; count = 0; status = "全消去しました"; pdf = nil
    }

    func export(name: String) {
        busy = true; status = "PDFを作成中…"
        let n = (name.isEmpty ? "scan" : name).replacingOccurrences(of: "/", with: "-")
        DispatchQueue.global(qos: .userInitiated).async {
            let files = pageFiles()
            let url = docsURL.appendingPathComponent(n + ".pdf")
            var ok = false, mb = 0.0
            if let d = makePDF(files), (try? d.write(to: url)) != nil { ok = true; mb = Double(d.count) / 1048576 }
            DispatchQueue.main.async {
                self.busy = false
                self.pdf = ok ? url : nil
                self.status = ok ? "\(files.count) ページ / " + String(format: "%.1f", mb) + " MB" : "PDFの作成に失敗しました"
            }
        }
    }
}

struct Scanner: UIViewControllerRepresentable {
    let done: (VNDocumentCameraScan?) -> Void
    func makeCoordinator() -> Coord { Coord(done) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let v = VNDocumentCameraViewController()
        v.delegate = context.coordinator
        return v
    }
    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    final class Coord: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: (VNDocumentCameraScan?) -> Void
        init(_ d: @escaping (VNDocumentCameraScan?) -> Void) { done = d }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) { done(scan) }
        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) { done(nil) }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFailWithError error: Error) { done(nil) }
    }
}

struct ContentView: View {
    @StateObject var s = Store()
    @AppStorage("spread") var spread = true
    @AppStorage("rtl") var rtl = true
    @AppStorage("long") var long = 2000
    @AppStorage("q") var q = 70
    @AppStorage("cut") var cut = 50.0
    @State var showScanner = false
    @State var confirmClear = false
    @State var name = ""

    var body: some View {
        Form {
            Section {
                Button { showScanner = true } label: {
                    Text("撮影").font(.title.bold()).frame(maxWidth: .infinity).padding(.vertical, 18)
                }.disabled(s.busy)
                Text("\(s.count) ページ")
                if !s.status.isEmpty { Text(s.status) }
            }
            Section("設定") {
                Toggle("見開きを左右に分割", isOn: $spread)
                Toggle("右開き(和書)", isOn: $rtl)
                Picker("長辺 px", selection: $long) { ForEach([1600, 2000, 2400], id: \.self) { Text("\($0)").tag($0) } }
                Picker("JPEG 品質", selection: $q) { ForEach([60, 70, 80], id: \.self) { Text("\($0)").tag($0) } }
                VStack(alignment: .leading) {
                    Text("分割位置 \(Int(cut))%")
                    Slider(value: $cut, in: 40...60, step: 1)
                }
            }
            Section {
                Button("直前を削除") { s.undo() }.disabled(s.busy || s.lastAdded == 0)
                Button("全消去", role: .destructive) { confirmClear = true }.disabled(s.busy)
                TextField("ファイル名(例: 全集第3巻)", text: $name)
                Button("PDF書き出し") { s.export(name: name) }.disabled(s.busy || s.count == 0)
                if let u = s.pdf { ShareLink(item: u) }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            Scanner { scan in
                showScanner = false
                if let scan = scan { s.ingest(scan, spread: spread, rtl: rtl, cut: cut, long: long, q: q) }
            }.ignoresSafeArea()
        }
        .confirmationDialog("全ページを消去しますか", isPresented: $confirmClear) {
            Button("消去", role: .destructive) { s.clear() }
        }
    }
}
