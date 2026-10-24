import Foundation

// container.xml → OPF package (metadata, manifest, spine) → navigation (EPUB 3
// nav document, falling back to the EPUB 2 NCX). Structural problems that make
// the book unreadable throw; a broken table of contents does not, because the
// spine alone is enough to read the book.

enum EpubPackageParser {
    static let containerPath = "META-INF/container.xml"
    static let encryptionPath = "META-INF/encryption.xml"
    static let packageMediaType = "application/oebps-package+xml"
    static let ncxMediaType = "application/x-dtbncx+xml"
    static let contentMediaTypes: Set<String> = ["application/xhtml+xml", "text/html", "image/svg+xml"]
    /// Font mangling is permitted in DRM-free books; anything else is DRM.
    static let fontObfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]
    private static let maxFallbackHops = 8
    private static let maxTocDepth = 32

    static func parse(container: EpubContainer) throws -> EpubPublication {
        try validateMimetype(container)
        let packagePath = try locatePackage(container)
        let obfuscated = try encryptedResources(container)
        try Task.checkCancellation()

        let package = try container.xmlDocument(at: packagePath)
        guard package.name == "package" else {
            throw EpubError.invalidPackage("the root element is not <package>")
        }
        let version = package.attribute("version")?.trimmingCharacters(in: .whitespaces) ?? ""
        let metadataElement = package.firstChild(named: "metadata")
        if let metadataElement, isFixedLayout(metadataElement) {
            throw EpubError.fixedLayoutUnsupported
        }
        let metadata = parseMetadata(
            metadataElement, uniqueIdentifierId: package.attribute("unique-identifier"))

        guard let manifestElement = package.firstChild(named: "manifest") else {
            throw EpubError.invalidPackage("the manifest is missing")
        }
        var manifest: [EpubPublication.ManifestItem] = []
        var manifestById: [String: EpubPublication.ManifestItem] = [:]
        var fallbacks: [String: String] = [:]
        for item in manifestElement.children(named: "item") {
            guard let id = item.attribute("id"), !id.isEmpty, manifestById[id] == nil,
                  let href = item.attribute("href"),
                  let mediaType = item.attribute("media-type"),
                  let resolved = EpubPath.resolve(href, relativeTo: packagePath)
            else { continue }
            let entry = EpubPublication.ManifestItem(
                id: id,
                path: resolved.path,
                mediaType: mediaType.lowercased().trimmingCharacters(in: .whitespaces),
                properties: tokens(item.attribute("properties")))
            manifest.append(entry)
            manifestById[id] = entry
            if let fallback = item.attribute("fallback") {
                fallbacks[id] = fallback
            }
        }

        guard let spineElement = package.firstChild(named: "spine") else {
            throw EpubError.invalidPackage("the spine is missing")
        }
        var spine: [EpubPublication.SpineItem] = []
        for itemref in spineElement.children(named: "itemref") {
            guard let idref = itemref.attribute("idref"),
                  let content = contentDocument(
                      startingAt: idref, manifest: manifestById, fallbacks: fallbacks),
                  container.contains(content.path)
            else { continue }
            spine.append(EpubPublication.SpineItem(
                idref: idref,
                path: content.path,
                mediaType: content.mediaType,
                linear: itemref.attribute("linear")?.lowercased() != "no"))
        }
        guard !spine.isEmpty else { throw EpubError.emptySpine }
        try Task.checkCancellation()

        var toc: [EpubPublication.TocEntry] = []
        if let nav = manifest.first(where: { $0.properties.contains("nav") }) {
            toc = (try? parseNavigationDocument(at: nav.path, container: container)) ?? []
        }
        if toc.isEmpty {
            let ncx = spineElement.attribute("toc").flatMap { manifestById[$0] }
                ?? manifest.first { $0.mediaType == ncxMediaType }
            if let ncx {
                toc = (try? parseNCX(at: ncx.path, container: container)) ?? []
            }
        }

        return EpubPublication(
            version: version,
            packagePath: packagePath,
            metadata: metadata,
            manifest: manifest,
            spine: spine,
            toc: toc,
            coverPath: coverPath(manifest: manifest, byId: manifestById, metadata: metadataElement, container: container),
            obfuscatedResourcePaths: obfuscated)
    }

    // MARK: - Container

    private static func validateMimetype(_ container: EpubContainer) throws {
        guard container.contains("mimetype") else { return }
        let data = try container.data(at: "mimetype", maxSize: 256)
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == "application/epub+zip" else { throw EpubError.invalidMimetype }
    }

    private static func locatePackage(_ container: EpubContainer) throws -> String {
        guard container.contains(containerPath) else { throw EpubError.missingContainer }
        let document = try container.xmlDocument(at: containerPath)
        let rootfiles = document.descendants(named: "rootfile")
        let preferred = rootfiles.first { $0.attribute("media-type")?.lowercased() == packageMediaType }
            ?? rootfiles.first
        guard let fullPath = preferred?.attribute("full-path"),
              let resolved = EpubPath.resolve(fullPath, relativeTo: ""),
              container.contains(resolved.path)
        else { throw EpubError.missingPackage }
        return resolved.path
    }

    /// Paths of obfuscated fonts. Throws `.drmProtected` for any other
    /// encryption, including an encryption manifest that cannot be read.
    private static func encryptedResources(_ container: EpubContainer) throws -> [String] {
        guard container.contains(encryptionPath) else { return [] }
        guard let document = try? container.xmlDocument(at: encryptionPath) else {
            throw EpubError.drmProtected
        }
        var obfuscated: [String] = []
        for encrypted in document.descendants(named: "EncryptedData") {
            guard let algorithm = encrypted.firstDescendant(named: "EncryptionMethod")?.attribute("Algorithm"),
                  fontObfuscationAlgorithms.contains(algorithm)
            else { throw EpubError.drmProtected }
            if let uri = encrypted.firstDescendant(named: "CipherReference")?.attribute("URI"),
               let resolved = EpubPath.resolve(uri, relativeTo: "") {
                obfuscated.append(resolved.path)
            }
        }
        return obfuscated
    }

    // MARK: - Package

    private static func parseMetadata(
        _ element: EpubXMLElement?, uniqueIdentifierId: String?
    ) -> EpubPublication.Metadata {
        guard let element else { return EpubPublication.Metadata() }
        func texts(_ name: String) -> [String] {
            element.children(named: name).map(\.textContent).filter { !$0.isEmpty }
        }
        let identifiers = element.children(named: "identifier")
        let identifier = identifiers.first { $0.attribute("id") == uniqueIdentifierId && uniqueIdentifierId != nil }
            ?? identifiers.first
        let identifierText = identifier?.textContent
        return EpubPublication.Metadata(
            title: texts("title").first,
            creators: texts("creator"),
            language: texts("language").first,
            identifier: identifierText?.isEmpty == false ? identifierText : nil,
            publisher: texts("publisher").first,
            description: texts("description").first)
    }

    private static func isFixedLayout(_ metadata: EpubXMLElement) -> Bool {
        metadata.children(named: "meta").contains {
            $0.attribute("property") == "rendition:layout" && $0.textContent == "pre-paginated"
        }
    }

    private static func contentDocument(
        startingAt id: String,
        manifest: [String: EpubPublication.ManifestItem],
        fallbacks: [String: String]
    ) -> EpubPublication.ManifestItem? {
        var current: String? = id
        var visited: Set<String> = []
        while let currentId = current, visited.count < maxFallbackHops, visited.insert(currentId).inserted {
            guard let item = manifest[currentId] else { return nil }
            if contentMediaTypes.contains(item.mediaType) { return item }
            current = fallbacks[currentId]
        }
        return nil
    }

    private static func coverPath(
        manifest: [EpubPublication.ManifestItem],
        byId: [String: EpubPublication.ManifestItem],
        metadata: EpubXMLElement?,
        container: EpubContainer
    ) -> String? {
        let epub2CoverId = metadata?.children(named: "meta")
            .first { $0.attribute("name") == "cover" }?
            .attribute("content")
        let candidates = [
            manifest.first { $0.properties.contains("cover-image") },
            epub2CoverId.flatMap { byId[$0] },
        ]
        return candidates.lazy
            .compactMap { $0 }
            .first { $0.mediaType.hasPrefix("image/") && container.contains($0.path) }?
            .path
    }

    private static func tokens(_ value: String?) -> [String] {
        value?.split(whereSeparator: { $0.isWhitespace }).map(String.init) ?? []
    }

    // MARK: - Navigation

    static func parseNavigationDocument(at path: String, container: EpubContainer) throws -> [EpubPublication.TocEntry] {
        let document = try container.xmlDocument(at: path)
        let navs = document.descendants(named: "nav")
        guard let nav = navs.first(where: { tokens($0.attribute("type")).contains("toc") }) ?? navs.first,
              let list = nav.firstDescendant(named: "ol")
        else { return [] }
        return navEntries(list, basePath: path, container: container, depth: 0)
    }

    private static func navEntries(
        _ list: EpubXMLElement, basePath: String, container: EpubContainer, depth: Int
    ) -> [EpubPublication.TocEntry] {
        guard depth < maxTocDepth else { return [] }
        return list.children(named: "li").compactMap { item in
            let label = item.children.first { $0.name == "a" || $0.name == "span" }
            let children = item.firstChild(named: "ol").map {
                navEntries($0, basePath: basePath, container: container, depth: depth + 1)
            } ?? []
            return tocEntry(
                title: label?.textContent ?? "",
                href: label?.name == "a" ? label?.attribute("href") : nil,
                basePath: basePath, container: container, children: children)
        }
    }

    static func parseNCX(at path: String, container: EpubContainer) throws -> [EpubPublication.TocEntry] {
        let document = try container.xmlDocument(at: path)
        guard let navMap = document.firstDescendant(named: "navMap") else { return [] }
        return ncxEntries(navMap, basePath: path, container: container, depth: 0)
    }

    private static func ncxEntries(
        _ parent: EpubXMLElement, basePath: String, container: EpubContainer, depth: Int
    ) -> [EpubPublication.TocEntry] {
        guard depth < maxTocDepth else { return [] }
        return parent.children(named: "navPoint").compactMap { point in
            tocEntry(
                title: point.firstChild(named: "navLabel")?.firstDescendant(named: "text")?.textContent ?? "",
                href: point.firstChild(named: "content")?.attribute("src"),
                basePath: basePath, container: container,
                children: ncxEntries(point, basePath: basePath, container: container, depth: depth + 1))
        }
    }

    private static func tocEntry(
        title: String, href: String?, basePath: String, container: EpubContainer,
        children: [EpubPublication.TocEntry]
    ) -> EpubPublication.TocEntry? {
        let target = href.flatMap { EpubPath.resolve($0, relativeTo: basePath) }
            .flatMap { container.contains($0.path) ? $0 : nil }
        guard target != nil || !children.isEmpty else { return nil }
        let fallbackTitle = target.map { ($0.path as NSString).lastPathComponent } ?? ""
        return EpubPublication.TocEntry(
            title: title.isEmpty ? fallbackTitle : title,
            path: target?.path,
            fragment: target?.fragment,
            children: children)
    }
}
