import SwiftUI
import VisionKit
import ImageIO
import CoreImage

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
    @Published var ver = 0
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

    // 並び順どおりに 000001.jpg から振り直す(切り抜き前の元画像も同じ名前に合わせる)
    func renumber(_ order: [URL]) {
        let fm = FileManager.default
        for (i, u) in order.enumerated() {
            let b = origURL.appendingPathComponent(u.lastPathComponent)
            try? fm.moveItem(at: u, to: pagesURL.appendingPathComponent("t\(i).tmp"))
            if fm.fileExists(atPath: b.path) { try? fm.moveItem(at: b, to: origURL.appendingPathComponent("t\(i).tmp")) }
        }
        for i in 0..<order.count {
            let name = String(format: "%06d.jpg", i + 1)
            try? fm.moveItem(at: pagesURL.appendingPathComponent("t\(i).tmp"), to: pagesURL.appendingPathComponent(name))
            let tb = origURL.appendingPathComponent("t\(i).tmp")
            if fm.fileExists(atPath: tb.path) { try? fm.moveItem(at: tb, to: origURL.appendingPathComponent(name)) }
        }
        lastAdded = 0; pdf = nil; ver += 1
    }

    func undo() {
        for u in pageFiles().suffix(lastAdded) { try? FileManager.default.removeItem(at: u) }
        lastAdded = 0; count = pageFiles().count; status = "直前の撮影を削除しました"; pdf = nil
    }

    func clear() {
        try? FileManager.default.removeItem(at: origURL)
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

func thumb(_ url: URL, max: Int) -> UIImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

let origURL = pagesURL.appendingPathComponent("orig")

struct CropEditor: View {
    let url: URL
    let s: Store
    @Environment(\.dismiss) var dismiss
    @State var img: UIImage?
    @State var q: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    @State var startQ: [CGPoint] = []
    @State var grab = -1
    @State var hasBackup = false

    var backup: URL { origURL.appendingPathComponent(url.lastPathComponent) }

    func segDist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let l2 = abx * abx + aby * aby
        var t: CGFloat = l2 == 0 ? 0 : ((p.x - a.x) * abx + (p.y - a.y) * aby) / l2
        t = min(1, max(0, t))
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    func poly(_ v: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: v[0])
        for i in 1..<4 { path.addLine(to: v[i]) }
        path.closeSubpath()
        return path
    }

    // 0-3: 角(左上・右上・右下・左下) / 4-7: 辺(上・右・下・左) / 8: 全体の移動 / -2: 何も掴まない
    func pick(_ p: CGPoint, _ v: [CGPoint]) -> Int {
        var best = -2
        var bd: CGFloat = 44
        for i in 0..<4 {
            let d = hypot(p.x - v[i].x, p.y - v[i].y)
            if d < bd { bd = d; best = i }
        }
        if best >= 0 { return best }
        bd = 30
        for i in 0..<4 {
            let d = segDist(p, v[i], v[(i + 1) % 4])
            if d < bd { bd = d; best = 4 + i }
        }
        if best >= 0 { return best }
        return poly(v).contains(p) ? 8 : -2
    }

    func drag(_ val: DragGesture.Value, _ v: [CGPoint], _ dw: CGFloat, _ dh: CGFloat) {
        if grab == -1 { startQ = q; grab = pick(val.startLocation, v) }
        if grab < 0 || startQ.count != 4 { return }
        let dx = val.translation.width / dw
        let dy = val.translation.height / dh
        func cl(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
        var n = startQ
        switch grab {
        case 0...3:
            n[grab] = CGPoint(x: cl(startQ[grab].x + dx), y: cl(startQ[grab].y + dy))
        case 4:
            for i in [0, 1] { n[i].y = cl(startQ[i].y + dy) }
        case 5:
            for i in [1, 2] { n[i].x = cl(startQ[i].x + dx) }
        case 6:
            for i in [2, 3] { n[i].y = cl(startQ[i].y + dy) }
        case 7:
            for i in [3, 0] { n[i].x = cl(startQ[i].x + dx) }
        default:
            let xs = startQ.map { $0.x }, ys = startQ.map { $0.y }
            let ddx = min(max(dx, -(xs.min() ?? 0)), 1 - (xs.max() ?? 1))
            let ddy = min(max(dy, -(ys.min() ?? 0)), 1 - (ys.max() ?? 1))
            n = startQ.map { CGPoint(x: $0.x + ddx, y: $0.y + ddy) }
        }
        q = n
    }

    func apply() {
        guard let im = img, let cg = im.cgImage else { dismiss(); return }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let pts = q.map { CGPoint(x: $0.x * W, y: $0.y * H) }
        let axis = abs(pts[0].x - pts[3].x) < 0.5 && abs(pts[1].x - pts[2].x) < 0.5
            && abs(pts[0].y - pts[1].y) < 0.5 && abs(pts[3].y - pts[2].y) < 0.5
        var out: CGImage?
        if axis {
            let rect = CGRect(x: pts[0].x.rounded(), y: pts[0].y.rounded(),
                              width: (pts[1].x - pts[0].x).rounded(), height: (pts[3].y - pts[0].y).rounded())
            if rect.width < 20 || rect.height < 20 { return }
            out = cg.cropping(to: rect)
        } else if let f = CIFilter(name: "CIPerspectiveCorrection") {
            func cv(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: H - p.y) }
            f.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
            f.setValue(cv(pts[0]), forKey: "inputTopLeft")
            f.setValue(cv(pts[1]), forKey: "inputTopRight")
            f.setValue(cv(pts[2]), forKey: "inputBottomRight")
            f.setValue(cv(pts[3]), forKey: "inputBottomLeft")
            if let o = f.outputImage, o.extent.width >= 20, o.extent.height >= 20,
               let c = CIContext().createCGImage(o, from: o.extent) {
                out = grayScaled(c, long: 100000)?.0
            }
        }
        let q0 = UserDefaults.standard.integer(forKey: "q")
        guard let c = out,
              let d = UIImage(cgImage: c).jpegData(compressionQuality: CGFloat(q0 == 0 ? 70 : q0) / 100) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: origURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: url, to: backup) }
        try? d.write(to: url)
        s.ver += 1; s.pdf = nil
        dismiss()
    }

    func restore() {
        let fm = FileManager.default
        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: url)
            try? fm.copyItem(at: backup, to: url)
            try? fm.removeItem(at: backup)
        }
        s.ver += 1; s.pdf = nil
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                if hasBackup { Button("元に戻す") { restore() } }
                Spacer()
                Button("適用") { apply() }.bold()
            }
            .padding()
            .foregroundColor(.white)
            GeometryReader { g in
                if let im = img {
                    let sc = min(g.size.width / im.size.width, g.size.height / im.size.height)
                    let dw = im.size.width * sc
                    let dh = im.size.height * sc
                    let ox = (g.size.width - dw) / 2
                    let oy = (g.size.height - dh) / 2
                    let v = q.map { CGPoint(x: ox + $0.x * dw, y: oy + $0.y * dh) }
                    ZStack {
                        Image(uiImage: im).resizable().frame(width: dw, height: dh).position(x: ox + dw / 2, y: oy + dh / 2)
                        Path { p in
                            p.addRect(CGRect(x: ox, y: oy, width: dw, height: dh))
                            p.addPath(poly(v))
                        }
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        poly(v).stroke(Color.yellow, lineWidth: 2)
                        ForEach(0..<4, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3).fill(Color.yellow).frame(width: 14, height: 14)
                                .position(x: (v[i].x + v[(i + 1) % 4].x) / 2, y: (v[i].y + v[(i + 1) % 4].y) / 2)
                        }
                        ForEach(0..<4, id: \.self) { i in
                            Circle().fill(Color.yellow).frame(width: 20, height: 20).position(v[i])
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { val in drag(val, v, dw, dh) }
                        .onEnded { _ in grab = -1 })
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            img = UIImage(contentsOfFile: url.path)
            hasBackup = FileManager.default.fileExists(atPath: backup.path)
        }
    }
}

struct Idx: Identifiable { let id: Int }

struct Thumb: View {
    let url: URL
    @State var img: UIImage?
    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let i = img { Image(uiImage: i).resizable().scaledToFit() }
        }
        .aspectRatio(0.72, contentMode: .fit)
        .task { img = await Task.detached { thumb(url, max: 300) }.value }
    }
}

final class ZScroll: UIScrollView {
    let iv = UIImageView()
    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 { iv.frame = bounds }
    }
}

struct ZoomPage: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coord { Coord() }
    func makeUIView(context: Context) -> ZScroll {
        let sv = ZScroll()
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 5
        sv.delegate = context.coordinator
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.iv.contentMode = .scaleAspectFit
        sv.addSubview(sv.iv)
        context.coordinator.iv = sv.iv
        let iv = sv.iv
        DispatchQueue.global(qos: .userInitiated).async {
            let im = UIImage(contentsOfFile: url.path)
            DispatchQueue.main.async { iv.image = im }
        }
        return sv
    }
    func updateUIView(_ v: ZScroll, context: Context) {}
    final class Coord: NSObject, UIScrollViewDelegate {
        var iv: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { iv }
    }
}

struct Pager: View {
    @Binding var files: [URL]
    @State var idx: Int
    @ObservedObject var s: Store
    @Environment(\.dismiss) var dismiss
    @State var confirm = false
    @State var editing = false

    init(files: Binding<[URL]>, start: Int, s: Store) {
        _files = files
        _idx = State(initialValue: start)
        self.s = s
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $idx) {
                ForEach(Array(files.enumerated()), id: \.element) { i, f in
                    ZoomPage(url: f).id("\(f.lastPathComponent)-\(s.ver)").tag(i).ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            HStack {
                Button("閉じる") { dismiss() }
                Spacer()
                Text("\(idx + 1) / \(files.count)")
                Spacer()
                Button { editing = true } label: { Image(systemName: "crop") }
                    .padding(.trailing, 16)
                Button(role: .destructive) { confirm = true } label: { Image(systemName: "trash") }
            }
            .padding()
            .background(Color.black.opacity(0.5))
            .foregroundColor(.white)
        }
        .fullScreenCover(isPresented: $editing) {
            if idx < files.count { CropEditor(url: files[idx], s: s) }
        }
        .confirmationDialog("このページを削除しますか", isPresented: $confirm) {
            Button("削除", role: .destructive) { remove() }
        }
    }

    func remove() {
        guard idx < files.count else { return }
        try? FileManager.default.removeItem(at: origURL.appendingPathComponent(files[idx].lastPathComponent))
        try? FileManager.default.removeItem(at: files[idx])
        files.remove(at: idx)
        s.count = pageFiles().count
        s.lastAdded = 0
        s.pdf = nil
        idx = min(idx, max(0, files.count - 1))
        if files.isEmpty { dismiss() }
    }
}

struct PreviewView: View {
    @ObservedObject var s: Store
    @Environment(\.dismiss) var dismiss
    @State var files = pageFiles()
    @State var open: Idx?
    @State var selecting = false
    @State var sel = Set<URL>()
    @State var moving = false
    @State var rangeMode = false
    @State var lastTap: Int?
    @State var confirmDel = false

    func tap(_ i: Int, _ f: URL) {
        if moving { moveSel(before: f); return }
        if selecting {
            if rangeMode, let l = lastTap {
                for k in min(l, i)...max(l, i) where k < files.count { sel.insert(files[k]) }
            } else if sel.contains(f) {
                sel.remove(f)
            } else {
                sel.insert(f)
            }
            lastTap = i
        } else {
            open = Idx(id: i)
        }
    }

    // 選択したページを、target の直前へ(nil なら末尾へ)移動する
    func moveSel(before target: URL?) {
        if sel.isEmpty { moving = false; return }
        if let t = target, sel.contains(t) { return }
        let picked = files.filter { sel.contains($0) }
        var rest = files.filter { !sel.contains($0) }
        if let t = target, let k = rest.firstIndex(of: t) {
            rest.insert(contentsOf: picked, at: k)
        } else {
            rest.append(contentsOf: picked)
        }
        s.renumber(rest)
        files = pageFiles()
        sel = []; lastTap = nil; moving = false
    }

    func deleteSel() {
        let fm = FileManager.default
        for u in sel {
            try? fm.removeItem(at: origURL.appendingPathComponent(u.lastPathComponent))
            try? fm.removeItem(at: u)
        }
        files = pageFiles()
        s.count = files.count; s.lastAdded = 0; s.pdf = nil
        sel = []; lastTap = nil
    }

    func cell(_ i: Int, _ f: URL) -> some View {
        let on = sel.contains(f)
        return Thumb(url: f)
            .id("\(f.lastPathComponent)-\(s.ver)")
            .overlay(alignment: .bottomTrailing) {
                Text("\(i + 1)").font(.caption2).padding(3)
                    .background(Color.black.opacity(0.6)).foregroundColor(.white)
            }
            .overlay(alignment: .topLeading) {
                if selecting {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(on ? .blue : .white).padding(4).shadow(radius: 2)
                }
            }
            .overlay(Rectangle().stroke(Color.blue, lineWidth: on ? 3 : 0))
            .onTapGesture { tap(i, f) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if moving {
                    HStack {
                        Text("移動先のページをタップ(その直前に入ります)").font(.footnote)
                        Spacer()
                        Button("末尾へ") { moveSel(before: nil) }
                        Button("取消") { moving = false }
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.3))
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
                        ForEach(Array(files.enumerated()), id: \.element) { i, f in
                            cell(i, f)
                        }
                    }
                    .padding(6)
                }
            }
            .navigationTitle(selecting ? "\(sel.count) / \(files.count) 選択" : "\(files.count) ページ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selecting ? "完了" : "選択") {
                        selecting.toggle()
                        if !selecting { sel = []; moving = false; rangeMode = false; lastTap = nil }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if selecting {
                        Button("全選択") { sel = Set(files) }
                        Button(rangeMode ? "範囲:オン" : "範囲") { rangeMode.toggle() }
                        Spacer()
                        Button("移動") { moving = true }.disabled(sel.isEmpty)
                        Button("削除(\(sel.count))", role: .destructive) { confirmDel = true }.disabled(sel.isEmpty)
                    }
                }
            }
            .confirmationDialog("選択した\(sel.count)ページを削除しますか", isPresented: $confirmDel) {
                Button("削除", role: .destructive) { deleteSel() }
            }
        }
        .fullScreenCover(item: $open) { o in Pager(files: $files, start: o.id, s: s) }
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
    @State var showPreview = false
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
                Button("プレビュー") { showPreview = true }.disabled(s.busy || s.count == 0)
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
        .sheet(isPresented: $showPreview) { PreviewView(s: s) }
        .confirmationDialog("全ページを消去しますか", isPresented: $confirmClear) {
            Button("消去", role: .destructive) { s.clear() }
        }
    }
}
