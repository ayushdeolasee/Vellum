import Foundation
import Dispatch
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public protocol FolderDirectoryWatching: Sendable {
    /// Called serially by the owning container. Failure to register a directory
    /// leaves periodic discovery active.
    func update(directories: Set<URL>, notify: @escaping @Sendable () -> Void)
    func stop()
}

/// One inotify descriptor for the tree on Linux. Darwin directory vnode
/// sources report membership changes, including Syncthing's atomic renames.
public final class FolderDirectoryWatcher: FolderDirectoryWatching, @unchecked Sendable {
    private let queue = DispatchQueue(label: "vellum.folder-watcher", qos: .utility)
    #if os(Linux)
    private var source: DispatchSourceRead?
    private var watches: Set<Int32> = []
    #else
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    #endif

    public init() {}

    public func update(directories: Set<URL>, notify: @escaping @Sendable () -> Void) {
        queue.sync {
            #if os(Linux)
            if source == nil {
                let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
                guard fd >= 0 else { return }
                let events = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                events.setEventHandler {
                    var buffer = [UInt8](repeating: 0, count: 16384)
                    while read(fd, &buffer, buffer.count) > 0 { }
                    // Overflow and ignored watches take the same full-scan path.
                    notify()
                }
                events.setCancelHandler { close(fd) }
                source = events
                events.resume()
            }
            guard let fd = source?.handle else { return }
            var retained: Set<Int32> = []
            for dir in directories {
                let mask = IN_CREATE | IN_DELETE | IN_MOVED_TO | IN_MOVED_FROM | IN_CLOSE_WRITE
                    | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR | IN_DONT_FOLLOW
                let wd = inotify_add_watch(fd, dir.path, UInt32(mask))
                if wd >= 0 { retained.insert(wd) }
            }
            for old in watches.subtracting(retained) { _ = inotify_rm_watch(fd, old) }
            watches = retained
            #else
            for dir in sources.keys where !directories.contains(dir) {
                sources.removeValue(forKey: dir)?.cancel()
            }
            for dir in directories {
                if let existing = sources[dir] {
                    // A replacement directory can have the same path.
                    var watched = stat(), current = stat()
                    if fstat(existing.handle, &watched) == 0, lstat(dir.path, &current) == 0,
                       watched.st_ino == current.st_ino, watched.st_dev == current.st_dev { continue }
                    existing.cancel()
                    sources.removeValue(forKey: dir)
                }
                let fd = open(dir.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { continue }
                let events = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
                events.setEventHandler(handler: notify)
                events.setCancelHandler { close(fd) }
                sources[dir] = events
                events.resume()
            }
            #endif
        }
    }

    public func stop() {
        queue.sync {
            #if os(Linux)
            source?.cancel()
            source = nil
            watches.removeAll()
            #else
            for source in sources.values { source.cancel() }
            sources.removeAll()
            #endif
        }
    }

    deinit { stop() }
}
