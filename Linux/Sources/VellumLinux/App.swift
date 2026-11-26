import CShell
import Foundation
import Glibc

@main
enum App {
    // GTK and the Dispatch main queue must share the process startup pthread.
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || (args.count == 2 && args[0] == "--library" && args[1].hasPrefix("/")) {
            let root = args.last.map { URL(fileURLWithPath: $0, isDirectory: true) }
            exit(ReaderController(rootOverride: root).run())
        }
        if args == ["--web-probe"] {
            exit(ReaderController(rootOverride: ReaderPreferences.defaultLibrary, webProbe: WebProbe()).run())
        }
        let modes = ["auto": SHELL_AUTO, "timer": SHELL_TIMER,
                     "missing": SHELL_MISSING, "eventfd": SHELL_EVENTFD]
        guard args.count == 3, args[0] == "--probe", let mode = modes[args[1]],
              ["idle", "busy"].contains(args[2]) else {
            fputs("usage: vellum-linux [--library /absolute/root] | --web-probe | --probe auto|timer|missing|eventfd idle|busy\n", stderr)
            exit(64)
        }
        exit(runLoopProbe(mode: mode, busy: args[2] == "busy"))
    }
}
