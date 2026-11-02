import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The documents module: projects with attachments, a house style and documents. Say what you want made; the model
/// reads the attachments, searches the web for what they do not say, and the house style's layout comes last.
struct DocumentsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var studio: DocumentStudio
    @EnvironmentObject var engine: EngineController
    @State private var askingProjectName = false
    @State private var projectName = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 270)
            Divider().opacity(0.3)
            Group {
                switch studio.page {
                case .project: ProjectPage()
                case .newDocument: NewDocumentPage()
                case .draft: DraftPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { studio.appeared() }
        .sheet(isPresented: $askingProjectName) { newProjectSheet }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Documenten")).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(L("Alle tekst blijft op deze Mac. Naar internet gaan alleen zoekvragen en het ophalen van pagina's.")).font(.caption).foregroundStyle(.secondary)
            }
            projectMenu
            Button { studio.page = .newDocument } label: {
                Label(L("Maak een document"), systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(DocumentActionStyle()).disabled(studio.busy)
            sideButton(L("Bijlagen, huisstijl en gegevens"), icon: "folder.badge.gearshape", active: studio.page == .project) { studio.page = .project }
            Text(L("Documenten in dit project")).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if studio.drafts.isEmpty {
                        Text(L("Nog geen documenten.")).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(studio.drafts, id: \.self) { url in
                        sideButton(url.deletingPathExtension().lastPathComponent, icon: "doc.plaintext", active: studio.page == .draft && studio.selected == url) { studio.open(url) }
                            .disabled(studio.busy)
                            .contextMenu {
                                Button(L("Toon in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button(L("Naar de prullenbak"), role: .destructive) { studio.delete(url) }
                            }
                    }
                }
            }
            modelsCard
        }
        .padding(16)
    }

    private var projectMenu: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Project")).font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(studio.projects, id: \.self) { url in
                    Button { studio.choose(folder: url) } label: {
                        if url.standardizedFileURL == studio.folder.standardizedFileURL { Label(url.lastPathComponent, systemImage: "checkmark") } else { Text(url.lastPathComponent) }
                    }
                }
                Divider()
                Button(L("Nieuw project…")) {
                    projectName = ""
                    askingProjectName = true
                }
                Button(L("Open een bestaande map…"), action: chooseFolder)
                Button(L("Toon in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([studio.folder]) }
            } label: {
                Label(studio.folder.lastPathComponent, systemImage: "folder.fill").font(.headline).lineLimit(1)
            }
            .disabled(studio.busy)
        }
    }

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Nieuw project")).font(.title2.bold())
            TextField(L("Naam van het project"), text: $projectName).textFieldStyle(.roundedBorder).frame(width: 340)
            HStack {
                Spacer()
                Button(L("Annuleer")) { askingProjectName = false }
                Button(L("Maak project")) {
                    askingProjectName = false
                    studio.createProject(name: projectName)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
    }

    private func sideButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(active ? Theme.accent.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Modellen")).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "brain").frame(width: 18).foregroundStyle(Theme.cyan)
                    Text(L("Zwaar")).font(.callout)
                    Text(app.selectedModel?.shortName ?? L("Geen model")).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Circle().fill(engine.state.isRunning ? Theme.mint : .secondary.opacity(0.4)).frame(width: 7, height: 7)
                }
                Text(engine.state.statusText(idle: L("Start vanzelf als er geschreven wordt."))).font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
            }
            if let fast = app.documentEngines.fastChoice {
                FastModelRow(engines: app.documentEngines, engine: app.documentEngines.fast, name: fast.shortName)
            } else {
                Text(L("Eén model voor alles: er past geen tweede model naast op deze Mac, of er is er geen gedownload."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = studio.folder
        panel.message = L("Kies de map van het project: daar komen de concepten en documenten")
        if panel.runModal() == .OK, let url = panel.url { studio.choose(folder: url) }
    }
}

// MARK: - project

/// What holds for all documents of the project: entered once.
private struct ProjectPage: View {
    @EnvironmentObject var studio: DocumentStudio
    @State private var newField = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(studio.folder.lastPathComponent).font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(L("Wat je hier zet, geldt voor elk document in dit project.")).foregroundStyle(.secondary)
                }
                section(L("Bijlagen"), icon: "paperclip", detail: L("De context en informatie: wat een document moet bevatten, verslagen, afspraken. Het model kijkt hier als eerste.")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(studio.attachments, id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { studio.removeAttachment(url) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                        Button(action: chooseAttachment) { Label(L("Voeg bijlagen toe…"), systemImage: "plus") }
                            .buttonStyle(DocumentActionStyle(prominent: false))
                    }
                }
                section(L("Huisstijl"), icon: "paintbrush.fill", detail: L("Alleen de opmaak: voorblad, kop- en voettekst, koppen en tabellen. Die wordt als laatste op het document toegepast.")) {
                    HStack(spacing: 10) {
                        if let style = studio.houseStyle {
                            Image(systemName: "doc.richtext.fill").foregroundStyle(Theme.amber)
                            Text(style.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(L("Eenvoudig (ingebouwd)")).foregroundStyle(.secondary)
                        }
                        Button(action: chooseHouseStyle) { Text(studio.houseStyle == nil ? L("Kies een Word-bestand…") : L("Vervang…")) }
                            .buttonStyle(DocumentActionStyle(prominent: false))
                    }
                }
                section(L("Gegevens voor het voorblad"), icon: "list.bullet.rectangle", detail: L("Een veld dat hier is ingevuld, hoef je nooit meer in te vullen.")) {
                    fields
                }
                DocumentStatus()
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private func section(_ title: String, icon: String, detail: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 7) {
            if studio.project.fields.isEmpty {
                Text(L("Nog geen velden. Ze komen vanzelf uit de huisstijl.")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach($studio.project.fields) { $field in
                HStack(spacing: 10) {
                    Text(field.key).frame(width: 170, alignment: .trailing).lineLimit(1).truncationMode(.middle)
                    TextField("", text: $field.value).textFieldStyle(.roundedBorder)
                    Button { studio.project.fields.removeAll { $0.id == field.id } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                TextField(L("Nieuw veld"), text: $newField).textFieldStyle(.roundedBorder).frame(width: 170)
                Button(L("Voeg toe")) {
                    studio.project.fields.append(.init(key: newField.trimmingCharacters(in: .whitespaces), value: ""))
                    newField = ""
                }
                .disabled(newField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func chooseHouseStyle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["docx", "dotx"].compactMap { UTType(filenameExtension: $0) }
        panel.message = L("Kies een Word-bestand in de huisstijl van het project; de app bewaart er een kopie van in de projectmap")
        if panel.runModal() == .OK, let url = panel.url { studio.useHouseStyle(url) }
    }

    private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["docx", "dotx", "pdf", "txt", "md"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(studio.addAttachment) }
    }
}

// MARK: - new document

private struct NewDocumentPage: View {
    @EnvironmentObject var studio: DocumentStudio
    @State private var request = ""
    @State private var useWeb = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Wat wil je maken?")).font(.system(size: 28, weight: .bold, design: .rounded))
                LargeInput(text: $request, placeholder: L("Bijvoorbeeld: maak een AQS voor deze applicatie, of: welke eisen stelt de BIO aan multi-factor authenticatie?"), height: 220)
                route
                Toggle(isOn: $useWeb) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Op internet zoeken als de bijlagen niet genoeg zeggen")).font(.callout.weight(.semibold))
                        Text(L("Bijvoorbeeld over het onderwerp en regelgeving. Namen en gegevens van het project gaan niet mee.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                HStack(spacing: 10) {
                    Button {
                        studio.make(request: request, useWeb: useWeb)
                        request = ""
                    } label: { Label(L("Maak het document"), systemImage: "sparkles") }
                        .buttonStyle(DocumentActionStyle())
                        .disabled(isEmpty || studio.busy)
                    Button {
                        studio.newDocument(name: isEmpty ? L("Nieuw document") : DocumentStudio.fileName(request))
                        request = ""
                    } label: { Text(L("Leeg document: zelf schrijven")) }
                        .buttonStyle(DocumentActionStyle(prominent: false))
                        .disabled(studio.busy)
                    Spacer()
                    if studio.busy {
                        Button(role: .destructive) { studio.stop() } label: { Label(L("Stop"), systemImage: "stop.fill") }
                    }
                }
                DocumentStatus()
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var isEmpty: Bool { request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The way the document goes, with what this project has.
    private var route: some View {
        VStack(alignment: .leading, spacing: 4) {
            routeLine("1", L("Bijlagen: \(studio.attachments.isEmpty ? L("nog geen") : String(studio.attachments.count)). Hierin zoekt het model waaruit het document moet bestaan."))
            routeLine("2", L("Internet: alleen voor wat de bijlagen niet zeggen."))
            routeLine("3", L("Concept in Markdown: daarin pas je alle tekst aan."))
            routeLine("4", L("Huisstijl als laatste: \(studio.houseStyle?.lastPathComponent ?? L("Eenvoudig (ingebouwd)"))."))
        }
    }

    private func routeLine(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number).font(.callout.weight(.bold)).foregroundStyle(Theme.cyan).frame(width: 14)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - a draft

private struct DraftPage: View {
    @EnvironmentObject var studio: DocumentStudio
    @State private var request = ""
    @State private var preview = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            editor
            if !studio.steps.isEmpty || studio.problem != nil || !studio.notes.isEmpty || studio.report != nil {
                Divider().opacity(0.3)
                DocumentStatus().padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider().opacity(0.3)
            composer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(studio.selected?.deletingPathExtension().lastPathComponent ?? "").font(.headline).lineLimit(1).truncationMode(.middle)
                Text(L("Huisstijl: \(studio.houseStyle?.lastPathComponent ?? L("Eenvoudig (ingebouwd)"))")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if studio.previous != nil, !studio.busy { Button(L("Ongedaan maken")) { studio.undo() } }
            Picker("", selection: $preview) {
                Text(L("Markdown")).tag(false)
                Text(L("Voorbeeld")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Button { studio.deliver() } label: { Label(L("Goedkeuren en maak .docx"), systemImage: "doc.richtext.fill") }
                .buttonStyle(DocumentActionStyle())
                .disabled(studio.selected == nil || studio.busy)
                .help(L("Zet dit concept in de huisstijl van het project. Een eerder .docx-bestand blijft staan."))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var editor: some View {
        if preview {
            ScrollView {
                MarkdownText(text: DocumentDraft(markdown: studio.text).body)
                    .frame(maxWidth: 760, alignment: .leading).padding(24)
                    .frame(maxWidth: .infinity)
            }
        } else {
            MarkdownEditor(text: $studio.text, selection: $studio.selection, editable: !studio.busy)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("Op \(studio.scopeTitle):")).font(.callout.weight(.semibold))
                ForEach(DocumentStudio.QuickAction.allCases, id: \.self) { a in
                    Button { studio.apply(a) } label: { Label(a.title, systemImage: "bolt.fill") }
                        .buttonStyle(DocumentActionStyle(prominent: false, small: true))
                        .disabled(studio.busy)
                        .help(L("Met het snelle model, op de selectie of anders op de sectie waar de cursor staat."))
                }
                Spacer()
                if studio.busy {
                    Button(role: .destructive) { studio.stop() } label: { Label(L("Stop"), systemImage: "stop.fill") }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                LargeInput(text: $request, placeholder: L("Schrijf wat er in dit stuk moet veranderen…"), height: 96)
                VStack(spacing: 8) {
                    Button {
                        studio.apply(instruction: request)
                        request = ""
                    } label: { Label(L("Pas aan"), systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                        .buttonStyle(DocumentActionStyle())
                        .disabled(isEmptyRequest || studio.busy)
                        .help(L("Met het zware model, op de selectie of anders op de sectie waar de cursor staat."))
                    Button {
                        studio.writeAllSections(request: request)
                        request = ""
                    } label: { Label(L("Schrijf alle secties"), systemImage: "text.badge.plus").frame(maxWidth: .infinity) }
                        .buttonStyle(DocumentActionStyle(prominent: false))
                        .disabled(studio.busy)
                        .help(L("Schrijft elke sectie onder de koppen van dit concept opnieuw, uit de bijlagen en deze opdracht."))
                }
                .frame(width: 200)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var isEmptyRequest: Bool { request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The steps of the running work, what went wrong, and the finished document.
private struct DocumentStatus: View {
    @EnvironmentObject var studio: DocumentStudio

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !studio.steps.isEmpty {
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
                    .frame(maxHeight: 92)
                    .onChange(of: studio.steps.count) { _, _ in if let last = studio.steps.last { proxy.scrollTo(last.id) } }
                }
            }
            if let p = studio.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(studio.notes, id: \.self) { n in
                Label(n, systemImage: "eye.fill").font(.callout).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            if let r = studio.report { result(r) }
        }
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
            ForEach(r.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// A big field for text with several lines.
private struct LargeInput: View {
    @Binding var text: String
    let placeholder: String
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 10).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .font(.body)
                .padding(.horizontal, 7).padding(.vertical, 10)
        }
        .frame(height: height)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.16)))
    }
}

/// A button whose text stays readable when it cannot be used yet.
private struct DocumentActionStyle: ButtonStyle {
    var prominent = true
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .callout.weight(.medium) : .body.weight(.semibold))
            .foregroundStyle(enabled ? .white : .white.opacity(0.62))
            .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 5 : 9)
            .background(fill(configuration.isPressed), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(prominent && enabled ? 0 : 0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fill(_ pressed: Bool) -> Color {
        if !enabled { return .white.opacity(0.07) }
        if prominent { return Theme.accent.opacity(pressed ? 0.75 : 1) }
        return .white.opacity(pressed ? 0.2 : 0.12)
    }
}

/// Follows the second engine, which the view above does not observe: what it is doing, why it does not run, and
/// the button to start or stop it. It also starts by itself when there is small work.
private struct FastModelRow: View {
    @EnvironmentObject var studio: DocumentStudio
    @ObservedObject var engines: DocumentEngines
    @ObservedObject var engine: EngineController
    let name: String

    private var loading: Bool {
        if case .starting = engine.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").frame(width: 18).foregroundStyle(Theme.cyan)
                Text(L("Snel")).font(.callout)
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Circle().fill(engine.state.isRunning ? Theme.mint : .secondary.opacity(0.4)).frame(width: 7, height: 7)
            }
            if let problem = engines.fastProblem {
                Text(L("Start niet; het zware model doet dit werk nu. \(problem)")).font(.caption).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
            } else {
                Text(engine.state.statusText(idle: L("Start vanzelf bij de eerste snelle actie."))).font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
            }
            HStack {
                if engine.state.isRunning || loading {
                    Button(L("Stop")) { engines.stopFast() }.disabled(studio.busy)
                } else {
                    Button(engines.fastProblem == nil ? L("Start nu") : L("Probeer opnieuw")) { engines.startFastNow() }
                }
            }
            .buttonStyle(DocumentActionStyle(prominent: false, small: true))
            .padding(.leading, 24)
        }
    }
}

extension EngineController.State {
    /// What the state means, in the words of the documents module.
    func statusText(idle: String) -> String {
        switch self {
        case .running: return L("Draait")
        case .starting(let what): return what
        case .failed(let why): return why
        case .stopped: return idle
        }
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
