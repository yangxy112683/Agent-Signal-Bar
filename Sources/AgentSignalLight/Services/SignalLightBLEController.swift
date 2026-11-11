import AgentSignalLightCore
import Combine
import Foundation

enum HardwareCommandSource: Equatable {
    case liveSnapshot
    case pinned(SignalLightBLECommand)
}

struct SignalLightBLEBondStore {
    static let key = "signalLightBELastDeviceID"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func load() -> SignalLightBLEDevice.ID? {
        userDefaults.string(forKey: Self.key).flatMap { SignalLightBLEDevice.ID(rawValue: $0) }
    }

    func save(_ id: SignalLightBLEDevice.ID) {
        userDefaults.set(id.rawValue, forKey: Self.key)
    }
}

@MainActor
final class SignalLightBLEController: ObservableObject {
    @Published private(set) var connectionState: SignalLightBLEConnectionState = .disabled
    @Published private(set) var isHardwareDebugPinned = false
    @Published private(set) var pinnedHardwareCommand: SignalLightBLECommand?

    private let model: MenuBarStatusModel
    private let makeRadio: () -> SignalLightBLECommanding
    private let clock: SignalLightBLEClock
    private let bond: SignalLightBLEBondStore
    private let scanningStateTimeout: TimeInterval

    private var radio: SignalLightBLECommanding?
    private var cancellables = Set<AnyCancellable>()
    private var isActivated = false
    private var commandSource: HardwareCommandSource = .liveSnapshot

    private struct Outbox {
        var lastSent: SignalLightBLECommand?
        var needsFlush = false
        var force = false
        var task: Task<Void, Never>?
    }
    private var outbox = Outbox()

    private struct Hunt {
        var attempt: Int
        var deviceID: SignalLightBLEDevice.ID?
        var task: Task<Void, Never>?
    }
    private var hunt: Hunt?
    private var scanningStartedAt: Date?
    private var inFlightScan: Task<[SignalLightBLEDevice], Never>?

    convenience init(model: MenuBarStatusModel, userDefaults: UserDefaults = .standard) {
        self.init(
            model: model,
            userDefaults: userDefaults,
            makeRadio: { CoreBluetoothSignalLightCommander() }
        )
    }

    init(
        model: MenuBarStatusModel,
        userDefaults: UserDefaults,
        makeRadio: @escaping () -> SignalLightBLECommanding,
        clock: SignalLightBLEClock = SystemSignalLightBLEClock(),
        scanningStateTimeout: TimeInterval = 10
    ) {
        self.model = model
        self.makeRadio = makeRadio
        self.clock = clock
        self.bond = SignalLightBLEBondStore(userDefaults: userDefaults)
        self.scanningStateTimeout = scanningStateTimeout
    }

    deinit {
        hunt?.task?.cancel()
        inFlightScan?.cancel()
        outbox.task?.cancel()
    }

    func activate() {
        guard !isActivated else { return }
        isActivated = true

        model.$isSignalLightBLEEnabled.sink { [weak self] enabled in
            Task { @MainActor in
                self?.applyEnabled(enabled)
            }
        }
        .store(in: &cancellables)

        bindLightSnapshotSync()
    }

    func scanForDevices() async -> [SignalLightBLEDevice] {
        guard model.isSignalLightBLEEnabled else { return [] }
        if let inFlightScan {
            return await inFlightScan.value
        }
        let task = Task { @MainActor () -> [SignalLightBLEDevice] in
            self.connectionState = .scanning
            self.scanningStartedAt = self.clock.now()
            let devices = await self.radioOrArm().scanForDevices()
            if self.connectionState == .scanning {
                self.connectionState = .idle
            }
            self.scanningStartedAt = nil
            return devices
        }
        inFlightScan = task
        let devices = await task.value
        inFlightScan = nil
        return devices
    }

    func connect(to deviceID: SignalLightBLEDevice.ID) async -> Bool {
        guard model.isSignalLightBLEEnabled else { return false }
        connectionState = .connecting
        guard let device = await radioOrArm().connect(to: deviceID) else {
            await reduceConnectionState()
            return false
        }
        bond.save(device.id)
        hunt = Hunt(attempt: 0, deviceID: device.id, task: nil)
        requestOutbox(force: true)
        await outbox.task?.value
        await reduceConnectionState()
        return true
    }

    func disconnect() {
        guard model.isSignalLightBLEEnabled else { return }
        cancelHunt()
        outbox.lastSent = nil
        Task { @MainActor in
            await self.radio?.disconnect()
            await self.reduceConnectionState()
        }
    }

    func pinHardwareDebug(_ command: SignalLightBLECommand) {
        guard model.isSignalLightBLEEnabled else { return }
        pinnedHardwareCommand = command
        isHardwareDebugPinned = true
        commandSource = .pinned(command)
        requestOutbox(force: true)
    }

    func setHardwareDebugPinned(_ enabled: Bool) {
        guard isHardwareDebugPinned != enabled else { return }
        isHardwareDebugPinned = enabled
        if enabled {
            let command = pinnedHardwareCommand
                ?? SignalLightBLECommand.from(model.floatingSignalLightSnapshot.aggregate.displayState)
            pinnedHardwareCommand = command
            commandSource = .pinned(command)
            requestOutbox(force: true)
        } else {
            pinnedHardwareCommand = nil
            commandSource = .liveSnapshot
            requestOutbox(force: true)
        }
    }

    func resetOutboxForTesting() {
        outbox.lastSent = nil
    }

    private func applyEnabled(_ enabled: Bool) {
        if enabled {
            _ = radioOrArm()
            if hunt?.task != nil { return }
            if let saved = bond.load() {
                hunt = Hunt(attempt: 0, deviceID: saved, task: nil)
                startHunt()
            } else {
                hunt = nil
                connectionState = .idle
            }
            return
        }

        cancelHunt()
        outbox.lastSent = nil
        outbox.task?.cancel()
        outbox.task = nil
        connectionState = .disabled
        Task { @MainActor in
            await self.radio?.disconnect()
        }
    }

    private func bindLightSnapshotSync() {
        let publishers: [AnyPublisher<Void, Never>] = [
            model.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.$desktopAppSessions.map { _ in () }.eraseToAnyPublisher(),
            model.$signalLightAgentScopes.map { _ in () }.eraseToAnyPublisher(),
            model.$signalLightAgentSelectionMode.map { _ in () }.eraseToAnyPublisher(),
            model.$isMonitoringPaused.map { _ in () }.eraseToAnyPublisher(),
            model.$statusLightOverride.map { _ in () }.eraseToAnyPublisher(),
            model.animationClock.$tick.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(publishers)
            .sink { [weak self] _ in
                self?.requestOutbox(force: false)
            }
            .store(in: &cancellables)
    }

    private func radioOrArm() -> SignalLightBLECommanding {
        if let radio { return radio }
        let created = makeRadio()
        created.setOnUnexpectedDisconnect { [weak self] in
            await MainActor.run { self?.handleUnexpectedDrop() }
        }
        radio = created
        return created
    }

    private func requestOutbox(force: Bool = false) {
        outbox.needsFlush = true
        if force {
            outbox.force = true
        }
        guard outbox.task == nil else { return }
        outbox.task = Task { @MainActor in
            while self.outbox.needsFlush {
                self.outbox.needsFlush = false
                let forceFlush = self.outbox.force
                self.outbox.force = false
                await self.flushOutbox(force: forceFlush)
            }
            self.outbox.task = nil
        }
    }

    private func flushOutbox(force: Bool) async {
        guard model.isSignalLightBLEEnabled else { return }
        let command: SignalLightBLECommand
        switch commandSource {
        case .liveSnapshot:
            command = SignalLightBLECommand.from(
                model.floatingSignalLightSnapshot.aggregate.displayState
            )
        case .pinned(let pinned):
            command = pinned
        }
        guard force || command != outbox.lastSent else { return }
        outbox.lastSent = command
        let ok = await radioOrArm().send(command)
        if !ok {
            handleUnexpectedDrop()
        }
        await reduceConnectionState()
    }

    private func startHunt() {
        guard model.isSignalLightBLEEnabled, hunt != nil, hunt?.task == nil else { return }
        connectionState = .connecting
        let task = Task { @MainActor in
            while !Task.isCancelled {
                guard self.model.isSignalLightBLEEnabled, self.hunt != nil else { break }
                let attempt = self.hunt?.attempt ?? 0
                if var current = self.hunt {
                    current.attempt += 1
                    self.hunt = current
                }
                let deviceID = self.hunt?.deviceID ?? self.bond.load()
                var device: SignalLightBLEDevice?
                if let deviceID {
                    device = await self.radioOrArm().reconnect(to: deviceID)
                    if device == nil {
                        device = await self.radioOrArm().scanAndConnectFirst()
                    }
                } else {
                    device = await self.radioOrArm().scanAndConnectFirst()
                }
                if let device {
                    self.bond.save(device.id)
                    self.hunt = Hunt(attempt: 0, deviceID: device.id, task: nil)
                    self.requestOutbox(force: true)
                    await self.reduceConnectionState()
                    return
                }
                await self.clock.sleep(seconds: SignalLightBLEReconnectPolicy.interval(forAttempt: attempt))
            }
            if var current = self.hunt {
                current.task = nil
                self.hunt = current
            }
            await self.reduceConnectionState()
        }
        if var current = hunt {
            current.task = task
            hunt = current
        }
    }

    private func cancelHunt() {
        let existing = hunt
        hunt = nil
        existing?.task?.cancel()
    }

    private func handleUnexpectedDrop() {
        switch connectionState {
        case .connected, .connecting:
            break
        default:
            return
        }
        if hunt == nil {
            hunt = Hunt(attempt: 0, deviceID: bond.load(), task: nil)
        }
        startHunt()
    }

    private func reduceConnectionState() async {
        guard model.isSignalLightBLEEnabled else {
            connectionState = .disabled
            return
        }
        if case .scanning = connectionState {
            if let start = scanningStartedAt,
               clock.now().timeIntervalSince(start) > scanningStateTimeout {
                connectionState = .idle
                scanningStartedAt = nil
            } else {
                return
            }
        }
        if hunt?.task != nil {
            connectionState = .connecting
            return
        }
        if await radio?.isReadyToWrite == true {
            connectionState = .connected(deviceName: await radio?.connectedDeviceName)
        } else {
            connectionState = .idle
        }
    }
}
