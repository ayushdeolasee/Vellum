import CShell
import Dispatch
import Foundation

private let swiftTurn: @convention(c) () -> Void = {
    precondition(shell_on_gtk_thread())
    _ = RunLoop.main.run(mode: .default, before: .distantPast)
}

private let pressed: @convention(c) () -> Void = {
    precondition(shell_on_gtk_thread())
    Task.detached {
        await Task.yield()
        let queued = DispatchTime.now().uptimeNanoseconds
        await MainActor.run {
            MainActor.preconditionIsolated()
            precondition(shell_on_gtk_thread())
            shell_probe_mark(0, DispatchTime.now().uptimeNanoseconds - queued)
        }
    }
    let queued = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.main.async {
        MainActor.preconditionIsolated()
        precondition(shell_on_gtk_thread())
        shell_probe_mark(1, DispatchTime.now().uptimeNanoseconds - queued)
    }
}

func runLoopProbe(mode: ShellPump, busy: Bool) -> Int32 {
    let selected = shell_install_pump(mode, swiftTurn)
    defer { shell_remove_pump() }
    guard selected >= 0 else {
        fputs("requested pump unavailable\n", stderr)
        return 77
    }
    if mode == SHELL_TIMER || mode == SHELL_MISSING { precondition(selected == SHELL_TIMER.rawValue) }
    if mode == SHELL_EVENTFD { precondition(selected == SHELL_EVENTFD.rawValue) }
    print("selected=\(selected == SHELL_EVENTFD.rawValue ? "eventfd" : "timer") load=\(busy ? "busy" : "idle")")
    return shell_probe_run(busy, pressed, getenv("VELLUM_PROBE_CAPTURE_DIR"))
}
