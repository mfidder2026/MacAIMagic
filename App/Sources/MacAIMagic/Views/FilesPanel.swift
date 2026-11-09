import SwiftUI

/// The working folder's files beside the chat (the </> button next to the folder): folders open with a click, a file
/// shows its text below the tree, read only. What the model writes shows within a second, also in the open file, which
/// keeps its place. Taken over from WinAIMagic.
struct FilesPanel: View {
    let folder: URL
    @AppStorage("filesPanelWidth") private var width: Double = 340
    @State private var open: Set<URL> = []
    @State private var selected: URL?
    @State private var content: WorkspaceFiles.Content?
    @State private var tick = 0
    @State private var dragStart: Double?
    @State private var cursorPushed = false

    var body: some View {
        HStack(spacing: 0) {
            // the left edge drags the panel wider
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in
                        if inside && !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
                        if !inside && cursorPushed { NSCursor.pop(); cursorPushed = false }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            if dragStart == nil { dragStart = width }
                            width = min(900, max(220, (dragStart ?? width) - g.translation.width))
                        }
                        .onEnded { _ in dragStart = nil }))
            VStack(spacing: 0) {
                HStack {
                    Label(folder.lastPathComponent, systemImage: "folder.fill").font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                ScrollView {
                    // only the tree is drawn again when the folder changed; the open file keeps its place
                    LazyVStack(alignment: .leading, spacing: 1) { rows(folder, depth: 0) }
                        .padding(.vertical, 6)
                        .id(tick)
                }
                .frame(minHeight: 120, maxHeight: selected == nil ? .infinity : 260)
                if let selected {
                    Divider()
                    viewer(selected)
                }
            }
            .frame(width: width)
        }
        .background(.ultraThinMaterial)
        .task(id: folder) { await watch() }
        // closed while the pointer was on the edge: the arrow comes back
        .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
        .onChange(of: folder) { _, _ in open = []; selected = nil; content = nil }
    }

    private func rows(_ dir: URL, depth: Int) -> AnyView {
        let (entries, more) = WorkspaceFiles.list(dir)
        return AnyView(ForEach(entries) { e in
            Button {
                if e.isFolder {
                    if open.contains(e.url) { open.remove(e.url) } else { open.insert(e.url) }
                } else {
                    selected = e.url
                    content = WorkspaceFiles.read(e.url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: e.isFolder ? (open.contains(e.url) ? "chevron.down" : "chevron.right") : "doc.text")
                        .font(.caption).frame(width: 12).foregroundStyle(.secondary)
                    if e.isFolder { Image(systemName: "folder.fill").foregroundStyle(Theme.amber).font(.caption) }
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if !e.isFolder { Text(WorkspaceFiles.size(e.size)).font(.caption2).foregroundStyle(.tertiary) }
                }
                .font(.callout)
                .padding(.leading, CGFloat(12 + depth * 14)).padding(.trailing, 10).padding(.vertical, 3)
                .background(selected == e.url ? Theme.accent.opacity(0.25) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if e.isFolder && open.contains(e.url) { rows(e.url, depth: depth + 1) }
        }
        .overlay(alignment: .bottomLeading) {
            if more > 0 { Text(L("… en nog \(more)")).font(.caption).foregroundStyle(.tertiary).padding(.leading, CGFloat(12 + depth * 14)) }
        })
    }

    private func viewer(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { selected = nil; content = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if let note = content?.note { Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4) }
            if let text = content?.text {
                // a text view of its own: a file of 1 MB in a SwiftUI Text made every redraw slow
                ReadOnlyText(text: text)
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Once a second: did the open folders or the open file change? Then redraw (the open file keeps its place: only its
    /// text is replaced).
    private func watch() async {
        var last = WorkspaceFiles.signature(folders: [folder] + open, file: selected)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let now = WorkspaceFiles.signature(folders: [folder] + open, file: selected)
            guard now != last else { continue }
            last = now
            if let selected { content = WorkspaceFiles.read(selected) }
            tick &+= 1
        }
    }
}

/// Read-only monospaced text that keeps its place when the text changes, or follows the end when it was at the end
/// (a log the model writes to).
struct ReadOnlyText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        // long lines scroll sideways instead of wrapping, as in an editor
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let clip = scroll.contentView
        let atEnd = clip.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 4
        let origin = clip.bounds.origin
        view.string = text
        if atEnd && origin.y > 0 {
            view.scrollToEndOfDocument(nil)
        } else {
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
