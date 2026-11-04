import SwiftUI

/// The models: one card each (download, select, start), then the selected model's plan, engine and API.
struct ModelsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var models: ModelStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Modellen")).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(L("\(app.system.chip) · \(app.system.physicalMemory >> 30) GB unified · \(app.system.freeDisk.gbShort) vrij op schijf"))
                            .foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                    ForEach(models.catalog.models) { m in ModelCard(model: m) }
                }
                if let plan = app.plan {
                    PlanStrip(plan: plan)
                    PlanDetails(plan: plan)
                }
                EngineCard()
                APICard()
                FolderCard()
            }
            .padding(28)
        }
        .onChange(of: models.status(app.selectedModelID).headersAvailable) { _, ok in if ok { app.loadIndex() } }
        .onAppear { app.refreshSystem(); app.loadIndex() }
    }
}

private struct ModelCard: View {
    let model: ModelInfo
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var models: ModelStore
    @State private var hover = false

    private var status: ModelStore.ModelStatus { models.status(model.id) }
    private var selected: Bool { app.selectedModelID == model.id }
    private var running: Bool { engine.model?.id == model.id && engine.state.isRunning }
    /// Does the model fit in this Mac's memory, stream from the SSD, or not run here at all?
    private var fit: MemoryPlanner.Fit { MemoryPlanner.fit(model, physical: app.system.physicalMemory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 5)
                    Circle().trim(from: 0, to: status.fraction)
                        .stroke(Theme.familyGradient(model.family), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: Theme.family(model.family).opacity(0.7), radius: 5)
                    Image(systemName: status.isComplete ? "checkmark" : (models.downloading.contains(model.id) ? "arrow.down" : "icloud.and.arrow.down"))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.family(model.family))
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.system(.title3, design: .rounded).weight(.bold))
                    Text(L(key: model.summary)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if running {
                    Text(L("ACTIEF")).font(.caption2.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.mint.opacity(0.2), in: Capsule()).foregroundStyle(Theme.mint)
                }
            }
            HStack(spacing: 8) {
                Badge(text: model.totalSize.gbShort, icon: "externaldrive")
                switch fit {
                case .fits: Badge(text: L("Past in geheugen"), icon: "memorychip", color: Theme.mint)
                case .streams:
                    Badge(text: L("Streamt van SSD"), icon: "bolt.horizontal", color: Theme.amber)
                    if MemoryPlanner.isSmallMac(app.system.physicalMemory) {
                        Badge(text: L("Op \(app.system.physicalMemory >> 30) GB niet gemeten, kan traag zijn"), icon: "speedometer", color: Theme.amber)
                    } else if let speed = model.speedOn32GB, app.system.physicalMemory < MemoryPlanner.roomyMemory {
                        Badge(text: L("\(speed) tok/s op 32 GB"), icon: "speedometer", color: Theme.amber)
                    }
                case .tooBig: Badge(text: L("Waarschijnlijk te krap voor deze Mac, niet gemeten"), icon: "exclamationmark.triangle", color: Theme.amber)
                }
                if status.vision?.complete == true { Badge(text: L("Vision"), icon: "eye") }
                if model.hasMTP { Badge(text: "MTP", icon: "forward.fill", color: Theme.violet) }
            }
            if !status.isComplete {
                ProgressView(value: status.fraction).tint(Theme.family(model.family))
                HStack {
                    Text(L("\(status.have.gbShort) van \(status.expected.gbShort)")).font(.caption).foregroundStyle(.secondary)
                    if let eta = models.etaSeconds(model.id) {
                        Text(L("· \(String(format: "%.0f MB/s", models.speed / 1e6)) · nog \(duration(eta))")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            HStack {
                if !status.isComplete {
                    if models.downloading.contains(model.id) {
                        Button(L("Pauzeer")) { models.stopDownload(model.id) }
                    } else {
                        Button { models.startDownload(model.id) } label: { Label(L("Download"), systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(.borderedProminent).tint(Theme.family(model.family))
                    }
                }
                Spacer()
                if selected {
                    Label(L("Gekozen"), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Theme.family(model.family))
                } else {
                    Button(L("Kies")) { Task { await app.select(model.id) } }.disabled(!status.headersAvailable)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? AnyShapeStyle(Theme.familyGradient(model.family)) : AnyShapeStyle(.white.opacity(0.08)),
                                                           lineWidth: selected ? 2 : 1))
        .shadow(color: Theme.family(model.family).opacity(selected ? 0.35 : (hover ? 0.2 : 0.05)), radius: selected ? 22 : 12)
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.spring(response: 0.35), value: hover)
        .onHover { hover = $0 }
    }

    private func duration(_ s: Double) -> String {
        s > 3600 ? String(format: "%.0f u %.0f min", (s / 3600).rounded(.down), s.truncatingRemainder(dividingBy: 3600) / 60)
                 : String(format: "%.0f min", s / 60)
    }
}

struct Badge: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

private struct PlanDetails: View {
    @EnvironmentObject var app: AppState
    let plan: MemoryPlan

    var body: some View {
        GlassCard(title: L("Geheugenplan"), icon: "memorychip", glow: Theme.violet) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow { Text(L("Vaste gewichten (GPU)")).foregroundStyle(.secondary); Text(plan.dense.gb) }
                if plan.expertCache > 0 {
                    GridRow { Text(L("Expert-cache (GPU)")).foregroundStyle(.secondary); Text(plan.expertCache.gb + L(" · de experts die het gesprek het meest gebruikt")) }
                    GridRow { Text(L("Experts van de SSD")).foregroundStyle(.secondary); Text(plan.streamedExperts.gb + L(" · alleen als een woord ze nodig heeft")) }
                } else {
                    GridRow { Text(L("Experts op de GPU")).foregroundStyle(.secondary); Text(plan.gpuExperts.gb) }
                    GridRow {
                        Text(L("Experts via CPU")).foregroundStyle(.secondary)
                        Text(plan.cpuMoELayers == 0 ? "geen" : L("\(plan.cpuExperts.gb) · \(plan.cpuMoELayers) lagen"))
                    }
                }
                if !plan.tensorSplit.isEmpty {
                    GridRow { Text(L("Lagen per Mac")).foregroundStyle(.secondary); Text(plan.tensorSplit.dropLast().map { "helper \($0)" }.joined(separator: " · ") + L(" · deze Mac \(max(plan.tensorSplit.last ?? 1, 1) - 1)")) }
                }
                if plan.engram > 0 {
                    GridRow { Text(L("Engram-tabellen (SSD)")).foregroundStyle(.secondary); Text(plan.engram.gb + L(" · per token een paar rijen")) }
                }
                GridRow { Text(L("KV-cache + buffers")).foregroundStyle(.secondary); Text(plan.overhead.gb + L(" · \(plan.contextSize / 1024)K context")) }
                GridRow { Text(L("GPU-limiet")).foregroundStyle(.secondary); Text(plan.gpuLimit.gb + (app.system.wiredLimitMB > 0 ? L(" (verhoogd)") : L(" (macOS-standaard)"))) }
            }
            .font(.callout)
            ForEach(plan.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.amber)
            }
            if app.system.wiredLimitMB < plan.suggestedWiredLimitMB - 1024 {
                Button(L("Verhoog GPU-limiet naar \((UInt64(plan.suggestedWiredLimitMB) << 20).gb)")) { app.raiseWiredLimit(mb: plan.suggestedWiredLimitMB) }
                    .help(L("Voert 'sysctl iogpu.wired_limit_mb' uit (vraagt je wachtwoord). Geldt tot de volgende herstart."))
            }
        }
    }
}

private struct EngineCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    @State private var showLog = false

    var body: some View {
        GlassCard(title: L("Engine"), icon: "bolt.horizontal.fill", glow: Theme.mint) {
            HStack {
                EngineStatusPill()
                Text(app.selectedModel?.name ?? "").foregroundStyle(.secondary)
                Spacer()
                EngineButton()
            }
            if case .starting = engine.state { ProgressView(value: engine.loadProgress).tint(Theme.mint) }
            if case .failed(let e) = engine.state { Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if Paths.engineBinary("llama-server") == nil {
                Label(L("Engine nog niet gebouwd: voer scripts/build_engine.sh uit."), systemImage: "hammer").font(.callout).foregroundStyle(Theme.amber)
            }
            DisclosureGroup(L("Log"), isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(engine.logTail.suffix(200).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 220)
                    .onChange(of: engine.logTail.count) { _, _ in proxy.scrollTo("end") }
                }
            }
        }
    }
}

private struct APICard: View {
    @EnvironmentObject var engine: EngineController

    var body: some View {
        GlassCard(title: L("API voor andere apps"), icon: "network", glow: Theme.cyan) {
            Text(L("Zolang de engine draait, kunnen andere programma's het model gebruiken via dezelfde poort."))
                .font(.callout).foregroundStyle(.secondary)
            snippet(L("OpenAI-compatibel"), "\(engine.baseURL.absoluteString)/v1")
            snippet(L("Anthropic-compatibel (Claude Code)"), "ANTHROPIC_BASE_URL=\(engine.baseURL.absoluteString) claude")
            snippet("Responses API (Codex)", "\(engine.baseURL.absoluteString)/v1/responses")
        }
    }

    private func snippet(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value).font(.callout.monospaced()).textSelection(.enabled)
                Spacer()
                Button { copy(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
            }
            .padding(8).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct FolderCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: Settings

    var body: some View {
        GlassCard(title: L("Modelmap"), icon: "folder.fill", glow: Theme.amber) {
            Text(L("Elk model staat in een eigen submap; afbeeldingsmodellen in vision/.")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(Paths.modelsRoot.path).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button(L("Kies map…")) { chooseFolder() }
                if !settings.modelFolder.isEmpty { Button(L("Standaard")) { settings.modelFolder = ""; app.loadIndex() } }
            }
        }
    }

    /// Use model files the user downloaded elsewhere (another disk, a shared folder).
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = L("Kies de map met de modelmappen (bijv. deepseek-v4.1-flash-compact/)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.modelFolder = url.path
        app.loadIndex()
    }
}
