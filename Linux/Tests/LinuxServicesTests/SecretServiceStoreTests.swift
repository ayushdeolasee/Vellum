import Foundation
import LinuxServices
import Testing

private let isolatedKeyring: Bool = {
    let env = ProcessInfo.processInfo.environment
    guard let root = env["VELLUM_TEST_KEYRING"] else { return false }
    return env["HOME"] == root && env["XDG_DATA_HOME"] == root + "/data"
        && env["DBUS_SESSION_BUS_ADDRESS"] == "unix:path=" + root + "/run/bus"
}()

@Test(.enabled(if: isolatedKeyring, "Run inside Linux/scripts/with-test-keyring.sh"))
func missingSavedDeletedAndLockedAreDistinct() async throws {
    let store = SecretServiceStore()
    let service = "org.vellum.synthetic-c8"
    #expect(await store.read("test", service: service) == .missing)
    #expect(await store.write("  fixture 🌱  ", account: "test", service: service) == .saved)
    #expect(await store.read("test", service: service) == .value("fixture 🌱"))
    #expect(await store.read("test", service: service + ".other") == .missing)
    #expect(await store.write("replacement", account: "test", service: service) == .saved)
    #expect(await store.read("test", service: service) == .value("replacement"))
    #expect(await store.delete("test", service: service))
    #expect(await store.delete("test", service: service))
    #expect(await store.read("test", service: service) == .missing)
    #expect(await store.write("lock fixture", account: "test", service: service) == .saved)

    let lock = Process()
    lock.executableURL = URL(fileURLWithPath: "/usr/bin/gdbus")
    lock.arguments = ["call", "--session", "--dest", "org.freedesktop.secrets",
                      "--object-path", "/org/freedesktop/secrets", "--method", "org.freedesktop.Secret.Service.Lock",
                      "['/org/freedesktop/secrets/collection/login']"]
    try lock.run()
    lock.waitUntilExit()
    try #require(lock.terminationStatus == 0)
    #expect(await store.read("test", service: service) == .unavailable)
    #expect(await store.write("blocked", account: "test", service: service) == .failed)
    #expect(await !store.delete("test", service: service))
}
