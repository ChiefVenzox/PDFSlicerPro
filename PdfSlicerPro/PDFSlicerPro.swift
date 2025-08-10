import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - PDF Slicer Pro (macOS 13+)
// Tek dosyalık SwiftUI uygulama – Inspector kaldırıldı.
// Üst bar artık SEKME bazlı ve satıra kırılıyor.
// Özellikler:
// - Çoklu PDF ekleme, sıralama, kaldırma
// - Sayfa seçimi (Select All / None / Invert, aralık: 1-3,5,10-12)
// - Sayfa sil, seçili sayfaları dışa aktar, tümünü birleştir
// - Her N sayfada böl (split)
// - Rasterize + JPEG sıkıştırma (DPI + kalite)
// - Export Folder (toplu çıktı için Save Panel istemez)
// - Thumbnail zoom ve hover efekti
// - Arka plan animasyonu & tema ayarı **View** sekmesinde

@main
struct PDFSlicerProApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.titleBar)
    }
}

// MARK: - Background Styles & Theme
enum BGStyle: String, CaseIterable, Identifiable { case gradient = "Gradient", waves = "Waves", particles = "Particles"; var id: String { rawValue } }
enum ThemeSetting: String, CaseIterable, Identifiable { case system = "System", light = "Light", dark = "Dark"; var id: String { rawValue }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

// 1) Soft flowing gradient
struct GradientBackground: View { @State private var phase: CGFloat = 0; var body: some View {
    TimelineView(.animation) { _ in ZStack {
        AngularGradient(gradient: Gradient(colors: [
            Color(red: 0.12, green: 0.28, blue: 0.85),
            Color(red: 0.56, green: 0.17, blue: 0.90),
            Color(red: 0.98, green: 0.25, blue: 0.56),
            Color(red: 0.99, green: 0.59, blue: 0.24),
            Color(red: 0.12, green: 0.28, blue: 0.85)
        ]), center: .center)
        .hueRotation(.degrees(Double(phase.truncatingRemainder(dividingBy: 360))))
        .saturation(0.75)
        .blur(radius: 80)
        .opacity(0.26)
        .animation(.linear(duration: 18).repeatForever(autoreverses: false), value: phase)
        .onAppear { phase = 360 }
        LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }.ignoresSafeArea() }
}}

// 2) Wavy bands using Canvas
struct WavesBackground: View { @State private var t: CGFloat = 0; var body: some View {
    TimelineView(.animation) { _ in
        Canvas { ctx, size in
            let w = size.width, h = size.height
            for i in 0..<3 {
                var path = Path()
                let baseY = h * (0.25 + CGFloat(i) * 0.22)
                let amp = CGFloat(20 + i * 14)
                let freq = CGFloat(1.5 + Double(i) * 0.6)
                let phase = t + CGFloat(i) * 0.9
                path.move(to: CGPoint(x: 0, y: baseY))
                stride(from: 0.0, through: Double(w), by: 6).forEach { dx in
                    let x = CGFloat(dx)
                    let y = baseY + sin((x / w) * freq * 2 * .pi + phase) * amp
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
                let c1 = Color.blue.opacity(0.12 - Double(i) * 0.03)
                let c2 = Color.purple.opacity(0.08 - Double(i) * 0.02)
                ctx.fill(path, with: .linearGradient(Gradient(colors: [c1, c2]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            }
        }
        .opacity(0.5)
        .onAppear { withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { t = 2 * .pi } }
        .ignoresSafeArea()
    }
}}

// 3) Floating particles using deterministic orbits
struct ParticlesBackground: View { @State private var t: Double = 0; var body: some View {
    TimelineView(.animation) { _ in
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let count = 48
            for i in 0..<count {
                let fi = Double(i)
                let r = 30.0 + (fi.truncatingRemainder(dividingBy: 6)) * 10.0
                let speed = 0.2 + (fi.truncatingRemainder(dividingBy: 7)) * 0.03
                let cx = w * 0.5 + CGFloat(cos(t * speed + fi) * (w * 0.35))
                let cy = h * 0.5 + CGFloat(sin(t * speed + fi * 1.3) * (h * 0.35))
                let rect = CGRect(x: cx - r * 0.5, y: cy - r * 0.5, width: r, height: r)
                let alpha = 0.06 + (fi.truncatingRemainder(dividingBy: 5)) * 0.01
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [
                    Color.white.opacity(alpha), Color.white.opacity(0.0)
                ]), center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
            }
        }
        .blendMode(.plusLighter)
        .onAppear { withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { t = 1000 } }
        .ignoresSafeArea()
    }
}}

// MARK: - Model
struct PDFItem: Identifiable, Hashable { let id = UUID(); var url: URL; var document: PDFDocument; var displayName: String { url.lastPathComponent } }
final class AppState: ObservableObject {
    @Published var pdfs: [PDFItem] = []
    @Published var selectedPDFID: UUID? = nil
    @Published var selectedPages: Set<Int> = []
    @Published var log: String = "Ready."
    @Published var exportFolderURL: URL? = nil
    @Published var isBusy: Bool = false
    var activePDFIndex: Int? { guard let id = selectedPDFID else { return nil }; return pdfs.firstIndex { $0.id == id } }
    var activeDocument: PDFDocument? { guard let idx = activePDFIndex else { return nil }; return pdfs[idx].document }
}

// MARK: - Toolbar Modes (sekme bazlı)
enum ToolbarMode: String, CaseIterable, Identifiable {
    case files = "Files", pages = "Pages", combine = "Combine/Split", compress = "Compress", output = "Output", view = "View"
    var id: String { rawValue }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var state = AppState()
    // PDF ops
    @State private var splitEvery: Int = 10
    @State private var compressDPI: Double = 110
    @State private var compressQuality: Double = 0.6
    @State private var pageRangeText: String = ""
    @State private var thumbScale: Double = 1.0
    // UI/tema
    @State private var bgStyle: BGStyle = .gradient
    @State private var themeSetting: ThemeSetting = .system
    // Toolbar
    @State private var toolbarMode: ToolbarMode = .files

    var body: some View {
        ZStack {
            backgroundView
            NavigationSplitView { sidebar } detail: {
                VStack(spacing: 10) {
                    toolbarSegmented
                    toolbarSection // seçili sekmeye göre içerik
                    Divider()
                    mainArea
                    Divider()
                    logArea
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 8)
            }
            .frame(minWidth: 920, minHeight: 720)
        }
        .preferredColorScheme(themeSetting.colorScheme)
        .frame(minWidth: 980, minHeight: 760)
    }

    // MARK: Sidebar
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("PDFs (" ) + Text("\(state.pdfs.count)") + Text(")"); Spacer()
                Button { addPDFs() } label: { Label("Add", systemImage: "plus") }.buttonStyle(.bordered).controlSize(.small)
            }.font(.headline)
            List(selection: Binding(get: { state.selectedPDFID }, set: { newID in state.selectedPDFID = newID; state.selectedPages.removeAll() })) {
                ForEach(state.pdfs) { item in HStack { Image(systemName: "doc.richtext"); Text(item.displayName).lineLimit(1) }.tag(item.id) }
            }
            HStack(spacing: 6) {
                Button { movePDF(up: true) } label: { Image(systemName: "arrow.up") }.help("Move up").controlSize(.small).disabled(state.activePDFIndex == nil)
                Button { movePDF(up: false) } label: { Image(systemName: "arrow.down") }.help("Move down").controlSize(.small).disabled(state.activePDFIndex == nil)
                Spacer()
                Button(role: .destructive) { removeActivePDF() } label: { Image(systemName: "trash") }.help("Remove from list (no file deletion)").controlSize(.small).disabled(state.activePDFIndex == nil)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
    }

    // MARK: Toolbar – Segmented header + section content
    private var toolbarSegmented: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Mode", selection: $toolbarMode) {
                    ForEach(ToolbarMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 420)

                Spacer(minLength: 0)

                // Kısa kısayollar
                Button { addPDFs() } label: { Label("", systemImage: "plus") }.help("Add PDFs").controlSize(.small)
                Button { mergeAll() } label: { Image(systemName: "square.stack.3d.down.right") }.help("Merge All").controlSize(.small).disabled(state.pdfs.count < 2)
                Button { chooseExportFolder() } label: { Image(systemName: "folder") }.help("Export Folder").controlSize(.small)
            }
        }
    }

    private var toolbarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch toolbarMode {
            case .files: filesSection
            case .pages: pagesSection
            case .combine: combineSection
            case .compress: compressSection
            case .output: outputSection
            case .view: viewSection
            }
        }
        .padding(8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // --- Sections ---
    private var filesSection: some View {
        HStack(spacing: 10) {
            Button { addPDFs() } label: { Label("Add PDFs", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.small)
            Button { removeActivePDF() } label: { Label("Remove from list", systemImage: "trash") }.disabled(state.activePDFIndex == nil).controlSize(.small)
            Spacer()
        }
    }

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Select All", action: selectAllPages).keyboardShortcut("a", modifiers: [.command])
                Button("None", action: { state.selectedPages.removeAll() }).keyboardShortcut(.escape)
                Button("Invert", action: invertSelection)
                Divider().frame(height: 16)
                Text("Range:").font(.caption)
                TextField("e.g. 1-3,5,10-12", text: $pageRangeText).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Select Range") { selectRange(pageRangeText) }
                Spacer()
            }
            HStack(spacing: 10) {
                Button { deleteSelectedPages() } label: { Label("Delete Pages", systemImage: "scissors") }
                    .disabled(state.selectedPages.isEmpty || state.activeDocument == nil)
                Button { extractSelectedPages() } label: { Label("Extract Pages", systemImage: "square.and.arrow.up") }
                    .disabled(state.selectedPages.isEmpty || state.activeDocument == nil)
                Spacer()
            }
        }
        .controlSize(.small)
    }

    private var combineSection: some View {
        HStack(spacing: 10) {
            Button { mergeAll() } label: { Label("Merge All", systemImage: "square.stack.3d.down.right") }
                .disabled(state.pdfs.count < 2)
            Divider().frame(height: 16)
            Text("Split every \(splitEvery)")
            Stepper("", value: $splitEvery, in: 2...200).labelsHidden()
            Button { splitAll(every: splitEvery) } label: { Text("Split") }.disabled(state.pdfs.isEmpty)
            Spacer()
        }
        .controlSize(.small)
    }

    private var compressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("DPI")
                Slider(value: $compressDPI, in: 72...300, step: 1).frame(width: 200)
                Text("\(Int(compressDPI))").monospaced()
                Text("Quality")
                Slider(value: $compressQuality, in: 0.2...0.95, step: 0.05).frame(width: 200)
                Text(String(format: "%.2f", compressQuality)).monospaced()
                Button { compressAll() } label: { Text("Apply") }.disabled(state.pdfs.isEmpty)
                Spacer()
            }
        }
        .controlSize(.small)
    }

    private var outputSection: some View {
        HStack(spacing: 10) {
            Button { chooseExportFolder() } label: { Label("Export Folder", systemImage: "folder") }
            if let out = state.exportFolderURL { Text(out.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) } else { Text("(Ask each time)").font(.caption).foregroundStyle(.tertiary) }
            Spacer()
        }
        .controlSize(.small)
    }

    private var viewSection: some View {
        HStack(spacing: 10) {
            Text("Zoom")
            Slider(value: $thumbScale, in: 0.7...1.6, step: 0.05).frame(width: 220)
            Text(String(format: "%.0f%%", thumbScale * 100)).monospaced()
            Divider().frame(height: 16)
            Text("Anim")
            Picker("Animation", selection: $bgStyle) { ForEach(BGStyle.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 280)
            Text("Theme")
            Picker("Theme", selection: $themeSetting) { ForEach(ThemeSetting.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 260)
            Spacer()
        }
        .controlSize(.small)
    }

    // MARK: Main Area
    private var mainArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let doc = state.activeDocument {
                Text("Pages: \(doc.pageCount)").font(.headline)
                if state.isBusy { ProgressView().controlSize(.small) }
                ScrollView {
                    let columns = 4
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(0..<doc.pageCount, id: \.self) { idx in
                            PageThumbView(document: doc, pageIndex: idx, isSelected: state.selectedPages.contains(idx), baseSize: 160 * thumbScale)
                                .onTapGesture { if state.selectedPages.contains(idx) { state.selectedPages.remove(idx) } else { state.selectedPages.insert(idx) } }
                                .contextMenu {
                                    Button("Select only this") { state.selectedPages = [idx] }
                                    Button("Exclude this") { state.selectedPages.remove(idx) }
                                }
                        }
                    }
                    .padding(4)
                }
            } else {
                VStack(spacing: 8) { Text("No PDF selected").foregroundStyle(.secondary); Text("Click 'Add PDFs' to begin.").font(.caption) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Log
    private var logArea: some View {
        GroupBox("Log") {
            ScrollView { Text(state.log).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                .frame(minHeight: 80, maxHeight: 140)
        }
    }

    private func appendLog(_ line: String) { state.log += "\n" + line }

    // MARK: - File Ops
    private func addPDFs() {
        let panel = NSOpenPanel(); panel.title = "Select PDFs"; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK { for url in panel.urls { if let doc = PDFDocument(url: url) { state.pdfs.append(.init(url: url, document: doc)) } }; if state.selectedPDFID == nil { state.selectedPDFID = state.pdfs.first?.id }; appendLog("✅ Added \(panel.urls.count) file(s)") }
    }
    private func chooseExportFolder() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.title = "Choose Export Folder"; if panel.runModal() == .OK { state.exportFolderURL = panel.url } }
    private func removeActivePDF() { guard let idx = state.activePDFIndex else { return }; let name = state.pdfs[idx].displayName; state.pdfs.remove(at: idx); state.selectedPDFID = state.pdfs.first?.id; state.selectedPages.removeAll(); appendLog("🗑️ Removed \(name) from list") }
    private func movePDF(up: Bool) { guard let idx = state.activePDFIndex else { return }; let newIndex = up ? max(0, idx - 1) : min(state.pdfs.count - 1, idx + 1); guard newIndex != idx else { return }; state.pdfs.swapAt(idx, newIndex); state.selectedPDFID = state.pdfs[newIndex].id }

    // MARK: - Page Ops
    private func deleteSelectedPages() { guard let idx = state.activePDFIndex else { return }; let doc = state.pdfs[idx].document; let sorted = state.selectedPages.sorted(by: >); guard !sorted.isEmpty else { return }; for p in sorted { if p < doc.pageCount { doc.removePage(at: p) } }; state.selectedPages.removeAll(); appendLog("✂️ Deleted \(sorted.count) page(s) from \(state.pdfs[idx].displayName)") }
    private func extractSelectedPages() { guard let idx = state.activePDFIndex else { return }; let doc = state.pdfs[idx].document; let pages = state.selectedPages.sorted(); guard !pages.isEmpty else { return }; let outDoc = PDFDocument(); var insert = 0; for p in pages { if let page = doc.page(at: p) { outDoc.insert(page, at: insert); insert += 1 } }; savePDF(document: outDoc, suggestedName: baseName(state.pdfs[idx].url) + "_extract.pdf") }
    private func mergeAll() { guard !state.pdfs.isEmpty else { return }; let merged = PDFDocument(); var cursor = 0; for item in state.pdfs { for i in 0..<item.document.pageCount { if let page = item.document.page(at: i) { merged.insert(page, at: cursor); cursor += 1 } } }; savePDF(document: merged, suggestedName: "Merged.pdf") }
    private func splitAll(every n: Int) { guard n >= 2 else { return }; guard !state.pdfs.isEmpty else { return }; for item in state.pdfs { let doc = item.document; var part = 1; var cursor = 0; while cursor < doc.pageCount { let out = PDFDocument(); let end = min(cursor + n, doc.pageCount); var insert = 0; for i in cursor..<end { if let page = doc.page(at: i) { out.insert(page, at: insert); insert += 1 } }; let name = baseName(item.url) + String(format: "_part_%02d.pdf", part); savePDF(document: out, suggestedName: name); part += 1; cursor = end } } }
    private func compressAll() { guard !state.pdfs.isEmpty else { return }; for item in state.pdfs { let compressed = rasterized(document: item.document, dpi: compressDPI, jpegQuality: compressQuality); let name = baseName(item.url) + "_compressed.pdf"; savePDF(document: compressed, suggestedName: name) } }

    // MARK: - Helpers
    private func baseName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
    private func savePDF(document: PDFDocument, suggestedName: String) {
        if let folder = state.exportFolderURL { let outURL = folder.appendingPathComponent(suggestedName); if document.write(to: outURL) { appendLog("💾 Saved → \(outURL.lastPathComponent)") } else { appendLog("❌ Save failed for \(outURL.lastPathComponent)") }; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = suggestedName; if panel.runModal() == .OK, let outURL = panel.url { if document.write(to: outURL) { appendLog("💾 Saved → \(outURL.lastPathComponent)") } else { appendLog("❌ Save failed for \(outURL.lastPathComponent)") } }
    }
    private func rasterized(document: PDFDocument, dpi: Double, jpegQuality: Double) -> PDFDocument {
        state.isBusy = true; defer { state.isBusy = false }
        let out = PDFDocument(); let q = max(0.2, min(0.95, jpegQuality))
        for i in 0..<document.pageCount { guard let page = document.page(at: i) else { continue }; let bounds = page.bounds(for: .mediaBox); let scale = dpi / 72.0; let pxSize = NSSize(width: bounds.width * scale, height: bounds.height * scale); if let img = render(page: page, pixelSize: pxSize), let jpegData = img.jpegData(compression: q), let jpegNSImage = NSImage(data: jpegData), let newPage = PDFPage(image: jpegNSImage) { out.insert(newPage, at: out.pageCount) } }
        return out
    }
    private func render(page: PDFPage, pixelSize: NSSize) -> NSImage? {
        let img = NSImage(size: pixelSize); img.lockFocusFlipped(false); NSGraphicsContext.current?.imageInterpolation = .high; guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return nil }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(origin: .zero, size: CGSize(width: pixelSize.width, height: pixelSize.height)))
        ctx.saveGState(); ctx.translateBy(x: 0, y: pixelSize.height)
        ctx.scaleBy(x: pixelSize.width / page.bounds(for: .mediaBox).width, y: -pixelSize.height / page.bounds(for: .mediaBox).height)
        page.draw(with: .mediaBox, to: ctx); ctx.restoreGState(); img.unlockFocus(); return img
    }

    // Selection helpers
    private func selectAllPages() { if let doc = state.activeDocument { state.selectedPages = Set(0..<doc.pageCount) } }
    private func invertSelection() { if let doc = state.activeDocument { let all = Set(0..<doc.pageCount); state.selectedPages = all.subtracting(state.selectedPages) } }
    private func selectRange(_ text: String) { guard let doc = state.activeDocument else { return }; let parts = text.replacingOccurrences(of: " ", with: "").split(separator: ","); var add: Set<Int> = []; for p in parts { if p.contains("-") { let ab = p.split(separator: "-"); if let a = Int(ab.first ?? ""), let b = Int(ab.last ?? "") { let lo = max(1, min(a,b)), hi = min(doc.pageCount, max(a,b)); add.formUnion((lo-1)...(hi-1)) } } else if let v = Int(p) { if (1...doc.pageCount).contains(v) { add.insert(v-1) } } }; state.selectedPages.formUnion(add) }
}

// MARK: - Background switch helper
private extension ContentView { @ViewBuilder var backgroundView: some View { switch bgStyle { case .gradient: GradientBackground(); case .waves: WavesBackground(); case .particles: ParticlesBackground() } } }

// MARK: - Page Thumbnail View (hover)
struct PageThumbView: View { let document: PDFDocument; let pageIndex: Int; let isSelected: Bool; let baseSize: CGFloat; @State private var isHovering = false
    var body: some View {
        VStack(spacing: 6) {
            if let page = document.page(at: pageIndex) {
                let thumb = page.thumbnail(of: NSSize(width: baseSize, height: baseSize * 1.4), for: .mediaBox)
                Image(nsImage: thumb)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: baseSize, maxHeight: baseSize * 1.4)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 3 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(isHovering ? 0.25 : 0.08), radius: isHovering ? 12 : 4, y: 4)
                    .scaleEffect(isHovering ? 1.02 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: isHovering)
                    .onHover { isHovering = $0 }
            }
            Text("\(pageIndex + 1)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Utilities
extension NSImage { func jpegData(compression: Double) -> Data? { guard let tiff = self.tiffRepresentation else { return nil }; guard let bitmap = NSBitmapImageRep(data: tiff) else { return nil }; return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]) } }
