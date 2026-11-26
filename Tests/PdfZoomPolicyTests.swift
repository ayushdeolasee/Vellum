import Testing

@testable import Vellum

@Suite("PDF absolute zoom in the app")
struct PdfFreeModeTests {
    @MainActor
    @Test("The app-wide bounds the viewers install are the ones .free resolves to")
    func freeMatchesTheStoresZoomRange() {
        #expect(AppStore.minZoom == 0.25)
        #expect(AppStore.maxZoom == 4.0)
        #expect(AppStore.freePdfZoom.minimumScale == AppStore.minZoom)
        #expect(AppStore.freePdfZoom.maximumScale == AppStore.maxZoom)
    }
}
