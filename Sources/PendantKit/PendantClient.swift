import Combine
import CoreBluetooth
import Foundation

public struct PendantCandidate: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public enum PendantClientState: String, Sendable {
    case disabled
    case bluetoothUnavailable
    case unauthorized
    case disconnected
    case scanning
    case connecting
    case discoveringServices
    case ready
}

/// Main-queue CoreBluetooth transport for the non-destructive protocol subset.
/// Bluetooth is initialized only after `enable()` so permission is deferred.
@MainActor
public final class PendantClient: NSObject, ObservableObject {
    @Published public private(set) var state: PendantClientState = .disabled
    @Published public private(set) var candidates: [PendantCandidate] = []
    @Published public private(set) var connectedName: String?
    @Published public private(set) var batteryPercent: Int?
    @Published public private(set) var lastEvent = "Bluetooth is disabled"
    @Published public private(set) var lastPayloadByteCount: Int?
    @Published public private(set) var storedPageCount = 0
    @Published public private(set) var pageVaultError: String?

    public var onPayload: ((Data) -> Void)?

    private static let rememberedPeripheralKey = "LessLimitless.rememberedPeripheral"
    private let defaults: UserDefaults
    private var reassembler = FragmentReassembler()
    private var central: CBCentralManager?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var dataNotificationsReady = false
    private var bootstrapSent = false
    private var bootstrapWriteSucceeded = false
    private var bootstrapEncryptionRetryCount = 0
    private static let maximumBootstrapEncryptionRetries = 3
    private var outboundQueue: [Data] = []
    private var writeInFlight = false
    private var messageIndex: UInt32 = 0
    private var pageIngestor: PendantPageIngestor?
    private var enabled = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    public func enable() {
        guard !enabled else {
            if central?.state == .poweredOn { scan() }
            return
        }
        enabled = true
        initializePageVaultIfNeeded()
        state = .disconnected
        lastEvent = "Starting Bluetooth"
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func disable() {
        enabled = false
        central?.stopScan()
        if let connectedPeripheral { central?.cancelPeripheralConnection(connectedPeripheral) }
        clearConnection()
        candidates = []
        state = .disabled
        lastEvent = "Bluetooth is disabled"
    }

    public func scan() {
        guard enabled, let central, central.state == .poweredOn else { return }
        candidates = []
        discovered = [:]
        state = .scanning
        lastEvent = "Scanning for pendants"
        central.scanForPeripherals(
            withServices: [CBUUID(string: PendantUUIDs.audioService)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    public func connect(to identifier: UUID) {
        bootstrapEncryptionRetryCount = 0
        guard state == .scanning || state == .disconnected else {
            lastEvent = "A pendant connection is already in progress"
            return
        }
        guard enabled, let central, central.state == .poweredOn else { return }
        let peripheral = discovered[identifier]
            ?? central.retrievePeripherals(withIdentifiers: [identifier]).first
        guard let peripheral else {
            lastEvent = "That pendant is no longer available; scan again"
            return
        }
        central.stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        lastEvent = "Connecting to \(peripheral.name ?? "Pendant")"
        central.connect(peripheral, options: nil)
    }

    public func disconnect() {
        guard let connectedPeripheral else { return }
        central?.cancelPeripheralConnection(connectedPeripheral)
    }

    public func forgetPendant() {
        disconnect()
        defaults.removeObject(forKey: Self.rememberedPeripheralKey)
        lastEvent = "Forgot remembered pendant"
    }

    private func initializePageVaultIfNeeded() {
        guard pageIngestor == nil else { return }
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let root = appSupport
                .appendingPathComponent("LessLimitless", isDirectory: true)
                .appendingPathComponent("RawPageVault", isDirectory: true)
            let ingestor = try PendantPageIngestor(rootURL: root)
            pageIngestor = ingestor
            Task { [weak self] in
                let count = await ingestor.recordCount()
                guard let self, self.pageIngestor === ingestor else { return }
                self.storedPageCount = count
            }
        } catch {
            pageVaultError = "Could not initialize local page vault"
        }
    }

    public func requestDeviceInfo() { send(.getDeviceInfo) }
    public func requestDeviceStatus() { send(.getDeviceStatus) }

    public func synchronizeClock(date: Date = Date()) {
        send(.setCurrentTime(millisecondsSince1970: Int64(date.timeIntervalSince1970 * 1_000)))
    }

    /// Starts a read-only batch transfer. It does not ACK or erase device data.
    public func requestStoredPages() {
        send(.downloadFlashPages(batch: true, realTime: false))
    }

    private func send(_ command: PendantCommand) {
        guard state == .ready,
              let peripheral = connectedPeripheral,
              controlCharacteristic != nil else {
            lastEvent = "Pendant is not ready"
            return
        }
        let index = nextMessageIndex()
        let payload = PendantWire.encodeApplicationCommand(command, requestID: index &+ 1)
        do {
            let fragments = try PendantWire.encodeFragments(
                payload: payload,
                messageIndex: index,
                maximumWriteLength: peripheral.maximumWriteValueLength(for: .withResponse)
            )
            outboundQueue.append(contentsOf: fragments)
            writeNextFragmentIfPossible()
            lastEvent = "Queued \(String(describing: command))"
        } catch {
            lastEvent = "Could not encode command: \(error.localizedDescription)"
        }
    }

    private func nextMessageIndex() -> UInt32 {
        let current = messageIndex
        messageIndex &+= 1
        return current
    }

    private func restoreOrScan() {
        guard let raw = defaults.string(forKey: Self.rememberedPeripheralKey),
              let identifier = UUID(uuidString: raw),
              let peripheral = central?.retrievePeripherals(withIdentifiers: [identifier]).first else {
            scan()
            return
        }
        discovered[identifier] = peripheral
        candidates = [PendantCandidate(
            id: identifier,
            name: peripheral.name ?? "Remembered Pendant",
            rssi: 0
        )]
        connect(to: identifier)
    }

    private func becomeReadyIfPossible() {
        guard state != .ready,
              controlCharacteristic != nil,
              dataCharacteristic != nil,
              dataNotificationsReady,
              bootstrapWriteSucceeded else { return }
        state = .ready
        lastEvent = "Pendant is ready"
        defaults.set(connectedPeripheral?.identifier.uuidString, forKey: Self.rememberedPeripheralKey)
        requestDeviceInfo()
        requestDeviceStatus()
    }

    /// The encrypted control write prompts macOS to bond on first use.
    private func triggerPairingIfPossible() {
        guard !bootstrapSent,
              let peripheral = connectedPeripheral,
              controlCharacteristic != nil else { return }
        bootstrapSent = true
        let index = nextMessageIndex()
        let command = PendantWire.encodeApplicationCommand(
            .setCurrentTime(millisecondsSince1970: Int64(Date().timeIntervalSince1970 * 1_000)),
            requestID: index &+ 1
        )
        do {
            let fragments = try PendantWire.encodeFragments(
                payload: command,
                messageIndex: index,
                maximumWriteLength: peripheral.maximumWriteValueLength(for: .withResponse)
            )
            outboundQueue.append(contentsOf: fragments)
            writeNextFragmentIfPossible()
            lastEvent = "Waiting for pendant pairing"
        } catch {
            failConnection("Could not prepare the pairing command")
        }
    }

    /// `.withResponse` permits only one logical write at a time. Advance the
    /// queue from `didWriteValueFor` so a failed fragment stops the command.
    private func writeNextFragmentIfPossible() {
        guard !writeInFlight,
              !outboundQueue.isEmpty,
              let peripheral = connectedPeripheral,
              let characteristic = controlCharacteristic else { return }
        writeInFlight = true
        peripheral.writeValue(outboundQueue.removeFirst(), for: characteristic, type: .withResponse)
    }

    private func clearConnection() {
        connectedPeripheral = nil
        controlCharacteristic = nil
        dataCharacteristic = nil
        batteryCharacteristic = nil
        dataNotificationsReady = false
        bootstrapSent = false
        bootstrapWriteSucceeded = false
        outboundQueue = []
        writeInFlight = false
        connectedName = nil
        batteryPercent = nil
        lastPayloadByteCount = nil
        // Replacing the actor prevents fragments from separate connections
        // sharing an index from entering the same assembly state.
        reassembler = FragmentReassembler()
    }

    private func failConnection(_ message: String) {
        if let connectedPeripheral { central?.cancelPeripheralConnection(connectedPeripheral) }
        clearConnection()
        state = enabled ? .disconnected : .disabled
        lastEvent = message
    }

    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        enabled && connectedPeripheral === peripheral
    }
}

extension PendantClient: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard self.central === central, self.enabled else { return }
            switch central.state {
            case .poweredOn:
                self.state = .disconnected
                self.lastEvent = "Bluetooth is available"
                self.restoreOrScan()
            case .unauthorized:
                self.state = .unauthorized
                self.lastEvent = "Bluetooth permission is required"
            case .unsupported, .poweredOff:
                self.state = .bluetoothUnavailable
                self.lastEvent = "Bluetooth is unavailable"
            case .resetting, .unknown:
                self.state = .bluetoothUnavailable
                self.lastEvent = "Bluetooth is not ready"
            @unknown default:
                self.state = .bluetoothUnavailable
                self.lastEvent = "Unknown Bluetooth state"
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let identifier = peripheral.identifier
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Pendant"
        let strength = RSSI.intValue
        Task { @MainActor in
            guard self.central === central, self.enabled, self.state == .scanning else { return }
            self.discovered[identifier] = peripheral
            let candidate = PendantCandidate(id: identifier, name: name, rssi: strength)
            self.candidates.removeAll { $0.id == identifier }
            self.candidates.append(candidate)
            self.candidates.sort { $0.rssi > $1.rssi }
            self.lastEvent = "Found \(self.candidates.count) pendant\(self.candidates.count == 1 ? "" : "s")"
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard self.central === central, self.isCurrent(peripheral) else { return }
            self.connectedName = peripheral.name ?? "Pendant"
            self.state = .discoveringServices
            self.lastEvent = "Discovering pendant services"
            peripheral.discoverServices([
                CBUUID(string: PendantUUIDs.audioService),
                CBUUID(string: PendantUUIDs.batteryService)
            ])
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.central === central, self.connectedPeripheral === peripheral else { return }
            self.failConnection(error.map { "Connection failed: \($0.localizedDescription)" } ?? "Connection failed")
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.central === central, self.connectedPeripheral === peripheral else { return }
            self.clearConnection()
            self.state = self.enabled ? .disconnected : .disabled
            self.lastEvent = self.enabled
                ? (error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected")
                : "Bluetooth is disabled"
        }
    }
}

extension PendantClient: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        Task { @MainActor in
            guard self.isCurrent(peripheral) else { return }
            if let error {
                self.failConnection("Service discovery failed: \(error.localizedDescription)")
                return
            }
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let characteristics = service.characteristics ?? []
        let serviceUUID = service.uuid.uuidString.uppercased()
        Task { @MainActor in
            guard self.isCurrent(peripheral) else { return }
            if let error {
                self.failConnection("Characteristic discovery failed: \(error.localizedDescription)")
                return
            }
            for characteristic in characteristics {
                switch characteristic.uuid.uuidString.uppercased() {
                case PendantUUIDs.control:
                    self.controlCharacteristic = characteristic
                case PendantUUIDs.data:
                    self.dataCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case PendantUUIDs.batteryLevel:
                    self.batteryCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                    peripheral.setNotifyValue(true, for: characteristic)
                default:
                    break
                }
            }
            if serviceUUID == PendantUUIDs.audioService {
                guard self.controlCharacteristic != nil, self.dataCharacteristic != nil else {
                    self.failConnection("This device does not expose the required pendant characteristics")
                    return
                }
                self.triggerPairingIfPossible()
                self.becomeReadyIfPossible()
            }
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid.uuidString.uppercased()
        let notifying = characteristic.isNotifying
        Task { @MainActor in
            guard self.isCurrent(peripheral), uuid == PendantUUIDs.data else { return }
            if let error {
                self.dataNotificationsReady = false
                self.failConnection("Could not enable pendant notifications: \(error.localizedDescription)")
                return
            }
            self.dataNotificationsReady = notifying
            self.becomeReadyIfPossible()
        }
    }
    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let value = characteristic.value
        let uuid = characteristic.uuid.uuidString.uppercased()
        Task { @MainActor in
            guard self.isCurrent(peripheral) else { return }
            if let error {
                self.lastEvent = "Pendant update failed: \(error.localizedDescription)"
                return
            }
            guard let value else { return }
            if uuid == PendantUUIDs.batteryLevel {
                if let level = value.first { self.batteryPercent = min(100, Int(level)) }
                return
            }
            guard uuid == PendantUUIDs.data else { return }
            let currentReassembler = self.reassembler
            do {
                let fragment = try PendantWire.decodeEnvelope(value)
                guard let payload = try await currentReassembler.receive(fragment) else { return }
                guard self.isCurrent(peripheral), self.reassembler === currentReassembler else { return }
                self.lastPayloadByteCount = payload.count
                do {
                    if let ingestor = self.pageIngestor,
                       let ingestion = try await ingestor.ingest(payload, deviceID: peripheral.identifier.uuidString) {
                        self.storedPageCount = await ingestor.recordCount()
                        self.lastEvent = ingestion.summary == nil
                            ? "Stored raw page; metadata needs review"
                            : "Stored pendant page locally"
                    } else {
                        self.lastEvent = "Received pendant data"
                    }
                } catch {
                    self.pageVaultError = "Could not preserve a received pendant page locally"
                    self.lastEvent = self.pageVaultError ?? "Local page vault error"
                }
                self.onPayload?(payload)
            } catch {
                self.lastEvent = "Ignored malformed pendant data"
            }
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.isCurrent(peripheral), characteristic === self.controlCharacteristic else { return }
            self.writeInFlight = false
            if let error {
                self.outboundQueue = []
                // macOS returns insufficientEncryption or insufficientAuthentication
                // on the first bootstrap writes while it silently negotiates bonding;
                // retry until bonding lands instead of treating the OS's own pairing
                // handshake as a failure.
                let bondingHandshakeCodes: Set<CBATTError.Code> = [.insufficientEncryption, .insufficientAuthentication]
                if self.bootstrapSent, !self.bootstrapWriteSucceeded,
                   let attCode = (error as? CBATTError)?.code, bondingHandshakeCodes.contains(attCode),
                   self.bootstrapEncryptionRetryCount < Self.maximumBootstrapEncryptionRetries {
                    self.bootstrapEncryptionRetryCount += 1
                    self.bootstrapSent = false
                    self.lastEvent = "Waiting for pendant pairing to complete"
                    self.triggerPairingIfPossible()
                    return
                }
                self.failConnection("Pendant write failed: \(error.localizedDescription)")
                return
            }
            if self.bootstrapSent, !self.bootstrapWriteSucceeded {
                self.bootstrapWriteSucceeded = true
                self.becomeReadyIfPossible()
            }
            self.writeNextFragmentIfPossible()
        }
    }
}
