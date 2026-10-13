import Foundation
import Testing
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
@testable import Vellum

@Suite("Home PDF and link drops", .serialized)
@MainActor
struct HomeDropTests {
    #if os(macOS)
    @Test("Native Mac pasteboard files and messages forward through a click-through destination")
    func nativePasteboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = NSPasteboardItem()
        let message = NSPasteboardItem()
        let url = NSPasteboardItem()
        let pdf = URL(fileURLWithPath: "/tmp/dragged paper.pdf")
        file.setString(pdf.absoluteString, forType: .fileURL)
        message.setString("Read https://example.com/message. Enjoy!", forType: .string)
        url.setString("https://example.com/article", forType: .URL)
        url.setString("Title without a link", forType: .string)
        #expect(pasteboard.writeObjects([file, message, url]))
        let providers = HomeDropView.providers(from: pasteboard)
        pasteboard.clearContents()
        let delivery = await HomeDrop.load(providers)
        #expect(delivery.urls.map(\.absoluteString) == [
            pdf.absoluteString, "https://example.com/message", "https://example.com/article"
        ])
        #expect(delivery.errors.isEmpty)
        let view = HomeDropView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(view.hitTest(NSPoint(x: 200, y: 150)) == nil)
    }
    #endif

    @Test("Messages open the first web link, skipping email and unsupported schemes")
    func messageLink() {
        #expect(HomeDrop.link(in: "Email reader@example.com; read https://example.com/article?x=1#part, then https://example.org.")?.absoluteString == "https://example.com/article?x=1#part")
        #expect(HomeDrop.link(in: "No article link here") == nil)
        #expect(!HomeDrop.isSupported(URL(string: "javascript:alert(1)")!))
        #expect(!HomeDrop.isSupported(URL(fileURLWithPath: "/tmp/image.png")))
    }

    @Test("HTML link labels retain destinations without loading WebKit")
    func htmlLink() {
        let data = Data("<a href=\"https://example.com/article?a=1&amp;b=2\">this article</a>".utf8)
        #expect(HomeDrop.linkInData(data, type: .html)?.absoluteString == "https://example.com/article?a=1&b=2")
    }

    @Test("URL representation wins over title text and duplicate URLs are coalesced")
    func urlProvider() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { complete in
            complete(Data("https://example.com/article".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { complete in
            complete(Data("Title: https://example.org/wrong".utf8), nil)
            return nil
        }
        let delivery = await HomeDrop.load([provider, provider])
        #expect(delivery.urls.map(\.absoluteString) == ["https://example.com/article"])
        #expect(delivery.errors.isEmpty)
    }

    @Test("Message providers open links and report linkless drops")
    func messageProvider() async {
        let delivery = await HomeDrop.load([NSItemProvider(object: "Read this: https://example.com/article" as NSString)])
        #expect(delivery.urls.first?.host == "example.com")
        #expect(delivery.errors.isEmpty)
        let unsupported = await HomeDrop.load([NSItemProvider(object: "No article here" as NSString)])
        #expect(unsupported.urls.isEmpty && !unsupported.errors.isEmpty)
    }

    @Test("Files binary-plist representation keeps the PDF path intact")
    func fileURLProvider() async throws {
        let url = URL(fileURLWithPath: "/tmp/a paper.PDF")
        let data = try PropertyListSerialization.data(fromPropertyList: [url.absoluteString, Data()], format: .binary, options: 0)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { complete in
            complete(data, nil)
            return nil
        }
        let delivery = await HomeDrop.load([provider])
        #expect(delivery.urls == [url])
        #expect(delivery.errors.isEmpty)
    }

    @Test("Provider PDF bytes survive removal of the source file")
    func promisedPDF() async throws {
        _ = try #require(TestEnvironment.storageRoot)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let bytes = Data("%PDF-1.7\nProvider lifetime fixture".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = NSItemProvider()
        provider.suggestedName = "Dropped paper.pdf"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { complete in
            complete(source, false, nil)
            return nil
        }
        let delivery = await HomeDrop.load([provider])
        let copy = try #require(delivery.urls.first)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: source)
        #expect(copy.lastPathComponent == "Dropped paper.pdf")
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(delivery.errors.isEmpty)
    }
}
