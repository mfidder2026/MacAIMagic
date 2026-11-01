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
    @Binding var text: String
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
            TextField("Vraag \(engine.model?.shortName ?? app.selectedModel?.shortName ?? "DeepSeek") iets…", text: $text, axis: .vertical)
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
                WorkspaceButton(conversationID: conversationID)
                RightsButton()
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
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            // a turning gradient edge while the model writes; a calm one otherwise (no endless animation when idle)
            if chat.busy {
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(AngularGradient(colors: [Theme.cyan, Theme.accent, Theme.violet, Theme.pink, Theme.cyan], center: .center,
                                                angle: .degrees(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) * 90)),
                                lineWidth: 2)
                        .shadow(color: Theme.violet.opacity(0.7), radius: 10)
                }
            } else {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(dropTarget ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12)), lineWidth: dropTarget ? 2 : 1)
            }
        }
        .frame(maxWidth: 860)
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
        chat.modelName = engine.model?.name ?? app.selectedModel?.name ?? "DeepSeek-V4.1-Flash"
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

/// This chat's folder: shows its name, opens a picker, and switches the file tools on or off.
struct WorkspaceButton: View {
    let conversationID: Conversation.ID
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: ConversationStore

    private var folder: String? { store.conversations.first { $0.id == conversationID }?.workspace }

    var body: some View {
        HStack(spacing: 2) {
            Toggle(isOn: $settings.workspaceTools) {
                Label(folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Werkmap", systemImage: "folder.badge.gearshape")
            }
            .toggleStyle(.button)
            .help(folder.map { "Het model werkt in \($0) (schrijven en commando's na jouw toestemming)" }
                  ?? "Kies een map waarin het model in dit gesprek bestanden mag lezen, maken en scripts mag starten")
            .onChange(of: settings.workspaceTools) { _, on in if on && folder == nil { choose() } }
            Menu {
                Button("Kies map voor dit gesprek…") { choose() }
                if let folder {
                    Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                    Button("Geen werkmap in dit gesprek") { store.update(conversationID) { $0.workspace = nil }; store.save() }
                }
            } label: { EmptyView() }
            .menuStyle(.borderlessButton).frame(width: 16)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Kies de map waarin het model in dit gesprek mag werken"
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url {
            store.update(conversationID) { $0.workspace = url.path }
            store.save()
            settings.workspace = url.path      // new chats start here
            settings.workspaceTools = true
        } else if folder == nil {
            settings.workspaceTools = false
        }
    }
}

/// The rights of the model in the work folder at a glance: L S U (lezen, schrijven, uitvoeren) in green (allowed),
/// orange (asks first) or red (denied), with a menu to change them.
struct RightsButton: View {
    @EnvironmentObject var settings: Settings

    private func binding(_ r: WorkspaceTools.Right) -> Binding<String> {
        switch r {
        case .read: return $settings.rightRead
        case .write: return $settings.rightWrite
        case .run: return $settings.rightRun
        }
    }

    static func color(_ value: String) -> Color { value == "allow" ? Theme.mint : value == "deny" ? .red : Theme.amber }

    var body: some View {
        Menu {
            ForEach(WorkspaceTools.Right.allCases, id: \.self) { r in
                Picker("\(r.title): \(r.detail.lowercased())", selection: binding(r)) {
                    Label("Toestaan", systemImage: "checkmark.circle").tag("allow")
                    Label("Eerst vragen", systemImage: "questionmark.circle").tag("ask")
                    Label("Weigeren", systemImage: "nosign").tag("deny")
                }
                .pickerStyle(.inline)
            }
            Divider()
            Button("Alles toestaan") { settings.rightRead = "allow"; settings.rightWrite = "allow"; settings.rightRun = "allow" }
            Button("Standaard (lezen mag, de rest eerst vragen)") { settings.rightRead = "allow"; settings.rightWrite = "ask"; settings.rightRun = "ask" }
        } label: {
            HStack(spacing: 3) {
                ForEach(WorkspaceTools.Right.allCases, id: \.self) { r in
                    Text(r.letter).font(.system(size: 11, weight: .heavy, design: .rounded).monospaced())
                        .foregroundStyle(Self.color(binding(r).wrappedValue))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Rechten van het model in de werkmap: Lezen, Schrijven, Uitvoeren. Groen = mag, oranje = eerst vragen, rood = nee.")
    }
}
