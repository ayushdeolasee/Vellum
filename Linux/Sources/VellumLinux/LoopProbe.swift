import CShell
import Dispatch
import Foundation

private let swiftTurn: @convention(c) () -> Void = {
    precondition(shell_on_gtk_thread())
    _ = RunLoop.main.run(mode: .default, before: .distantPast)
    shell_probe_turn_finished()
}

private func checkThread() {
    MainActor.preconditionIsolated()
    precondition(shell_on_gtk_thread())
}

// Each lane keeps a successor queued until the shared monotonic deadline.
private func dispatchLane() {
    DispatchQueue.main.async {
        checkThread()
        if shell_probe_load_step(1) { dispatchLane() }
    }
}

private func actorLane() {
    Task { @MainActor in
        checkThread()
        if shell_probe_load_step(0) { actorLane() }
    }
}

private func startSamples(busy: Bool) {
    precondition(shell_on_gtk_thread())
    // GTK still owns this turn, so the complete FIFO burst is pending together.
    for sequence in 0..<Int32(PROBE_FIFO) {
        DispatchQueue.main.async {
            checkThread()
            shell_probe_fifo(sequence)
        }
    }
    let producer = DispatchQueue(label: "vellum.probe.samples")
    var deadline = DispatchTime.now()
    for sequence in 0..<Int32(PROBE_SAMPLES) {
        // Absolute deadlines on a serial worker. Vary the spacing across the 8 ms tick.
        deadline = deadline + .microseconds(7_000 + Int((sequence * 7919) % 6_001))
        producer.asyncAfter(deadline: deadline) {
            Task.detached {
                await Task.yield()
                let queued = DispatchTime.now().uptimeNanoseconds
                await MainActor.run {
                    checkThread()
                    shell_probe_mark(0, sequence, DispatchTime.now().uptimeNanoseconds - queued)
                }
            }
            let queued = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                checkThread()
                shell_probe_mark(1, sequence, DispatchTime.now().uptimeNanoseconds - queued)
            }
        }
    }
    if busy {
        for _ in 0..<PROBE_LANES {
            dispatchLane()
            actorLane()
        }
    }
}

func runLoopProbe(mode: ShellPump, busy: Bool) -> Int32 {
    let selected = shell_install_pump(mode, swiftTurn)
    defer { shell_remove_pump() }
    guard selected >= 0 else {
        fputs("effective=unavailable requested pump unavailable\n", stderr)
        return mode == SHELL_EVENTFD ? 77 : 1
    }
    print("selected=\(String(cString: shell_effective_pump())) load=\(busy ? "busy" : "idle")")
    return shell_probe_run(busy, startSamples, getenv("VELLUM_PROBE_CAPTURE_DIR"))
}
