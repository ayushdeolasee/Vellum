import Foundation

// A small, bounded DOM over Foundation's XMLParser for EPUB package, container,
// navigation and NCX documents. External entities are never resolved and any
// DTD entity declaration aborts the parse, so XXE and entity-expansion bombs
// cannot reach the reader. HTML named entities common in navigation documents
// (&nbsp;, &mdash;, …) are rewritten to numeric references first, because
// without the XHTML DTD a strict XML parser rejects them.

final class EpubXMLElement {
    /// Local name (namespace prefix stripped).
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [EpubXMLElement] = []
    fileprivate var textParts: [String] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Attribute lookup by local name: `attribute("type")` matches both
    /// `type` and a prefixed `epub:type`.
    func attribute(_ localName: String) -> String? {
        if let value = attributes[localName] { return value }
        let suffix = ":" + localName
        return attributes.first { $0.key.hasSuffix(suffix) }?.value
    }

    func children(named name: String) -> [EpubXMLElement] {
        children.filter { $0.name == name }
    }

    func firstChild(named name: String) -> EpubXMLElement? {
        children.first { $0.name == name }
    }

    /// Depth-first, document-order search below this element.
    func descendants(named name: String) -> [EpubXMLElement] {
        var result: [EpubXMLElement] = []
        var stack = Array(children.reversed())
        while let next = stack.popLast() {
            if next.name == name { result.append(next) }
            stack.append(contentsOf: next.children.reversed())
        }
        return result
    }

    func firstDescendant(named name: String) -> EpubXMLElement? {
        var stack = Array(children.reversed())
        while let next = stack.popLast() {
            if next.name == name { return next }
            stack.append(contentsOf: next.children.reversed())
        }
        return nil
    }

    /// All descendant text, whitespace-collapsed.
    var textContent: String {
        var parts: [String] = []
        func collect(_ element: EpubXMLElement) {
            parts.append(contentsOf: element.textParts)
            element.children.forEach(collect)
        }
        collect(self)
        return parts.joined()
            .split(whereSeparator: { $0.isWhitespace && $0 != "\u{00A0}" })
            .joined(separator: " ")
    }
}

enum EpubXML {
    static let maxElementCount = 200_000
    static let maxDepth = 256

    static func parse(_ data: Data, source: String) throws -> EpubXMLElement {
        // XMLParser does not report internal-subset declarations reliably,
        // so reject DTD entities up front (XXE and expansion bombs).
        if declaresEntities(data) {
            throw EpubError.malformedXML("\(source): entity declarations are not allowed")
        }
        let parser = XMLParser(data: normalizingHTMLEntities(data))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let builder = Builder(source: source)
        parser.delegate = builder
        let succeeded = parser.parse()
        if let failure = builder.failure { throw failure }
        guard succeeded, let root = builder.root else {
            let detail = parser.parserError?.localizedDescription ?? "unreadable document"
            throw EpubError.malformedXML("\(source): \(detail)")
        }
        return root
    }

    private static func declaresEntities(_ data: Data) -> Bool {
        let marker = "<!ENTITY"
        if data.range(of: Data(marker.utf8)) != nil { return true }
        let utf16BOMs: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF]]
        guard utf16BOMs.contains(where: { data.starts(with: $0) }),
              let text = String(data: data, encoding: .utf16)
        else { return false }
        return text.contains(marker)
    }

    private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    private static let htmlEntities: [String: UInt32] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "sect": 167, "copy": 169,
        "laquo": 171, "shy": 173, "reg": 174, "deg": 176, "para": 182, "middot": 183,
        "raquo": 187, "iquest": 191, "times": 215, "agrave": 224, "aacute": 225,
        "auml": 228, "ccedil": 231, "egrave": 232, "eacute": 233, "ntilde": 241,
        "ouml": 246, "uuml": 252, "szlig": 223, "ensp": 8194, "emsp": 8195,
        "thinsp": 8201, "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217,
        "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224,
        "Dagger": 8225, "bull": 8226, "hellip": 8230, "prime": 8242, "trade": 8482,
    ]

    private static let entityPattern = try? NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]{0,31});")

    /// Rewrites non-XML named entities to numeric references (or escapes
    /// unknown ones as literal text). Only ASCII sequences change, so the
    /// document's own encoding is preserved; non-UTF-8 input passes through.
    static func normalizingHTMLEntities(_ data: Data) -> Data {
        guard data.contains(UInt8(ascii: "&")),
              let text = String(data: data, encoding: .utf8),
              let entityPattern
        else { return data }
        let source = text as NSString
        var output = ""
        var cursor = 0
        var changed = false
        for match in entityPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1))
            guard !xmlEntities.contains(name) else { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let scalar = htmlEntities[name] {
                output += "&#\(scalar);"
            } else {
                output += "&amp;\(name);"
            }
            cursor = match.range.location + match.range.length
            changed = true
        }
        guard changed else { return data }
        output += source.substring(from: cursor)
        return Data(output.utf8)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let source: String
        var root: EpubXMLElement?
        var failure: EpubError?
        private var stack: [EpubXMLElement] = []
        private var elementCount = 0

        init(source: String) {
            self.source = source
        }

        private func fail(_ parser: XMLParser, _ reason: String) {
            if failure == nil {
                failure = .malformedXML("\(source): \(reason)")
            }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            elementCount += 1
            guard elementCount <= EpubXML.maxElementCount else {
                return fail(parser, "too many elements")
            }
            guard stack.count < EpubXML.maxDepth else {
                return fail(parser, "nesting is too deep")
            }
            let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let element = EpubXMLElement(name: localName, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(element)
            } else if root == nil {
                root = element
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.textParts.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.textParts.append(String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail(parser, "entity declarations are not allowed")
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            fail(parser, "external entities are not allowed")
        }

        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?, notationName: String?) {
            fail(parser, "unparsed entities are not allowed")
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            fail(parser, "external entities are not allowed")
            return nil
        }
    }
}
