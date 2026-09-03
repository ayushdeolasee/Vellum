#if os(macOS)
import Sparkle

@MainActor
final class UpdateChecker {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: RuntimeProfile.current.allowsProductionServices
                && RuntimeProfile.current.syncEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil)
    }

    func check() {
        guard RuntimeProfile.current.allowsProductionServices,
              RuntimeProfile.current.syncEnabled
        else { return }
        controller.checkForUpdates(nil)
    }
}

#endif  // os(macOS) — iPad reference; see Platform/iOS
