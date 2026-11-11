import Foundation

public enum SignalLightBLEConnectionState: Sendable, Equatable {
    case disabled
    case idle
    case scanning
    case connecting
    case connected(deviceName: String?)
}

public struct SignalLightBLEDevice: Sendable, Equatable, Identifiable {
    public struct ID: Hashable, Sendable, RawRepresentable {
        public let rawValue: String

        public init?(rawValue: String) {
            guard UUID(uuidString: rawValue) != nil else { return nil }
            self.rawValue = rawValue
        }

        public init?(_ rawValue: String) { self.init(rawValue: rawValue) }
    }

    public let id: ID
    public let name: String

    public init(id: ID, name: String) {
        self.id = id
        self.name = name
    }
}

package protocol SignalLightBLECommanding: Sendable {
    var isReadyToWrite: Bool { get async }
    var connectedDeviceName: String? { get async }

    func scanForDevices() async -> [SignalLightBLEDevice]
    func connect(to deviceID: SignalLightBLEDevice.ID) async -> SignalLightBLEDevice?
    func reconnect(to deviceID: SignalLightBLEDevice.ID) async -> SignalLightBLEDevice?
    func scanAndConnectFirst() async -> SignalLightBLEDevice?
    func send(_ command: SignalLightBLECommand) async -> Bool
    func disconnect() async
    func setOnUnexpectedDisconnect(_ handler: @escaping @Sendable () async -> Void)
}
