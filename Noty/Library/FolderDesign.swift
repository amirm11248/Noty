import PhotosUI
import SwiftUI

extension NotyFolder {
    var displayDesign: NotyNotebookCover {
        design ?? NotyNotebookCover(style: .gradient, colorHex: ["65749C", "5B8985", "98799D", "AD9069"][Int(id.uuid.0) % 4])
    }
}

private struct FolderSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.14))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.08, y: 0), control: .zero)
        path.addLine(to: CGPoint(x: rect.width * 0.36, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.14), control: CGPoint(x: rect.width * 0.4, y: 0))
        path.addLine(to: CGPoint(x: rect.width * 0.92, y: rect.height * 0.14))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height * 0.24), control: CGPoint(x: rect.width, y: rect.height * 0.14))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.9))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.92, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width * 0.08, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.height * 0.9), control: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

struct FolderArtwork: View {
    let design: NotyNotebookCover
    let symbol: String
    var imageData: Data?
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: UIColor(notyHex: design.colorHex))
                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    Color.black.opacity(0.2)
                }
                if design.style != .minimal {
                    LinearGradient(colors: [.white.opacity(0.26), .clear, .black.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                if design.style == .geometric {
                    Canvas { context, size in
                        for index in 0..<8 {
                            var line = Path()
                            line.move(to: CGPoint(x: CGFloat(index) * size.width / 4 - size.height, y: 0))
                            line.addLine(to: CGPoint(x: CGFloat(index) * size.width / 4, y: size.height))
                            context.stroke(line, with: .color(.white.opacity(0.15)), lineWidth: size.width * 0.1)
                        }
                    }
                } else if design.style == .linen {
                    Canvas { context, size in
                        for y in stride(from: CGFloat(0), through: size.height, by: 3) {
                            var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(line, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
                        }
                    }
                }
                Rectangle().fill(.white.opacity(0.18)).frame(height: 1).offset(y: -proxy.size.height * 0.25)
                Image(systemName: symbol).font(.system(size: proxy.size.height * 0.25, weight: .light)).foregroundStyle(.white.opacity(0.9)).offset(y: proxy.size.height * 0.07)
            }
            .clipShape(FolderSilhouette())
            .overlay(FolderSilhouette().stroke(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: Color(uiColor: UIColor(notyHex: design.colorHex)).opacity(0.22), radius: 14, x: 0, y: 8)
        }
        .aspectRatio(1.25, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct FolderDesignSheet: View {
    let isNew: Bool
    var onSave: (String, NotyNotebookCover, String, Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var design: NotyNotebookCover
    @State private var symbol: String
    @State private var imageData: Data?
    @State private var photo: PhotosPickerItem?
    @State private var photoError: String?
    @State private var isLoadingPhoto = false
    private let colors = ["5267A9", "497B76", "A0687D", "B58C54", "5F537C", "3F4B5B", "BD6D58", "6E8054"]
    private let symbols = ["books.vertical", "graduationcap", "atom", "function", "leaf", "globe.europe.africa", "music.note", "paintpalette", "calendar", "heart", "star", "briefcase"]

    init(folder: NotyFolder? = nil, onSave: @escaping (String, NotyNotebookCover, String, Data?) -> Void) {
        isNew = folder == nil
        self.onSave = onSave
        _name = State(initialValue: folder?.name ?? "")
        _design = State(initialValue: folder?.displayDesign ?? NotyNotebookCover())
        _symbol = State(initialValue: folder?.symbol ?? "books.vertical")
        _imageData = State(initialValue: folder?.imageData)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    FolderArtwork(design: design, symbol: symbol, imageData: imageData).frame(width: 220).frame(maxWidth: .infinity).padding(.vertical, 12)
                    TextField("Folder name", text: $name).font(.title3.weight(.semibold)).padding(16).frostedPanel()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Design").font(.headline)
                        Picker("Folder design", selection: $design.style) {
                            ForEach(NotyCoverStyle.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(colors, id: \.self) { hex in
                                    Button { design.colorHex = hex } label: {
                                        Circle().fill(Color(uiColor: UIColor(notyHex: hex))).frame(width: 36, height: 36)
                                            .overlay(Circle().stroke(design.colorHex == hex ? NotionTheme.ink : .clear, lineWidth: 2).padding(-4))
                                            .padding(4)
                                    }.buttonStyle(.plain).accessibilityLabel("Folder color \(NotyColorName.name(hex))").accessibilityAddTraits(design.colorHex == hex ? .isSelected : [])
                                }
                            }
                        }
                    }
                    HStack {
                        PhotosPicker(selection: $photo, matching: .images) { Label(isLoadingPhoto ? "Loading photo…" : "Use a photo", systemImage: "photo") }.disabled(isLoadingPhoto)
                        Spacer()
                        if imageData != nil { Button("Remove photo") { imageData = nil; photo = nil } }
                    }.font(.subheadline)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Symbol").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 12) {
                            ForEach(symbols, id: \.self) { icon in
                                Button { symbol = icon } label: {
                                    Image(systemName: icon).font(.title3).frame(maxWidth: .infinity, minHeight: 48)
                                        .background(symbol == icon ? NotionTheme.accent.opacity(0.18) : NotionTheme.rowHover, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).accessibilityLabel(icon.replacingOccurrences(of: ".", with: " ")).accessibilityAddTraits(symbol == icon ? .isSelected : [])
                            }
                        }
                    }
                }.padding(24)
            }
            .background { FrostedWorkspaceBackground() }
            .navigationTitle(isNew ? "New folder" : "Customize folder").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), design, symbol, imageData); dismiss() }
                        .fontWeight(.semibold).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingPhoto)
                }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            isLoadingPhoto = true
            Task { @MainActor in
                defer { isLoadingPhoto = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw NotyStoreError.invalidImage }
                    let ratio = image.size.width / image.size.height
                    let size = ratio >= 1 ? CGSize(width: 600, height: 600 / ratio) : CGSize(width: 600 * ratio, height: 600)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                    imageData = thumbnail.jpegData(compressionQuality: 0.8)
                } catch { photoError = "This photo could not be opened. Choose another photo." }
            }
        }
        .alert("Couldn’t add photo", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
            Button("OK") { photoError = nil }
        } message: { Text(photoError ?? "") }
        .presentationSizing(.page)
        .presentationDetents([.large])
    }
}
