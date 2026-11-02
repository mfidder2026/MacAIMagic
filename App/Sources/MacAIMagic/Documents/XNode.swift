import Foundation

/// A small XML tree for the parts of a .docx. Names stay as written ("w:p"), so what is not touched is written back
/// the same; `DocxPackage` checks that the prefix w: means what the code assumes.
final class XNode {
    enum Kind { case element, text, comment, instruction }

    let kind: Kind
    var name: String
    var value: String
    var attributes: [String: String]
    private(set) var children: [XNode] = []
    private(set) weak var parent: XNode?
    /// A root element: the comments and instructions before it.
    var prolog: [XNode] = []

    init(kind: Kind, name: String = "", value: String = "", attributes: [String: String] = [:]) {
        self.kind = kind
        self.name = name
        self.value = value
        self.attributes = attributes
    }

    convenience init(_ name: String, _ attributes: [String: String] = [:], _ children: [XNode] = []) {
        self.init(kind: .element, name: name, attributes: attributes)
        children.forEach { self.append($0) }
    }

    /// `<w:t>text</w:t>`, keeping spaces at its ends.
    static func textElement(_ name: String, _ text: String) -> XNode {
        let e = XNode(name)
        e.text = text
        return e
    }

    // MARK: - reading

    var elements: [XNode] { children.filter { $0.kind == .element } }

    func find(_ name: String) -> XNode? { children.first { $0.kind == .element && $0.name == name } }
    func findAll(_ name: String) -> [XNode] { children.filter { $0.kind == .element && $0.name == name } }
    func has(_ name: String) -> Bool { find(name) != nil }
    subscript(_ attribute: String) -> String? {
        get { attributes[attribute] }
        set { attributes[attribute] = newValue }
    }
    /// The w:val of this element.
    var val: String? { attributes["w:val"] }

    /// This element and everything below it, in document order.
    func walk(_ visit: (XNode) -> Void) {
        visit(self)
        for c in children { c.walk(visit) }
    }

    /// The elements with one of these names below this one, in document order.
    func descendants(_ names: String...) -> [XNode] { descendants(in: Set(names)) }

    func descendants(in names: Set<String>) -> [XNode] {
        var out: [XNode] = []
        for c in children where c.kind == .element {
            c.walk { if $0.kind == .element && names.contains($0.name) { out.append($0) } }
        }
        return out
    }

    /// The directly contained text; setting it replaces all content.
    var text: String {
        get { children.filter { $0.kind == .text }.map(\.value).joined() }
        set {
            for c in children { c.parent = nil }
            children = newValue.isEmpty ? [] : [XNode(kind: .text, value: newValue)]
            children.first?.parent = self
            if name == "w:t" || name == "w:instrText" {
                if newValue != newValue.trimmingCharacters(in: .whitespacesAndNewlines) { attributes["xml:space"] = "preserve" }
            }
        }
    }

    /// All text below this element.
    var allText: String {
        var out = ""
        walk { if $0.kind == .text { out += $0.value } }
        return out
    }

    func hasAncestor(_ name: String, below stop: XNode? = nil) -> Bool {
        var a = parent
        while let node = a, node !== stop {
            if node.name == name { return true }
            a = node.parent
        }
        return false
    }

    // MARK: - changing

    @discardableResult
    func append(_ child: XNode) -> XNode {
        child.removeFromParent()
        child.parent = self
        children.append(child)
        return child
    }

    /// A new element at the end of this one.
    @discardableResult
    func add(_ name: String, _ attributes: [String: String] = [:]) -> XNode { append(XNode(name, attributes)) }

    func insert(_ child: XNode, at index: Int) {
        child.removeFromParent()
        child.parent = self
        children.insert(child, at: min(index, children.count))
    }

    func index(of child: XNode) -> Int? { children.firstIndex { $0 === child } }

    func insertBefore(_ reference: XNode, _ child: XNode) {
        guard let i = index(of: reference) else { append(child); return }
        insert(child, at: i)
    }

    func insertAfter(_ reference: XNode, _ child: XNode) {
        guard let i = index(of: reference) else { append(child); return }
        insert(child, at: i + 1)
    }

    func remove(_ child: XNode) {
        guard let i = index(of: child) else { return }
        children.remove(at: i)
        child.parent = nil
    }

    func removeAll(_ name: String) { for e in findAll(name) { remove(e) } }

    func removeFromParent() { parent?.remove(self) }

    func copy() -> XNode {
        let c = XNode(kind: kind, name: name, value: value, attributes: attributes)
        for child in children { c.append(child.copy()) }
        return c
    }

    // MARK: - text form

    func serialized() -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        for p in prolog { p.write(to: &out) }
        write(to: &out)
        return Data(out.utf8)
    }

    /// Only for comparing two pieces of formatting.
    var signature: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch kind {
        case .text:
            out += Self.escape(value)
        case .comment:
            out += "<!--" + value + "-->"
        case .instruction:
            out += "<?" + name + (value.isEmpty ? "" : " " + value) + "?>"
        case .element:
            out += "<" + name
            // the parser gives no order: the namespace declarations first, then by name, so the result does not vary
            let keys = attributes.keys.sorted { a, b in
                let (x, y) = (a.hasPrefix("xmlns"), b.hasPrefix("xmlns"))
                return x == y ? a < b : x
            }
            for k in keys { out += " " + k + "=\"" + Self.escapeAttribute(attributes[k] ?? "") + "\"" }
            if children.isEmpty { out += "/>"; return }
            out += ">"
            for c in children { c.write(to: &out) }
            out += "</" + name + ">"
        }
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\r" || $0 == "\r\n" }) else { return s }
        return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\t", with: "&#9;")
    }

    // MARK: - parsing

    static func parse(_ data: Data) throws -> XNode {
        let builder = XNodeParser()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw Zip.Failure(parser.parserError?.localizedDescription ?? "XML")
        }
        return root
    }
}

private final class XNodeParser: NSObject, XMLParserDelegate {
    var root: XNode?
    private var stack: [XNode] = []
    private var prolog: [XNode] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let e = XNode(kind: .element, name: qualifiedName ?? name, attributes: attributes)
        if let top = stack.last {
            top.append(e)
        } else if root == nil {
            root = e
            e.prolog = prolog
        }
        stack.append(e)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { addText(string) }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespace: String) { addText(whitespace) }
    func parser(_ parser: XMLParser, foundCDATA block: Data) { addText(String(decoding: block, as: UTF8.self)) }

    /// The parser may report one text in pieces.
    private func addText(_ s: String) {
        guard let top = stack.last else { return }
        if let last = top.children.last, last.kind == .text { last.value += s } else { top.append(XNode(kind: .text, value: s)) }
    }

    func parser(_ parser: XMLParser, foundComment comment: String) { add(XNode(kind: .comment, value: comment)) }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        add(XNode(kind: .instruction, name: target, value: data ?? ""))
    }

    private func add(_ node: XNode) {
        if let top = stack.last { top.append(node) } else if root == nil { prolog.append(node) }
    }
}

/// Regular expressions on the UTF-16 offsets Foundation uses, so positions can be compared across runs of text.
struct Rx {
    struct Match {
        let range: NSRange
        let groups: [String?]
        var first: String? { groups.compactMap { $0 }.first }
    }

    private let re: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func matches(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            Match(range: m.range, groups: (1..<max(m.numberOfRanges, 1)).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            })
        }
    }

    func first(_ s: String) -> Match? { matches(s).first }
    func test(_ s: String) -> Bool { first(s) != nil }

    /// Every match replaced by what `with` gives.
    func replace(_ s: String, with: (Match) -> String) -> String {
        var out = s as NSString
        for m in matches(s).reversed() { out = out.replacingCharacters(in: m.range, with: with(m)) as NSString }
        return out as String
    }
}
