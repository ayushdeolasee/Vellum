#if os(macOS)
import Sparkle

@MainActor
final class UpdateChecker {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}

#endif  // os(macOS) — iPad reference; see Platform/iOS
