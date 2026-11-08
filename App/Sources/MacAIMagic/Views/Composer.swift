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
    @State private var pasteMonitor: Any?
    @State private var dropTarget = false
    @FocusState private var focused: Bool
    @ObservedObject private var voice = Voice.shared
    /// The text before speaking started: what is heard comes after it.
    @State private var beforeSpeaking = ""

    /// A question sent while the model is not loaded: it loads first, and the question goes when it is there.
    @State private var waitingForModel = false
    /// Stops listening and sends after a pause in speaking.
    @State private var silence: Task<Void, Never>?

    private var canSend: Bool {
        let modelThere = engine.state.isRunning || app.canStart || { if case .starting = engine.state { return true } else { return false } }()
        return modelThere && !waitingForModel && !chat.isBusy(conversationID)
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
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
            TextField(L("Vraag \(engine.model?.shortName ?? app.selectedModel?.shortName ?? "DeepSeek") iets…"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit(send)
                .onPasteCommand(of: [.image, .fileURL]) { providers in load(providers) }
                // while the field edits text, ⌘V goes straight to the text editor, which drops images: catch it first
                .onAppear { pasteMonitor = pasteMonitor ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "v", settings.vision,
                          let pasted = ImageAttachment.fromPasteboard(.general) else { return event }
                    attachments += pasted
                    return nil
                } }
                .onDisappear { if let m = pasteMonitor { NSEvent.removeMonitor(m) }; pasteMonitor = nil }
            HStack(spacing: 8) {
                Button { importing = true } label: { Image(systemName: "photo.badge.plus") }
                    .help(L("Afbeelding toevoegen")).disabled(!settings.vision)
                Toggle(isOn: $settings.thinking) { Label(L("Denken"), systemImage: "brain") }
                    .toggleStyle(.button).help(L("Laat het model eerst nadenken (beter, maar trager)"))
                Toggle(isOn: $settings.webSearch) { Label(L("Web"), systemImage: "globe") }
                    .toggleStyle(.button).help(L("Het model mag het web doorzoeken en pagina's lezen"))
                WorkspaceButton(conversationID: conversationID)
                RightsButton()
                Spacer()
                if settings.featureVoice {
                    Button {
                        if voice.listening { voice.stopListening() } else {
                            beforeSpeaking = text.isEmpty ? "" : text + " "
                            Task { await voice.startListening { heard in text = beforeSpeaking + heard } }
                        }
                    } label: {
                        Image(systemName: voice.listening ? "mic.fill" : "mic").font(.title3)
                            .foregroundStyle(voice.listening ? .red : .secondary)
                            .symbolEffect(.pulse, isActive: voice.listening)
                    }
                    .buttonStyle(.plain)
                    .help(voice.listening ? L("Stop met luisteren") : L("Inspreken (op deze Mac, niets gaat naar internet)"))
                    .popover(isPresented: Binding(get: { voice.problem != nil }, set: { if !$0 { voice.problem = nil } })) {
                        Text(voice.problem ?? "").padding().frame(width: 300)
                    }
                    .onChange(of: voice.heard) { _, heard in
                        // a pause of two seconds after speaking: the question is done, and it goes by itself
                        silence?.cancel()
                        guard voice.listening, !heard.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        silence = Task {
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, voice.listening, voice.heard == heard else { return }
                            send()
                        }
                    }
                }
                if waitingForModel {
                    ProgressView().controlSize(.small)
                    Text(L("Model laden, je vraag gaat daarna vanzelf")).font(.caption).foregroundStyle(.secondary)
                }
                if chat.isBusy(conversationID) {
                    Button { chat.stop(conversationID) } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.plain).help(L("Stop"))
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
            if chat.isBusy(conversationID) {
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
        if voice.listening { voice.stopListening() }
        silence?.cancel()
        guard canSend else { return }
        guard engine.state.isRunning else {
            // load the model first; the question waits in the field and goes as soon as the model is there
            waitingForModel = true
            Task {
                let ready = await app.ensureModel()
                waitingForModel = false
                if ready { send() }
            }
            return
        }
        chat.modelName = engine.model?.name ?? app.selectedModel?.name ?? L("DeepSeek-V4.1-Flash")
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
                    guard let img = obj as? NSImage, let a = ImageAttachment.make(from: img, name: L("Geplakt")) else { return }
                    Task { @MainActor in attachments.append(a) }
                }
            }
        }
    }
}

enum ImageAttachment {
    /// The vision tower takes at most ~1024 image tokens; larger pictures only cost prompt time.
    static let maxSide: CGFloat = 1344

    /// The images on a pasteboard (a screenshot, an image copied from an app, image files copied in the Finder); nil when
    /// it holds no image, so text pastes as usual.
    static func fromPasteboard(_ pb: NSPasteboard) -> [Attachment]? {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !urls.isEmpty {
            let list = urls.compactMap { make(from: $0) }
            return list.isEmpty ? nil : list
        }
        // copied text often carries a picture of itself too: text wins
        guard pb.string(forType: .string) == nil, pb.canReadObject(forClasses: [NSImage.self], options: nil),
              let img = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
              let a = make(from: img, name: L("Geplakt")) else { return nil }
        return [a]
    }

    static func make(from url: URL, minSide: CGFloat = 0) -> Attachment? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return make(from: img, name: url.lastPathComponent, minSide: minSide)
    }

    /// `minSide` enlarges a small picture (a 384-pixel emulator screen) with sharp pixels, so its letters stay readable
    /// for the vision tower, which sees an image in patches of 14 pixels.
    static func make(from image: NSImage, name: String, minSide: CGFloat = 0) -> Attachment? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let up = minSide > 0 && max(w, h) < minSide
        let scale = up ? (minSide / max(w, h)).rounded(.down) : min(1, maxSide / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if up { NSGraphicsContext.current?.cgContext.interpolationQuality = .none }
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

    /// On only when the model can really work here: this chat has a folder and the tools are on.
    private var active: Binding<Bool> {
        Binding(get: { settings.workspaceTools && folder != nil },
                set: { on in if on && folder == nil { choose() } else { settings.workspaceTools = on } })
    }

    var body: some View {
        HStack(spacing: 2) {
            Toggle(isOn: active) {
                Label(folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("Werkmap"), systemImage: "folder.badge.gearshape")
            }
            .toggleStyle(.button)
            .help(folder.map { L("Het model werkt in \($0) (rechten: knop L S U)") }
                  ?? L("Kies een map waarin het model in dit gesprek bestanden mag lezen, maken en scripts mag starten"))
            Menu {
                Button(L("Kies map voor dit gesprek…")) { choose() }
                if let folder {
                    Button(L("Toon in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                    Button(L("Geen werkmap in dit gesprek")) { store.update(conversationID) { $0.workspace = nil }; store.save() }
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
        panel.message = L("Kies de map waarin het model in dit gesprek mag werken")
        let start = folder ?? settings.workspace
        if !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start) }
        if panel.runModal() == .OK, let url = panel.url {
            store.update(conversationID) { $0.workspace = url.path }
            store.save()
            settings.workspace = url.path      // new chats start here
            settings.workspaceTools = true
        }
    }
}

/// The rights of the model in the work folder at a glance: L S U (lezen, schrijven, uitvoeren) in green (allowed),
/// orange (asks first) or red (denied); a click opens the matrix to change them.
struct RightsButton: View {
    @EnvironmentObject var settings: Settings
    @State private var open = false

    private func binding(_ r: WorkspaceTools.Right) -> Binding<String> {
        switch r {
        case .read: return $settings.rightRead
        case .write: return $settings.rightWrite
        case .run: return $settings.rightRun
        }
    }

    static func color(_ value: String) -> Color { value == "allow" ? Theme.mint : value == "deny" ? .red : Theme.amber }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                ForEach(WorkspaceTools.Right.allCases, id: \.self) { r in
                    Text(r.letter).font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(Self.color(binding(r).wrappedValue))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(L("Rechten van het model in de werkmap: Lezen, Schrijven, Uitvoeren. Groen = mag, oranje = eerst vragen, rood = nee."))
        .popover(isPresented: $open, arrowEdge: .top) { RightsMatrix() }
    }

}

/// The rights matrix: per kind of action Allow, Ask first or Deny.
struct RightsMatrix: View {
    @EnvironmentObject var settings: Settings

    private func binding(_ r: WorkspaceTools.Right) -> Binding<String> {
        switch r {
        case .read: return $settings.rightRead
        case .write: return $settings.rightWrite
        case .run: return $settings.rightRun
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Wat mag het model in de werkmap?")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                ForEach(WorkspaceTools.Right.allCases, id: \.self) { r in
                    GridRow {
                        Text(r.letter).font(.system(.title3, design: .rounded).weight(.heavy))
                            .foregroundStyle(RightsButton.color(binding(r).wrappedValue)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).fontWeight(.semibold)
                            Text(r.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("", selection: binding(r)) {
                            Text(L("Toestaan")).tag("allow")
                            Text(L("Eerst vragen")).tag("ask")
                            Text(L("Weigeren")).tag("deny")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 270)
                    }
                }
            }
            HStack {
                Button(L("Standaard")) { settings.rightRead = "allow"; settings.rightWrite = "ask"; settings.rightRun = "ask" }
                    .help(L("Lezen mag, schrijven en uitvoeren eerst vragen"))
                Button(L("Alles toestaan")) { settings.rightRead = "allow"; settings.rightWrite = "allow"; settings.rightRun = "allow" }
                Spacer()
                Text(L("Geldt voor alle gesprekken")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}
