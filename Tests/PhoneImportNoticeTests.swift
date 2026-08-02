#if os(iOS)
import Foundation
import Testing

@testable import Vellum

// What the phone shell says when a file arrives that it cannot open (#151).
//
// Widening the target to iPhone made Vellum an "Open in" / share-sheet
// destination there — `CFBundleDocumentTypes` has no idiom — while the shell
// that receives the resulting `.vellumOpenFile` is still a placeholder. The
// failure this pins down is the SILENT one: `VellumApp_iOS` copies the file
// into the library and posts, and if nothing reads the payload the user is left
// looking at "being built" with no reason to think anything happened.
//
// The payload contract is the point: `VellumApp_iOS` posts `["paths": [String]]`
// on an import and NO userInfo for ⌘O ("show the picker"), so these are the two
// shapes, plus the malformed one.

@Suite("Phone import notice")
struct PhoneImportNoticeTests {
    @Test("An imported file is reported as kept, not opened")
    func oneImportedFileIsAccountedFor() {
        let notice = PhoneImportNotice(userInfo: ["paths": ["/library/a.pdf"]])
        #expect(notice == .imported(count: 1))
        // The two things the user needs: their file is not lost, and where to
        // go for it.
        #expect(notice.message.contains("saved to your library"))
        #expect(notice.message.contains("iPad"))
    }

    @Test("Several files at once are counted and referred to in the plural")
    func severalImportedFilesAreCounted() {
        let notice = PhoneImportNotice(
            userInfo: ["paths": ["/library/a.pdf", "/library/b.pdf", "/library/c.pdf"]])
        #expect(notice == .imported(count: 3))
        #expect(notice.message.contains("Those 3 documents"))
        #expect(notice.message.contains("Open them"))
    }

    @Test("A payload-less post is ⌘O, which has nothing to open into")
    func noPayloadMeansTheImporterIsUnavailable() {
        #expect(PhoneImportNotice(userInfo: nil) == .unavailable)
        #expect(PhoneImportNotice(userInfo: [:]) == .unavailable)
        #expect(PhoneImportNotice(userInfo: nil).message.contains("isn't available"))
    }

    @Test("A payload that isn't a non-empty path list never claims files were saved")
    func malformedPayloadsDoNotClaimAnImport() {
        // An empty list is what `handleIncomingFile` refuses to post at all,
        // and the wrong type could only come from a future caller — neither may
        // tell the user their document is in the library.
        #expect(PhoneImportNotice(userInfo: ["paths": [String]()]) == .unavailable)
        #expect(PhoneImportNotice(userInfo: ["paths": 7]) == .unavailable)
    }
}
#endif
