import PhotosUI
import SwiftUI
import UIKit

extension NotyPageTemplate {
    var title: String {
        switch self {
        case .blank: "Blank"
        case .ruled: "Ruled"
        case .narrowRuled: "Narrow ruled"
        case .grid: "Grid"
        case .smallGrid: "Small grid"
        case .dots: "Dotted"
        case .cornell: "Cornell"
        case .weeklyPlanner: "Weekly planner"
        case .dailyPlanner: "Daily planner"
        case .music: "Music staff"
        case .checklist: "Checklist"
        }
    }
    var icon: String {
        switch self {
        case .blank: "square"
        case .ruled, .narrowRuled: "line.3.horizontal"
        case .grid, .smallGrid: "grid"
        case .dots: "circle.grid.3x3"
        case .cornell: "rectangle.split.2x1"
        case .weeklyPlanner, .dailyPlanner: "calendar"
        case .music: "music.note"
        case .checklist: "checklist"
        }
    }
}

struct NotebookCoverView: View {
    let title: String
    let cover: NotyNotebookCover
    var image: UIImage?
    var pageSize: CGSize?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                } else {
                    Color(uiColor: UIColor(notyHex: cover.colorHex))
                    if cover.style == .gradient {
                        LinearGradient(colors: [.white.opacity(0.24), .clear, .black.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Circle().fill(.white.opacity(0.1)).frame(width: size.width * 1.3).offset(x: size.width * 0.1, y: -size.height * 0.45)
                        Circle().stroke(.white.opacity(0.13), lineWidth: 1).frame(width: size.width * 1.5).offset(x: -size.width * 0.5, y: size.height * 0.55)
                    } else if cover.style == .geometric {
                        Canvas { context, dimensions in
                            for index in 0..<8 {
                                let x = CGFloat(index) * dimensions.width / 4
                                var path = Path()
                                path.move(to: CGPoint(x: x - dimensions.height, y: 0))
                                path.addLine(to: CGPoint(x: x, y: dimensions.height))
                                context.stroke(path, with: .color(.white.opacity(0.16)), lineWidth: dimensions.width * 0.12)
                            }
                        }
                    } else if cover.style == .linen {
                        Canvas { context, dimensions in
                            for y in stride(from: CGFloat(0), through: dimensions.height, by: 3) {
                                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: dimensions.width, y: y))
                                context.stroke(line, with: .color(.white.opacity(0.09)), lineWidth: 0.5)
                            }
                        }
                    }
                }
                LinearGradient(colors: [.black.opacity(0.22), .white.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: size.width * 0.09)
                VStack(alignment: .leading, spacing: size.height * 0.04) {
                    Image(systemName: "sparkle").font(.system(size: size.width * 0.12, weight: .light))
                    Spacer()
                    Text(title.isEmpty ? "My notebook" : title)
                        .font(.system(size: max(12, size.width * 0.13), weight: .semibold, design: .serif))
                        .lineLimit(4).minimumScaleFactor(0.6)
                    Rectangle().fill(.white.opacity(0.6)).frame(width: size.width * 0.22, height: 1)
                    Text("NOTY").font(.system(size: max(7, size.width * 0.045), weight: .medium)).tracking(2)
                }
                .foregroundStyle(.white)
                .frame(width: max(1, size.width * 0.72), height: max(1, size.height - size.width * 0.28), alignment: .leading)
                .padding(size.width * 0.14)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .aspectRatio(pageSize.map { $0.width / $0.height } ?? 0.72, contentMode: .fit)
        .accessibilityLabel("\(title) notebook cover")
    }
}

extension UIColor {
    convenience init(notyHex: String) {
        let value = UInt64(notyHex, radix: 16) ?? 0x5267A9
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

struct NotebookDesignSheet: View {
    enum Purpose { case notebook, page, cover }
    let purpose: Purpose
    var initialTitle = ""
    var initialPage = NotyPage(template: .ruled, sizePreset: .a4)
    var initialCover = NotyNotebookCover()
    var existingCoverImage: UIImage?
    let onSave: (String, NotyPage, NotyNotebookCover, Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var title = ""
    @State private var page = NotyPage()
    @State private var cover = NotyNotebookCover()
    @State private var photo: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoError: String?
    @State private var isLoadingPhoto = false
    @State private var initialized = false
    @State private var designSection = 0
    private let colors = ["5267A9", "497B76", "A0687D", "B58C54", "5F537C", "3F4B5B", "BD6D58", "6E8054"]
    private let papers = ["FFFFFF", "FFFDF5", "FFF3B0", "EAF4FF", "ECF7EE", "FCECEF", "292927"]

    private var isChoosingPaper: Bool { purpose == .page || (purpose == .notebook && designSection == 1) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center, spacing: 28) {
                        if !isChoosingPaper {
                            NotebookCoverView(title: title, cover: cover, image: photoData.flatMap(UIImage.init(data:)) ?? (cover.imageFileName == nil ? nil : existingCoverImage))
                                .frame(width: 145).shadow(color: .black.opacity(0.16), radius: 16, y: 8)
                        } else {
                            PaperDesignPreview(page: page).frame(width: 145, height: 200)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(isChoosingPaper ? "A fresh page." : "Make it yours.")
                                .font(.system(size: 29, weight: .semibold, design: .serif))
                            Text(isChoosingPaper ? "Paper for the way you think. Choose a layout, color and size." : "A cover you love. Paper that fits the way you think.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if purpose != .page {
                        TextField("Notebook title", text: $title).font(.title3.weight(.medium))
                            .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if purpose == .notebook {
                        Picker("Notebook design", selection: $designSection) {
                            Text("Cover").tag(0)
                            Text("Paper · \(page.template.title)").tag(1)
                        }.pickerStyle(.segmented)
                    }
                    if purpose == .cover || (purpose == .notebook && designSection == 0) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Cover").font(.headline)
                            Picker("Cover style", selection: $cover.style) {
                                ForEach(NotyCoverStyle.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            colorRow(colors, selected: cover.colorHex) { cover.colorHex = $0; cover.imageFileName = nil; photoData = nil }
                            HStack {
                                PhotosPicker(selection: $photo, matching: .images) { Label("Use a photo", systemImage: "photo") }
                                if cover.imageFileName != nil || photoData != nil {
                                    Button("Remove photo") { cover.imageFileName = nil; photoData = nil; photo = nil }
                                }
                            }.font(.subheadline)
                            if isLoadingPhoto { ProgressView("Loading cover…") }
                            if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
                        }
                    }
                    if isChoosingPaper {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Paper").font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 12) {
                                ForEach(NotyPageTemplate.allCases, id: \.self) { template in
                                    Button {
                                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { page.template = template }
                                    } label: {
                                        VStack(spacing: 8) {
                                            PaperDesignPreview(page: NotyPage(template: template, paperColorHex: page.paperColorHex)).frame(height: 100)
                                            Text(template.title).font(.caption.weight(.medium)).lineLimit(1)
                                        }
                                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(page.template == template ? NotionTheme.accent : .clear, lineWidth: 2))
                                    }.buttonStyle(.plain).accessibilityAddTraits(page.template == template ? .isSelected : [])
                                }
                            }
                            colorRow(papers, selected: page.paperColorHex) { page.paperColorHex = $0 }
                            if page.customWidth != nil {
                                Text("Current page size · \(Int(page.canvasSize.width)) × \(Int(page.canvasSize.height)) pt").font(.caption).foregroundStyle(.secondary)
                                Button("Use a standard paper size") { page.customWidth = nil; page.customHeight = nil }
                            }
                            Picker("Size", selection: Binding(get: { page.sizePreset }, set: {
                                page.sizePreset = $0; page.customWidth = nil; page.customHeight = nil
                            })) {
                                ForEach(NotyPageSizePreset.allCases, id: \.self) { Text($0.designTitle).tag($0) }
                            }
                            Picker("Orientation", selection: Binding(get: { page.orientation }, set: { orientation in
                                if orientation != page.orientation, let width = page.customWidth, let height = page.customHeight {
                                    page.customWidth = height; page.customHeight = width
                                }
                                page.orientation = orientation
                            })) {
                                Text("Portrait").tag(NotyPageOrientation.portrait)
                                Text("Landscape").tag(NotyPageOrientation.landscape)
                            }.pickerStyle(.segmented)
                        }
                    }
                }.animation(reduceMotion ? nil : .snappy(duration: 0.25), value: designSection).padding(24).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
            .background { FrostedWorkspaceBackground() }
            .navigationTitle(purpose == .page ? "Add page" : purpose == .cover ? "Notebook cover" : "New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose == .page ? "Add" : purpose == .cover ? "Save" : "Create") {
                        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), page, cover, photoData)
                        dismiss()
                    }.fontWeight(.semibold).disabled((purpose != .page && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || isLoadingPhoto)
                }
            }
            .onAppear {
                guard !initialized else { return }; initialized = true
                title = initialTitle; page = initialPage; cover = initialCover
            }
            .task(id: photo) {
                guard let photo else { return }
                isLoadingPhoto = true; photoError = nil
                defer { isLoadingPhoto = false }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self), UIImage(data: data) != nil else { throw NotyStoreError.invalidImage }
                    photoData = data
                } catch { photoError = "This photo couldn’t be loaded. Choose another image." }
            }
        }
        .presentationSizing(.page)
        .presentationDragIndicator(.visible)
    }
    private func colorRow(_ colors: [String], selected: String, action: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal) {
        HStack(spacing: 12) {
            ForEach(colors, id: \.self) { hex in
                Button { action(hex) } label: {
                    Circle().fill(Color(uiColor: UIColor(notyHex: hex))).frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.primary.opacity(0.15), lineWidth: 1))
                        .overlay { if selected == hex { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(UIColor(notyHex: hex).notyIsDark ? .white : .black) } }
                }.buttonStyle(.plain).frame(minWidth: 36, minHeight: 44)
                    .accessibilityLabel(NotyColorName.name(hex)).accessibilityAddTraits(selected == hex ? .isSelected : [])
            }
        }
        }.scrollIndicators(.hidden)
    }
}

enum NotyColorName {
    static func name(_ hex: String) -> String {
        switch hex {
        case "5267A9": "Indigo"; case "497B76": "Sage"; case "A0687D": "Rose"; case "B58C54": "Sand"
        case "5F537C": "Plum"; case "3F4B5B": "Slate"; case "BD6D58": "Terracotta"; case "6E8054": "Olive"
        case "FFFFFF": "White"; case "FFFDF5": "Ivory"; case "FFF3B0": "Yellow"; case "EAF4FF": "Blue"
        case "ECF7EE": "Green"; case "FCECEF": "Pink"; case "292927": "Charcoal"; default: "Custom color"
        }
    }
}
extension UIColor {
    var notyIsDark: Bool { var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; getRed(&r, green: &g, blue: &b, alpha: nil); return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.48 }
}
extension NotyPageSizePreset {
    var designTitle: String {
        switch self { case .a4: "A4"; case .a5: "A5"; case .letter: "US Letter"; case .legal: "US Legal"; case .square: "Square"; case .screen4x3: "Screen 4:3"; case .widescreen16x9: "Widescreen 16:9" }
    }
}

struct PaperDesignPreview: View {
    let page: NotyPage
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / page.canvasSize.width, proxy.size.height / page.canvasSize.height)
            PaperTemplateSurface(template: page.template, paperColorHex: page.paperColorHex)
                .frame(width: page.canvasSize.width, height: page.canvasSize.height)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .background(Color(uiColor: UIColor(notyHex: page.paperColorHex)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.1)))
        .accessibilityHidden(true)
    }
}

// The same geometry drives editor previews and exported pages.
enum PaperTemplateGeometry {
    static func path(_ template: NotyPageTemplate, size: CGSize) -> CGPath {
        let p = CGMutablePath()
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) { p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2)) }
        switch template {
        case .blank: break
        case .ruled, .narrowRuled:
            for y in stride(from: CGFloat(34), through: size.height, by: template == .ruled ? 28 : 20) { line(28, y, size.width - 24, y) }
            line(min(56, size.width * 0.12), 0, min(56, size.width * 0.12), size.height)
        case .grid, .smallGrid:
            let spacing: CGFloat = template == .grid ? 24 : 16
            for x in stride(from: spacing, through: size.width, by: spacing) { line(x, 0, x, size.height) }
            for y in stride(from: spacing, through: size.height, by: spacing) { line(0, y, size.width, y) }
        case .dots:
            for x in stride(from: CGFloat(18), through: size.width, by: 24) {
                for y in stride(from: CGFloat(18), through: size.height, by: 24) { p.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)) }
            }
        case .cornell:
            let cueX = max(90, size.width * 0.3); let summaryY = size.height - 110
            line(cueX, 54, cueX, summaryY); line(24, 54, size.width - 24, 54); line(24, summaryY, size.width - 24, summaryY)
            for y in stride(from: CGFloat(82), through: summaryY - 12, by: 28) { line(cueX + 12, y, size.width - 24, y) }
        case .weeklyPlanner:
            let h = (size.height - 104) / 7
            for i in 0...7 { line(24, 72 + CGFloat(i) * h, size.width - 24, 72 + CGFloat(i) * h) }
            line(110, 72, 110, size.height - 32)
        case .dailyPlanner:
            line(24, 80, size.width - 24, 80); line(size.width * 0.63, 80, size.width * 0.63, size.height - 32)
            for y in stride(from: CGFloat(116), through: size.height - 32, by: 36) { line(24, y, size.width * 0.63 - 12, y) }
            line(size.width * 0.63 + 12, size.height * 0.5, size.width - 24, size.height * 0.5)
        case .music:
            for top in stride(from: CGFloat(60), through: size.height - 72, by: 88) { for i in 0..<5 { line(24, top + CGFloat(i) * 9, size.width - 24, top + CGFloat(i) * 9) } }
        case .checklist:
            for y in stride(from: CGFloat(72), through: size.height - 32, by: 36) { p.addRect(CGRect(x: 28, y: y - 14, width: 12, height: 12)); line(52, y, size.width - 24, y) }
        }
        return p
    }
    static func labels(_ template: NotyPageTemplate, size: CGSize) -> [(String, CGPoint)] {
        switch template {
        case .weeklyPlanner:
            let heading: [(String, CGPoint)] = [("WEEK OF", CGPoint(x: 24, y: 30))]
            let dayNames = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
            let rowHeight = (size.height - 104) / 7
            let days: [(String, CGPoint)] = dayNames.enumerated().map { index, name in
                (name, CGPoint(x: 32, y: 88 + CGFloat(index) * rowHeight))
            }
            return heading + days
        case .dailyPlanner: return [("TODAY", CGPoint(x: 24, y: 30)), ("SCHEDULE", CGPoint(x: 24, y: 60)), ("PRIORITIES", CGPoint(x: size.width * 0.63 + 12, y: 60)), ("NOTES", CGPoint(x: size.width * 0.63 + 12, y: size.height * 0.5 + 16))]
        case .cornell: return [("TOPIC / DATE", CGPoint(x: 24, y: 26)), ("SUMMARY", CGPoint(x: 24, y: size.height - 94))]
        case .checklist: return [("TO DO", CGPoint(x: 24, y: 30))]
        default: return []
        }
    }
}

struct PaperTemplateSurface: View {
    let template: NotyPageTemplate
    let paperColorHex: String
    var body: some View {
        Canvas { context, size in
            let dark = UIColor(notyHex: paperColorHex).notyIsDark
            let color = dark ? Color.white.opacity(0.24) : Color(red: 0.3, green: 0.36, blue: 0.44).opacity(0.18)
            let path = Path(PaperTemplateGeometry.path(template, size: size))
            if template == .dots { context.fill(path, with: .color(color)) }
            else { context.stroke(path, with: .color(color), lineWidth: 0.65) }
            for (label, point) in PaperTemplateGeometry.labels(template, size: size) {
                context.draw(Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(dark ? .white.opacity(0.55) : .secondary), at: point, anchor: .topLeading)
            }
        }.allowsHitTesting(false)
    }
}

extension NotyDocument {
    var displayCover: NotyNotebookCover {
        if let cover { return cover }
        let colors = ["5267A9", "497B76", "A0687D", "B58C54", "5F537C", "3F4B5B"]
        let index = id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return NotyNotebookCover(style: NotyCoverStyle.allCases[index % NotyCoverStyle.allCases.count], colorHex: colors[index])
    }
}
