import CShell
import Glibc

@main
enum App {
    // GTK and the Dispatch main queue must share the process startup pthread.
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let modes = ["auto": SHELL_AUTO, "timer": SHELL_TIMER,
                     "missing": SHELL_MISSING, "eventfd": SHELL_EVENTFD]
        guard args.count == 3, args[0] == "--probe", let mode = modes[args[1]],
              ["idle", "busy"].contains(args[2]) else {
            fputs("usage: vellum-linux --probe auto|timer|missing|eventfd idle|busy\n", stderr)
            exit(64)
        }
        exit(runLoopProbe(mode: mode, busy: args[2] == "busy"))
    }
}
