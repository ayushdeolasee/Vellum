import Foundation

/// Minimal stored-only ZIP writer for EPUB fixtures. It deliberately accepts
/// hostile inputs (traversal names, symlink entries) that real archivers
/// refuse to produce, so the reader's defenses can be exercised.
struct ZipFixture {
    enum Kind { case file, directory, symlink }

    struct Item {
        var path: String
        var data: Data
        var kind: Kind = .file
    }

    var items: [Item] = []

    mutating func add(_ path: String, _ text: String, kind: Kind = .file) {
        items.append(Item(path: path, data: Data(text.utf8), kind: kind))
    }

    mutating func add(_ path: String, data: Data) {
        items.append(Item(path: path, data: data))
    }

    func archiveData() -> Data {
        var body = Data()
        var central = Data()
        for item in items {
            let name = Data(item.path.utf8)
            let crc = Self.crc32(item.data)
            let size = UInt32(item.data.count)
            let offset = UInt32(body.count)
            body.append(le32: 0x0403_4b50)
            body.append(le16: 20); body.append(le16: 0x0800); body.append(le16: 0)
            body.append(le16: 0); body.append(le16: 0x21)
            body.append(le32: crc); body.append(le32: size); body.append(le32: size)
            body.append(le16: UInt16(name.count)); body.append(le16: 0)
            body.append(name); body.append(item.data)

            let mode: UInt32 = switch item.kind {
            case .file: 0o100644
            case .directory: 0o040755
            case .symlink: 0o120777
            }
            central.append(le32: 0x0201_4b50)
            central.append(le16: (3 << 8) | 20); central.append(le16: 20)
            central.append(le16: 0x0800); central.append(le16: 0)
            central.append(le16: 0); central.append(le16: 0x21)
            central.append(le32: crc); central.append(le32: size); central.append(le32: size)
            central.append(le16: UInt16(name.count)); central.append(le16: 0); central.append(le16: 0)
            central.append(le16: 0); central.append(le16: 0)
            central.append(le32: mode << 16); central.append(le32: offset)
            central.append(name)
        }
        var archive = body
        archive.append(central)
        archive.append(le32: 0x0605_4b50)
        archive.append(le16: 0); archive.append(le16: 0)
        archive.append(le16: UInt16(items.count)); archive.append(le16: UInt16(items.count))
        archive.append(le32: UInt32(central.count)); archive.append(le32: UInt32(body.count))
        archive.append(le16: 0)
        return archive
    }

    @discardableResult
    func write(to url: URL) throws -> URL {
        try archiveData().write(to: url)
        return url
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// Canonical small books built on `ZipFixture`.
enum EpubFixture {
    static let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    static func chapter(_ title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head>
        <body><h1 id="top">\(title)</h1><p>Text of \(title).</p></body></html>
        """
    }

    /// EPUB 3: nav document, cover-image, a non-linear item, a spine entry
    /// that reaches XHTML through a manifest fallback, and resources outside
    /// the OPF directory.
    static func epub3(title: String = "Sample Book", metadataExtra: String = "") -> ZipFixture {
        var zip = ZipFixture()
        zip.add("mimetype", "application/epub+zip")
        zip.add("META-INF/", "", kind: .directory)
        zip.add("META-INF/container.xml", container)
        zip.add("OEBPS/content.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="isbn">urn:isbn:000</dc:identifier>
                <dc:identifier id="uid">urn:uuid:1234</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:creator>Ada Writer</dc:creator>
                <dc:creator>Bo Editor</dc:creator>
                <dc:language>en</dc:language>
                <dc:publisher>Vellum Press</dc:publisher>
                \(metadataExtra)
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="cover" href="../images/cover.png" media-type="image/png" properties="cover-image"/>
                <item id="c1" href="text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="text/chapter2.xhtml" media-type="application/xhtml+xml"/>
                <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
                <item id="dtb" href="text/chapter3.dtb" media-type="application/x-dtbook+xml" fallback="c3"/>
                <item id="c3" href="text/chapter3.xhtml" media-type="application/xhtml+xml"/>
                <item id="remote" href="https://example.com/a.mp3" media-type="audio/mpeg"/>
              </manifest>
              <spine>
                <itemref idref="c1"/>
                <itemref idref="notes" linear="no"/>
                <itemref idref="c2"/>
                <itemref idref="missing"/>
                <itemref idref="dtb"/>
              </spine>
            </package>
            """)
        zip.add("OEBPS/nav.xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <body>
              <nav epub:type="landmarks"><ol><li><a href="text/notes.xhtml">Notes</a></li></ol></nav>
              <nav epub:type="toc"><h1>Contents</h1>
                <ol>
                  <li><a href="text/chapter%201.xhtml">Part&nbsp;One &mdash; Start</a>
                    <ol><li><a href="text/chapter2.xhtml#sec">Section &copy; Two</a></li></ol>
                  </li>
                  <li><span>Appendix</span>
                    <ol><li><a href="text/chapter3.xhtml">Chapter Three</a></li></ol>
                  </li>
                  <li><a href="https://example.com">External</a></li>
                </ol>
              </nav>
            </body></html>
            """)
        zip.add("OEBPS/text/chapter 1.xhtml", chapter("One"))
        zip.add("OEBPS/text/chapter2.xhtml", chapter("Two"))
        zip.add("OEBPS/text/chapter3.xhtml", chapter("Three"))
        zip.add("OEBPS/text/chapter3.dtb", "<dtbook/>")
        zip.add("OEBPS/text/notes.xhtml", chapter("Notes"))
        zip.add("images/cover.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        return zip
    }

    /// EPUB 2: NCX navigation and `<meta name="cover">`.
    static func epub2() -> ZipFixture {
        var zip = ZipFixture()
        zip.add("mimetype", "application/epub+zip")
        zip.add("META-INF/container.xml", container)
        zip.add("OEBPS/content.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>Old Book</dc:title>
                <dc:creator opf:role="aut">Cy Author</dc:creator>
                <dc:identifier id="id">old-1</dc:identifier>
                <meta name="cover" content="cover-img"/>
              </metadata>
              <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="cover-img" href="cover.jpg" media-type="image/jpeg"/>
                <item id="a" href="a.html" media-type="application/xhtml+xml"/>
                <item id="b" href="b.html" media-type="application/xhtml+xml"/>
              </manifest>
              <spine toc="ncx"><itemref idref="a"/><itemref idref="b"/></spine>
            </package>
            """)
        zip.add("OEBPS/toc.ncx", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <navMap>
                <navPoint id="p1"><navLabel><text>First</text></navLabel><content src="a.html"/>
                  <navPoint id="p1a"><navLabel><text>Inner</text></navLabel><content src="a.html#inner"/></navPoint>
                </navPoint>
                <navPoint id="p2"><navLabel><text>Second</text></navLabel><content src="b.html"/></navPoint>
              </navMap>
            </ncx>
            """)
        zip.add("OEBPS/a.html", chapter("A"))
        zip.add("OEBPS/b.html", chapter("B"))
        zip.add("OEBPS/cover.jpg", data: Data([0xFF, 0xD8]))
        return zip
    }
}
