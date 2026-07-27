/// Decides whether a storage-relocation status change has reached a stable
/// enough point to refresh Settings ▸ Storage's inventory.
enum StorageRelocationInventoryReloadPolicy {
    static func shouldReload(for status: WebStorageRelocator.Status) -> Bool {
        !status.isInProgress
    }
}
