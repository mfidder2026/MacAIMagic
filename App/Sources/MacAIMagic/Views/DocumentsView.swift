import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The documents module: ask a question or start from the house style, change all text in Markdown, and get the
/// .docx last.
struct DocumentsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var studio: DocumentStudio
    @EnvironmentObject var engine: EngineController
    @State private var request = ""
    @State private var preview = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
            Divider().opacity(0.3)
            VStack(spacing: 0) {
                toolbar
                Divider().opacity(0.3)
                editor
                if !studio.steps.isEmpty || studio.problem != nil || !studio.notes.isEmpty || studio.report != nil {
                    Divider().opacity(0.3)
                    status
                }
                Divider().opacity(0.3)
                composer
            }
        }
        .onAppear { studio.appeared() }
    }

    // MARK: - left

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Documenten")).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(L("Alle tekst blijft op deze Mac. Naar internet gaan alleen zoekvragen en het ophalen van pagina's.")).font(.caption).foregroundStyle(.secondary)
                }
                setting(L("Project"), icon: "folder.fill", value: studio.folder.lastPathComponent, help: studio.folder.path, button: L("Kies…"), action: chooseFolder)
                setting(L("Huisstijl"), icon: "paintbrush.fill",
                        value: studio.template?.lastPathComponent ?? L("Eenvoudig (ingebouwd)"),
                        help: L("Een Word-bestand (.docx of .dotx) waarvan de app voorblad, kop- en voettekst, kopstijlen en tabellen overneemt."),
                        button: L("Kies…"), action: chooseTemplate)
                modelsCard
                materialCard
                draftsCard
            }
            .padding(16)
        }
    }

    private func setting(_ title: String, icon: String, value: String, help: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.amber).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small)
        }
        .help(help)
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Modellen")).font(.caption).foregroundStyle(.secondary)
            modelRow(L("Zwaar"), icon: "brain", name: app.selectedModel?.shortName ?? L("Geen model"), running: engine.state.isRunning)
            if let fast = app.documentEngines.fastChoice {
                FastModelRow(engine: app.documentEngines.fast, name: fast.shortName)
            } else {
                Text(L("Eén model voor alles: er past geen tweede model naast op deze Mac, of er is er geen gedownload."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modelRow(_ role: String, icon: String, name: String, running: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.cyan)
            Text(role).font(.callout)
            Text(name).font(.callout.weight(.medium)).lineLimit(1)
            Spacer()
            Circle().fill(running ? Theme.mint : .secondary.opacity(0.4)).frame(width: 7, height: 7)
        }
    }

    private var materialCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("Bijlagen")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Voeg toe…"), action: chooseMaterial).controlSize(.small)
            }
            ForEach(studio.material, id: \.name) { m in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").foregroundStyle(.secondary)
                    Text(m.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { studio.removeMaterial(m.name) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var draftsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Concepten")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Nieuw")) { studio.newDraft(name: L("Nieuw document")) }.controlSize(.small).disabled(studio.busy)
            }
            if studio.drafts.isEmpty {
                Text(L("Nog geen concepten in deze map.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(studio.drafts, id: \.self) { url in
                Button { studio.open(url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.plaintext")
                        Text(url.deletingPathExtension().lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(studio.selected == url ? Theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(studio.busy)
                .contextMenu {
                    Button(L("Toon in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button(L("Naar de prullenbak"), role: .destructive) { studio.delete(url) }
                }
            }
        }
    }

    // MARK: - right

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(studio.selected?.lastPathComponent ?? L("Geen concept gekozen")).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer()
            if studio.previous != nil, !studio.busy {
                Button(L("Ongedaan maken")) { studio.undo() }
            }
            Picker("", selection: $preview) {
                Text(L("Markdown")).tag(false)
                Text(L("Voorbeeld")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Button { studio.deliver() } label: { Label(L("Goedkeuren en maak .docx"), systemImage: "doc.richtext.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(studio.selected == nil || studio.busy)
                .help(L("Zet dit concept in de huisstijl van het project. Een eerder .docx-bestand blijft staan."))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var editor: some View {
        if studio.selected == nil && !studio.busy {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 42)).foregroundStyle(Theme.brand)
                Text(L("Stel hieronder een vraag, of begin met Nieuw uit de huisstijl.")).font(.title3)
                Text(L("De app zoekt eerst online, schrijft een concept in Markdown met bronnen, en maakt pas het Word-bestand als jij het goedkeurt."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if preview {
            ScrollView {
                MarkdownText(text: DocumentDraft(markdown: studio.text).body)
                    .frame(maxWidth: 760, alignment: .leading).padding(24)
                    .frame(maxWidth: .infinity)
            }
        } else {
            MarkdownEditor(text: $studio.text, selection: $studio.selection, editable: !studio.busy)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(studio.steps) { s in
                            HStack(spacing: 6) {
                                switch s.state {
                                case .running: ProgressView().controlSize(.mini).frame(width: 14)
                                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint).frame(width: 14)
                                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.amber).frame(width: 14)
                                }
                                Text(s.text).font(.callout).lineLimit(1).truncationMode(.middle)
                            }
                            .id(s.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: studio.steps.isEmpty ? 0 : 92)
                .onChange(of: studio.steps.count) { _, _ in if let last = studio.steps.last { proxy.scrollTo(last.id) } }
            }
            if let p = studio.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(studio.notes, id: \.self) { n in
                Label(n, systemImage: "eye.fill").font(.callout).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            if let r = studio.report { result(r) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func result(_ r: DocxCompose.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = r.url {
                HStack(spacing: 8) {
                    Image(systemName: r.problems.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.problems.isEmpty ? Theme.mint : Theme.amber)
                    Text(url.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Open")) { NSWorkspace.shared.open(url) }
                    Button(L("Toon in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            ForEach(r.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.amber) }
            ForEach(r.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(DocumentStudio.QuickAction.allCases, id: \.self) { a in
                    Button { studio.apply(a) } label: { Label(a.title, systemImage: "bolt.fill") }
                        .controlSize(.small)
                        .disabled(studio.selected == nil || studio.busy)
                        .help(L("Met het snelle model, op de selectie of anders op de sectie waar de cursor staat."))
                }
                Spacer()
                if studio.busy {
                    Button(role: .destructive) { studio.stop() } label: { Label(L("Stop"), systemImage: "stop.fill") }.controlSize(.small)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Stel een vraag, of schrijf wat er moet gebeuren…"), text: $request, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                Button { studio.research(question: request); clearRequest() } label: { Label(L("Zoek online en schrijf"), systemImage: "globe") }
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmptyRequest || studio.busy)
                    .help(L("Zoekt eerst op internet, leest de pagina's en schrijft een nieuw concept met bronnen."))
                Button { studio.writeDraft(brief: request); clearRequest() } label: { Label(L("Vul het concept"), systemImage: "text.badge.plus") }
                    .disabled(isEmptyRequest || studio.selected == nil || studio.busy)
                    .help(L("Schrijft elke sectie van dit concept met het zware model, uit deze opdracht en de bijlagen."))
                Button { studio.apply(instruction: request); clearRequest() } label: { Label(L("Pas aan"), systemImage: "wand.and.stars") }
                    .disabled(isEmptyRequest || studio.selected == nil || studio.busy)
                    .help(L("Met het zware model, op de selectie of anders op de sectie waar de cursor staat."))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var isEmptyRequest: Bool { request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func clearRequest() { request = "" }

    // MARK: - choosing files

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = studio.folder
        panel.message = L("Kies de map van het project: daar komen de concepten en documenten")
        if panel.runModal() == .OK, let url = panel.url { studio.choose(folder: url) }
    }

    private func chooseTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["docx", "dotx"].compactMap { UTType(filenameExtension: $0) }
        panel.message = L("Kies een Word-bestand in de huisstijl van het project; de app bewaart er een kopie van in de projectmap")
        if panel.runModal() == .OK, let url = panel.url { studio.useTemplate(url) }
    }

    private func chooseMaterial() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["docx", "dotx", "pdf", "txt", "md"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(studio.addMaterial) }
    }
}

/// Follows the second engine, which the view above does not observe.
private struct FastModelRow: View {
    @ObservedObject var engine: EngineController
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").frame(width: 18).foregroundStyle(Theme.cyan)
            Text(L("Snel")).font(.callout)
            Text(name).font(.callout.weight(.medium)).lineLimit(1)
            Spacer()
            Circle().fill(engine.state.isRunning ? Theme.mint : .secondary.opacity(0.4)).frame(width: 7, height: 7)
        }
        .help(L("Start vanzelf bij de eerste snelle actie."))
    }
}

/// A text view that shows the selection, so an action can work on it. SwiftUI's own gets that only from macOS 15.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 20, height: 16)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        view.isEditable = editable
        guard view.string != text else { return }
        // while a model writes the view follows its text; the place of the cursor only matters while typing
        let atEnd = scroll.verticalScroller.map { $0.floatValue > 0.98 } ?? true
        view.string = text
        if !editable && atEnd { view.scrollToEndOfDocument(nil) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            let range = view.selectedRange()
            DispatchQueue.main.async { [weak self] in self?.parent.selection = range }
        }
    }
}
