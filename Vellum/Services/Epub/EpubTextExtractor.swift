import Foundation

enum EpubTextError: Error, Equatable {
    case limitExceeded(String)
    case malformedXML
    case entityDeclaration
    case unsupportedEncoding
}

enum EpubTextExtractor {
    struct Limits: Sendable {
        var maxInputBytes: Int = 8 * 1024 * 1024
        var maxTextUTF16: Int = 2 * 1024 * 1024
        var maxElements: Int = EpubXML.maxElementCount
        var maxDepth: Int = EpubXML.maxDepth
        static let standard = Limits()
    }

    /// Synchronous CPU work: use EpubTextWorker or an already-owned background task.
    static func extract(xhtml: Data, chapterHref: String, limits: Limits = .standard) throws -> EpubChapterText {
        try Task.checkCancellation()
        guard limits.maxInputBytes > 0, limits.maxTextUTF16 >= 0,
            limits.maxElements > 0, limits.maxDepth > 0
        else {
            throw EpubTextError.limitExceeded("invalid limits")
        }
        guard xhtml.count <= limits.maxInputBytes else { throw EpubTextError.limitExceeded("input bytes") }
        var xml = try decodedXML(xhtml)
        guard !xml.utf8.contains(0) else { throw EpubTextError.unsupportedEncoding }
        // XMLParser does not reliably report internal-subset entity declarations.
        guard !xml.contains("<!ENTITY") else { throw EpubTextError.entityDeclaration }
        if xml.hasPrefix("\u{FEFF}") { xml.removeFirst() }
        // Transcoding must not leave the source's UTF-16/32 encoding declaration behind.
        if xml.hasPrefix("<?xml"), let end = xml.range(of: "?>") {
            xml.removeSubrange(xml.startIndex..<end.upperBound)
        }
        let parser = XMLParser(data: EpubXML.normalizingHTMLEntities(Data(xml.utf8)))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let builder = Builder(limits: limits)
        parser.delegate = builder
        let success = parser.parse()
        if let failure = builder.failure { throw failure }
        try Task.checkCancellation()
        guard success, builder.sawBody else { throw EpubTextError.malformedXML }
        return EpubChapterText(chapterHref: chapterHref, text: builder.output)
    }

    /// Collapse this exact scalar set to U+0020, trim both ends; do not NFC-fold.
    static func normalizeWhitespace(_ text: String) -> String {
        var result = ""
        var pending = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                pending = !result.isEmpty
                continue
            }
            if pending {
                result.append(" ")
                pending = false
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
            0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default: false
        }
    }

    private static func decodedXML(_ data: Data) throws -> String {
        let encoding: String.Encoding
        if data.starts(with: [0xFF, 0xFE, 0, 0]) || data.starts(with: [0x3C, 0, 0, 0]) {
            encoding = .utf32LittleEndian
        } else if data.starts(with: [0, 0, 0xFE, 0xFF]) || data.starts(with: [0, 0, 0, 0x3C]) {
            encoding = .utf32BigEndian
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0x3C, 0]) {
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0, 0x3C]) {
            encoding = .utf16BigEndian
        } else {
            encoding = .utf8
        }
        guard let text = String(data: data, encoding: encoding) else { throw EpubTextError.unsupportedEncoding }
        return text
    }

    // Mirror these sets and isWhitespace in the reader's DOM text walker.
    static let excludedElements: Set<String> = ["head", "script", "style", "template", "noscript"]
    static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "dd", "details", "dialog",
        "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre",
        "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul", "br",
    ]

    private final class Builder: NSObject, XMLParserDelegate {
        let limits: Limits
        var output = ""
        var failure: (any Error)?
        var sawBody = false
        private var stack: [(name: String, excluded: Bool, inBody: Bool)] = []
        private var elements = 0
        private var outputUTF16 = 0
        private var pendingSpace = false

        init(limits: Limits) { self.limits = limits }

        private func fail(_ parser: XMLParser, _ error: any Error) {
            if failure == nil { failure = error }
            parser.abortParsing()
        }

        private func checkCancellation(_ parser: XMLParser) -> Bool {
            if Task.isCancelled {
                fail(parser, CancellationError())
                return false
            }
            return failure == nil
        }

        private func separator() { pendingSpace = !output.isEmpty }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String] = [:]
        ) {
            guard checkCancellation(parser) else { return }
            elements += 1
            guard elements <= limits.maxElements else { return fail(parser, EpubTextError.limitExceeded("elements")) }
            guard stack.count < limits.maxDepth else { return fail(parser, EpubTextError.limitExceeded("depth")) }
            let name = elementName.lowercased()
            let excluded =
                stack.last?.excluded == true || excludedElements.contains(name) || attributes["hidden"] != nil
                || attributes["aria-hidden"]?.lowercased() == "true"
            let inBody = stack.last?.inBody == true || name == "body"
            if name == "body" { sawBody = true }
            stack.append((name, excluded, inBody))
            if inBody, !excluded, blockElements.contains(name) { separator() }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            guard let element = stack.popLast() else { return }
            if element.inBody, !element.excluded, blockElements.contains(element.name) { separator() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard checkCancellation(parser), let element = stack.last, element.inBody, !element.excluded else { return }
            for scalar in string.unicodeScalars {
                if isWhitespace(scalar) {
                    separator()
                    continue
                }
                let units = scalar.value > 0xFFFF ? 2 : 1
                let added = units + (pendingSpace ? 1 : 0)
                guard outputUTF16 <= limits.maxTextUTF16 - added else {
                    return fail(parser, EpubTextError.limitExceeded("text UTF-16"))
                }
                if pendingSpace {
                    output.append(" ")
                    pendingSpace = false
                }
                output.unicodeScalars.append(scalar)
                outputUTF16 += added
            }
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail(parser, EpubTextError.entityDeclaration)
        }

        func parser(
            _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
            systemID: String?
        ) {
            fail(parser, EpubTextError.entityDeclaration)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            fail(parser, EpubTextError.entityDeclaration)
            return nil
        }
    }
}
