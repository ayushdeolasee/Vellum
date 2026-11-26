/// Each settings backend serializes the first read and write of its device ID.
public protocol DeviceIDDefaults: Sendable {
    associatedtype Failure: Error
    func loadOrCreateID(forKey key: String) throws(Failure) -> String
}

public struct DeviceIdentityProvider<Defaults: DeviceIDDefaults>: Sendable {
    public let defaults: Defaults
    public let name: String
    public let platform: String

    public init(defaults: Defaults, name: String, platform: String) {
        self.defaults = defaults
        self.name = name
        self.platform = platform
    }

    public func current() throws(Defaults.Failure) -> DeviceIdentity {
        let id = try defaults.loadOrCreateID(forKey: DeviceIdentity.defaultsKey)
        return DeviceIdentity(id: DeviceID(id), name: name, platform: platform)
    }
}
