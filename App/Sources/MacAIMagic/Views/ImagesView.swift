import AppKit
import SwiftUI

/// Makes images from a description, on this Mac. The model comes down here too; it is not one of the models the chat can choose.
struct ImagesView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var images: ImageMaker
    @EnvironmentObject var models: ModelStore
    @ObservedObject private var settings = Settings.shared
    @State private var prompt = ""
    @State private var shown: ImageResult?

    private var model: ModelInfo? { app.imageModel }
    private var status: ModelStore.ModelStatus { model.map { models.status($0.id) } ?? ModelStore.ModelStatus() }
    private var size: ImageSize {
        if let chosen = ImageSize(key: settings.imageSize), ImagePlanner.sizes.contains(chosen) { return chosen }
        return ImagePlanner.defaultSize(app.system)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "photo.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Beeld")).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(L("Maakt afbeeldingen op deze Mac. Je beschrijving gaat niet naar buiten.")).foregroundStyle(.secondary)
                    }
                }
                // first the download; once the model is here, the images come first and the model moves to the end
                if !status.isComplete { modelCard }
                makeCard
                if let image = shown ?? images.last { resultCard(image) }
                let list = images.history()
                if !list.isEmpty { galleryCard(list) }
                if status.isComplete { modelCard }
            }
            .padding(28)
        }
        .onChange(of: images.last) { _, new in if let new { shown = new } }
    }

    private var modelCard: some View {
        GlassCard(title: L("Model"), icon: "square.stack.3d.up.fill", glow: Theme.violet) {
            if let model {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.system(.title3, design: .rounded).weight(.bold))
                    Text(L(key: model.summary)).font(.caption).foregroundStyle(.secondary)
                }
                if !status.isComplete { ProgressView(value: status.fraction).tint(Theme.violet) }
                HStack {
                    if status.isComplete {
                        Text(L("\(status.expected.gbShort) op schijf")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("\(status.have.gbShort) van \(status.expected.gbShort)")).font(.caption).foregroundStyle(.secondary)
                        if let eta = models.etaSeconds(model.id) {
                            Text(L("· \(String(format: "%.0f MB/s", models.speed / 1e6)) · nog \(duration(eta))")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !status.isComplete && !models.downloading.contains(model.id), status.expected - status.have > app.system.freeDisk {
                    Text(L("Op deze schijf is \(app.system.freeDisk.gbShort) vrij; \(model.name) heeft nog \((status.expected - status.have).gbShort) nodig."))
                        .font(.caption).foregroundStyle(Theme.amber)
                }
                if let problem = models.lastError[model.id] {
                    Text(problem).font(.caption).foregroundStyle(Theme.pink).fixedSize(horizontal: false, vertical: true)
                }
                if !status.isComplete {
                    if models.downloading.contains(model.id) {
                        Button(L("Pauzeer")) { models.stopDownload(model.id) }
                    } else {
                        Button { models.startDownload(model.id) } label: { Label(L("Download"), systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(.borderedProminent).tint(Theme.violet)
                    }
                }
            }
        }
    }

    private var makeCard: some View {
        GlassCard(title: L("Beschrijf wat je wilt zien"), icon: "photo", glow: Theme.violet) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden).frame(height: 96).disabled(images.busy)
                if prompt.isEmpty {
                    Text(L("Bijvoorbeeld: een rode vos die de krant leest op een bankje in Amsterdam, herfstlicht, foto"))
                        .foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 1).allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Picker(L("Grootte"), selection: Binding(get: { size.key }, set: { settings.imageSize = $0 })) {
                    ForEach(ImagePlanner.sizes) { Text(label($0)).tag($0.key) }
                }
                .fixedSize().disabled(images.busy)
                Toggle(isOn: $settings.imageImprove) {
                    Label(L("Verbeteren met web"), systemImage: "globe")
                }
                .toggleStyle(.button).disabled(images.busy)
                .help(L("\(app.selectedModel?.shortName ?? L("Het chatmodel")) schrijft eerst een betere Engelse beschrijving en zoekt zo nodig op het web hoe iets eruitziet. Dat kost wat tijd."))
                if images.busy {
                    Button(L("Stop")) { images.stop() }
                } else {
                    Button { app.makeImage(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), size: size) } label: {
                        Label(L("Maak afbeelding"), systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.violet)
                    .disabled(!status.isComplete || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(!status.isComplete ? L("Download eerst het model.") : prompt.isEmpty ? L("Beschrijf eerst wat je wilt zien.") : "")
                }
                Spacer()
            }
            // who does what: the image model always, the model that writes the description when the switch is on
            HStack(spacing: 14) {
                if settings.imageImprove {
                    if let writer = app.describer {
                        roleLabel(icon: "text.bubble", text: L("Beschrijving: \(writer.model.name) (\(writer.role))"))
                    } else {
                        roleLabel(icon: "text.bubble", text: L("Beschrijving: geen chatmodel gedownload"))
                    }
                }
                roleLabel(icon: "photo", text: L("Afbeelding: \(model?.name ?? L("geen model"))"))
            }
            if images.busy { ProgressView(value: images.fraction).tint(Theme.violet) }
            if !images.steps.isEmpty { stepList }
            let plan = ImagePlanner.plan(size, app.system)
            Text(plan.onGPU ? L("Op de GPU duurt een afbeelding seconden tot een minuut.")
                            : L("Op de processor duurt een afbeelding minuten. Hoe lang precies hangt af van deze Mac en de grootte.")
                                + (plan.tiling ? " " + L("Op dit geheugen werkt de laatste stap in delen, en dat duurt langer.") : ""))
                .font(.caption).foregroundStyle(.secondary)

            Text(L("Het model volgt een beschrijving in het Engels het best: in het Nederlands mist het soms waar het om gaat."))
                .font(.caption).foregroundStyle(.secondary)
            if settings.imageImprove, !images.busy, let writer = app.describer {
                Text(writerNote(writer)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note = images.note { Text(note).font(.caption).foregroundStyle(Theme.amber) }
            if let error = images.error { Text(error).font(.caption).foregroundStyle(Theme.pink) }
        }
    }

    private func resultCard(_ image: ImageResult) -> some View {
        GlassCard(title: L("Afbeelding"), icon: "photo.fill", glow: Theme.violet) {
            if let picture = NSImage(contentsOfFile: image.path) {
                Image(nsImage: picture).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 620, alignment: .leading)
            }
            if !image.prompt.isEmpty { Text(image.prompt).textSelection(.enabled) }
            if let used = image.usedPrompt {
                DisclosureGroup(L("Beschrijving voor het beeldmodel")) {
                    Text(used).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            if image.path == images.last?.path, !images.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(images.sources.prefix(10)) { s in
                            Link(destination: URL(string: s.url) ?? URL(string: "about:blank")!) {
                                Label(URL(string: s.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? s.url, systemImage: "globe")
                                    .font(.caption).lineLimit(1)
                            }
                            .help(s.title)
                        }
                    }
                }
            }
            Text(image.seconds > 0
                 ? L("\(image.width) × \(image.height) · \(clock(image.seconds)) \(place(image)) · nummer \(image.seed)")
                 : (image.path as NSString).lastPathComponent)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(L("Kopieer")) {
                    NSPasteboard.general.clearContents()
                    if let picture = NSImage(contentsOfFile: image.path) { NSPasteboard.general.writeObjects([picture]) }
                }
                Button(L("Toon in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: image.path)]) }
                Button(L("Verwijderen")) { images.remove(image); shown = nil }
            }
        }
    }

    private func galleryCard(_ list: [ImageResult]) -> some View {
        GlassCard(title: L("Eerdere afbeeldingen"), icon: "clock", glow: Theme.cyan) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(list) { item in
                    Button { shown = item } label: {
                        Group {
                            if let picture = NSImage(contentsOfFile: item.path) { Image(nsImage: picture).resizable().scaledToFill() }
                            else { Color.white.opacity(0.05) }
                        }
                        .frame(width: 132, height: 132).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(item.prompt.isEmpty ? (item.path as NSString).lastPathComponent : item.prompt)
                }
            }
        }
    }

    private func roleLabel(icon: String, text: String) -> some View {
        Label(text, systemImage: icon).font(.callout).foregroundStyle(.secondary).lineLimit(1)
    }

    /// What will happen before the image, in plain words: which model starts, and what makes room.
    private func writerNote(_ writer: AppState.Describer) -> String {
        let target = writer.onFast ? app.documentEngines.fast : app.engine
        let runs = target.state.isRunning && target.model?.id == writer.model.id
        let first = runs ? L("\(writer.model.shortName) draait al en schrijft eerst een Engelse beschrijving; zo nodig zoekt het op het web hoe iets eruitziet.")
                         : L("\(writer.model.shortName) start eerst (enkele seconden tot minuten) en schrijft een Engelse beschrijving; zo nodig zoekt het op het web hoe iets eruitziet.")
        return first + " " + L("Is er daarna te weinig geheugen voor de afbeelding, dan stopt een model om ruimte te maken; dat zie je in de stappen.")
    }

    /// Each step with the model that does it: a spinner while it runs, a check when done, a cross when it failed.
    private var stepList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(images.steps) { s in
                HStack(spacing: 8) {
                    switch s.state {
                    case .running: ProgressView().controlSize(.small).frame(width: 16)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint).frame(width: 16)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.amber).frame(width: 16)
                    }
                    Text(s.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    if s.state == .running {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(clock(context.date.timeIntervalSince(s.started))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func place(_ image: ImageResult) -> String { image.onGPU ? L("op de GPU") : L("op de processor") }

    private func label(_ s: ImageSize) -> String {
        let text = "\(s.width) × \(s.height)"
        return s.width > s.height ? text + " " + L("(liggend)") : s.width < s.height ? text + " " + L("(staand)") : text
    }

    private func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }

    private func duration(_ seconds: Double) -> String { seconds > 3600 ? String(format: "%.0f u %.0f min", seconds / 3600, seconds.truncatingRemainder(dividingBy: 3600) / 60) : String(format: "%.0f min", seconds / 60) }
}
