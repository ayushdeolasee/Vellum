import Foundation

/// Process-boundary isolation, installed before either app entry constructs stores.
enum UITestLaunchConfiguration {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    static var storageRoot: URL? {
        guard isEnabled else { return nil }
        do {
            return try validatedStorageRoot(arguments: ProcessInfo.processInfo.arguments)
        } catch {
            fatalError("[UITest] Refusing to use production storage: \(error)")
        }
    }

    enum ConfigurationError: Error {
        case missingStorageRoot, invalidStorageRoot
    }

    /// Pure validation lets the failure paths be tested without resetting anything.
    static func validatedStorageRoot(arguments: [String]) throws -> URL {
        guard let index = arguments.firstIndex(of: "--ui-test-storage-root"),
              arguments.indices.contains(index + 1)
        else { throw ConfigurationError.missingStorageRoot }
        let path = arguments[index + 1]
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw ConfigurationError.invalidStorageRoot
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first?.resolvingSymlinksInPath()
        // A reset root must never cover the user's home or application-support data.
        guard root.path != "/", root != home,
              !home.path.hasPrefix(root.path + "/"),
              support.map({ $0.path.hasPrefix(root.path + "/") || root.path.hasPrefix($0.path + "/") || root == $0 }) != true
        else { throw ConfigurationError.invalidStorageRoot }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw ConfigurationError.invalidStorageRoot
        }
        return root
    }

    @discardableResult
    static func prepare() -> String? {
        guard isEnabled else { return nil }
        // Validate and create the root BEFORE defaults, credentials, or library writes.
        guard let root = storageRoot else { fatalError("UI tests require isolated storage") }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { fatalError("Could not create UI-test storage: \(error)") }

        WebLibrary.storeDirOverride = root.appendingPathComponent("web", isDirectory: true)
        WebLibrary.layoutOverride = .local(storeDir: WebLibrary.storeDir)
        DocumentDataStore.rootDirectoryOverride = WebLibrary.activeLayout.documentsDir
        ScratchpadAttachmentStore.directoryOverride = root.appendingPathComponent("scratchpad-attachments", isDirectory: true)
        DocumentAccessBookmarkStore.rootDirectoryOverride = root.appendingPathComponent("DocumentAccess", isDirectory: true)

        if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-state") {
            AppDefaults.resetTestDomain()
        }
        WebStorageSettings.setMode(.local)
        if !ProcessInfo.processInfo.arguments.contains("--ui-test-show-walkthrough") {
            WalkthroughSettings.markSeen()
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-corrupt-restoration") {
            AppDefaults.current.set("{not valid workspace json", forKey: "vellum.workspace")
        }
        return value(after: "--ui-test-open-document")
    }

    private static func value(after switchName: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: switchName), arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}
