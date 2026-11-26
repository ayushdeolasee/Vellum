/// Filenames to omit from ordinary library listings while leaving the files
/// available for recovery or for the writer to finish.
public enum SyncArtifact {
    public static func matches(_ name: String) -> Bool {
        // Syncthing conflicts retain the original extension. Its partial
        // downloads and Vellum's fixed and PDF staging names end in ".tmp".
        // Vellum also stages atomic writes as ".<name>.tmp-<nonce>".
        name.contains(".sync-conflict-")
            || name.hasSuffix(".tmp")
            || (name.hasPrefix(".") && name.contains(".tmp-"))
    }
}
