import SwiftUI

/// Setup and status: this Mac, the model download, the memory plan, the engine and its API.
struct EngineView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var models: ModelStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Engine & model").font(.largeTitle.weight(.semibold))
                Text("DeepSeek-V4.1-Flash-1017 · 748B MoE · Maya-XS (IQ1_S-experts, Q8_0-attention)")
                    .foregroundStyle(.secondary)
                SystemCard()
                ModelCard()
                if let plan = app.plan { PlanCard(plan: plan) }
                EngineCard()
                APICard()
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: models.headersAvailable) { _, ok in if ok { app.loadIndex() } }
        .onAppear { app.refreshSystem(); app.loadIndex() }
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

private struct SystemCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Card(title: "Deze Mac", icon: "laptopcomputer") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow { Text("Chip").foregroundStyle(.secondary); Text(app.system.chip) }
                GridRow { Text("Geheugen").foregroundStyle(.secondary); Text(app.system.physicalMemory.gb + " unified") }
                GridRow {
                    Text("GPU-limiet").foregroundStyle(.secondary)
                    Text(app.system.effectiveGPULimit.gb + (app.system.wiredLimitMB > 0 ? " (verhoogd)" : " (macOS-standaard)"))
                }
                GridRow { Text("Vrije schijf").foregroundStyle(.secondary); Text(app.system.freeDisk.gb) }
            }
        }
    }
}

private struct ModelCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var models: ModelStore

    var body: some View {
        Card(title: "Model", icon: "shippingbox") {
            if models.isComplete {
                Label(models.allVerified ? "Alle bestanden gedownload en gecontroleerd (sha256)" : "Alle modelbestanden aanwezig",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ProgressView(value: Double(models.haveTotal), total: Double(max(models.expectedTotal, 1))) {
                    HStack {
                        Text("\(models.haveTotal.gb) van \(models.expectedTotal.gb)")
                        Spacer()
                        if models.speed > 0 {
                            Text(String(format: "%.0f MB/s", models.speed / 1e6))
                            if let eta = models.etaSeconds { Text("· nog \(Self.duration(eta))") }
                        }
                    }
                    .font(.callout)
                }
                HStack {
                    if models.downloading {
                        Button("Pauzeer") { models.stopDownload() }
                    } else {
                        Button("Download model (278 GB)") { models.startDownload() }.buttonStyle(.borderedProminent)
                    }
                    Text(models.lastMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            DisclosureGroup("Bestanden") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(models.files) { f in
                        HStack {
                            Image(systemName: f.complete ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(f.complete ? .green : .secondary)
                            Text(f.name).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", f.fraction * 100)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Map: \(Paths.modelDir.path)").font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                        Spacer()
                        Button("Kies map…") { chooseFolder() }.controlSize(.small)
                        if !Settings.shared.modelFolder.isEmpty {
                            Button("Standaard") { Settings.shared.modelFolder = ""; app.loadIndex() }.controlSize(.small)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// Use model files the user downloaded elsewhere (another disk, a shared folder).
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Kies de map met de DeepSeek-V4.1-Flash-1017 Maya-XS GGUF-bestanden"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.shared.modelFolder = url.path
        app.loadIndex()
    }

    static func duration(_ s: Double) -> String {
        s > 3600 ? String(format: "%.0f u %.0f min", (s / 3600).rounded(.down), (s.truncatingRemainder(dividingBy: 3600) / 60))
                 : String(format: "%.0f min", s / 60)
    }
}

private struct PlanCard: View {
    @EnvironmentObject var app: AppState
    let plan: MemoryPlan

    var body: some View {
        Card(title: "Geheugenplan", icon: "memorychip") {
            MemoryBar(plan: plan)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow { Text("Vaste gewichten (GPU)").foregroundStyle(.secondary); Text(plan.dense.gb) }
                GridRow {
                    Text("Experts op de GPU").foregroundStyle(.secondary)
                    Text("\(plan.gpuExperts.gb) · lagen \(plan.cpuMoELayers)–\(plan.layers - 1)")
                }
                GridRow {
                    Text("Experts via CPU (mmap)").foregroundStyle(.secondary)
                    Text(plan.cpuMoELayers == 0 ? "geen" : "\(plan.cpuExperts.gb) · lagen 0–\(plan.cpuMoELayers - 1)")
                }
                GridRow { Text("Engram-tabellen (SSD)").foregroundStyle(.secondary); Text(plan.engram.gb + " · per token een paar rijen") }
                GridRow { Text("KV-cache + buffers").foregroundStyle(.secondary); Text(plan.overhead.gb + " · \(plan.contextSize / 1024)K context") }
            }
            .font(.callout)
            ForEach(plan.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if app.system.wiredLimitMB < plan.suggestedWiredLimitMB - 1024 {
                Button("Verhoog GPU-limiet naar \((UInt64(plan.suggestedWiredLimitMB) << 20).gb)") {
                    app.raiseWiredLimit(mb: plan.suggestedWiredLimitMB)
                }
                .help("Voert 'sysctl iogpu.wired_limit_mb' uit (vraagt je wachtwoord). Geldt tot de volgende herstart.")
            }
        }
    }
}

private struct MemoryBar: View {
    let plan: MemoryPlan
    var body: some View {
        let total = Double(plan.physical)
        let parts: [(String, Double, Color)] = [
            ("Vast", Double(plan.dense + plan.overhead), .purple),
            ("GPU-experts", Double(plan.gpuExperts), Theme.accent),
            ("CPU-experts", Double(plan.cpuExperts), .teal),
        ]
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2).frame(width: max(0, geo.size.width * min(p.1 / total, 1)))
                    }
                    Rectangle().fill(.quaternary)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 4) { Circle().fill(p.2).frame(width: 8, height: 8); Text(p.0) }
                }
                HStack(spacing: 4) { Circle().fill(.quaternary).frame(width: 8, height: 8); Text("Vrij voor macOS") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct EngineCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    @State private var showLog = false

    var body: some View {
        Card(title: "Engine", icon: "bolt.horizontal") {
            HStack {
                EngineStatusPill()
                Spacer()
                switch engine.state {
                case .running, .starting:
                    Button("Stop", role: .destructive) { engine.stop() }
                default:
                    Button("Start engine") { app.startEngine() }.buttonStyle(.borderedProminent).disabled(!app.canStart)
                }
            }
            if case .starting = engine.state { ProgressView(value: engine.loadProgress) }
            if case .failed(let e) = engine.state { Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if Paths.engineBinary("llama-server") == nil {
                Label("Engine nog niet gebouwd: voer scripts/build_engine.sh uit.", systemImage: "hammer")
                    .font(.callout).foregroundStyle(.orange)
            }
            DisclosureGroup("Log", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(engine.logTail.suffix(200).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        Card(title: "API voor andere apps", icon: "network") {
            Text("Zolang de engine draait, kunnen andere programma's het model gebruiken via dezelfde poort.")
                .font(.callout).foregroundStyle(.secondary)
            snippet("OpenAI-compatibel", "\(engine.baseURL.absoluteString)/v1")
            snippet("Anthropic-compatibel (Claude Code)", "ANTHROPIC_BASE_URL=\(engine.baseURL.absoluteString) claude")
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
            .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
