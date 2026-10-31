import SwiftUI
import UniformTypeIdentifiers

/// The input field: text, images (button, drag and drop, paste), thinking and web search toggles.
struct Composer: View {
    let conversationID: Conversation.ID
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var settings: Settings
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var importing = false
    @State private var dropTarget = false
    @FocusState private var focused: Bool

    private var canSend: Bool {
        engine.state.isRunning && !chat.busy && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments) { a in
                            ZStack(alignment: .topTrailing) {
                                if let img = NSImage(data: a.jpeg) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button { attachments.removeAll { $0.id == a.id } } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).padding(3)
                            }
                        }
                    }
                }
            }
            TextField("Vraag DeepSeek iets…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit(send)
                .onPasteCommand(of: [.image, .fileURL]) { providers in load(providers) }
            HStack(spacing: 8) {
                Button { importing = true } label: { Image(systemName: "photo.badge.plus") }
                    .help("Afbeelding toevoegen").disabled(!settings.vision)
                Toggle(isOn: $settings.thinking) { Label("Denken", systemImage: "brain") }
                    .toggleStyle(.button).help("Laat het model eerst nadenken (beter, maar trager)")
                Toggle(isOn: $settings.webSearch) { Label("Web", systemImage: "globe") }
                    .toggleStyle(.button).help("Het model mag het web doorzoeken en pagina's lezen")
                Spacer()
                if chat.busy {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.plain).help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(canSend ? Theme.accent : .secondary)
                        .disabled(!canSend).keyboardShortcut(.return, modifiers: .command)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropTarget ? Theme.accent : Color.secondary.opacity(0.25), lineWidth: dropTarget ? 2 : 1))
        .frame(maxWidth: 820)
        .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 8)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTarget) { providers in load(providers); return true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let a = ImageAttachment.make(from: url) { attachments.append(a) }
            }
        }
        .onAppear { focused = true }
    }

    private func send() {
        guard canSend else { return }
        chat.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments,
                  in: conversationID, store: store, baseURL: engine.baseURL)
        text = ""
        attachments = []
    }

    private func load(_ providers: [NSItemProvider]) {
        guard settings.vision else { return }
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let a = ImageAttachment.make(from: url) else { return }
                    Task { @MainActor in attachments.append(a) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let a = ImageAttachment.make(from: img, name: "Geplakt") else { return }
                    Task { @MainActor in attachments.append(a) }
                }
            }
        }
    }
}

enum ImageAttachment {
    /// The vision tower takes at most ~1024 image tokens; larger pictures only cost prompt time.
    static let maxSide: CGFloat = 1344

    static func make(from url: URL) -> Attachment? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return make(from: img, name: url.lastPathComponent)
    }

    static func make(from image: NSImage, name: String) -> Attachment? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return Attachment(filename: name, jpeg: jpeg)
    }
}
