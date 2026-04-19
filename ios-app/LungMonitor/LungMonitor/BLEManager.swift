//
//  BLEManager.swift
//  LungMonitor
//

import Combine
import CoreBluetooth
import Foundation

/// Result of writing the receive buffer to a `.wav` file (debug export).
enum WAVExportResult {
    case success(URL)
    case failure(String)
}

/// A name and stable id for one row in the scan list.
struct ScannedDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// Scans for BLE peripherals, can connect to one, then discovers its GATT services.
final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var bluetoothStateText = "Bluetooth: starting…"
    @Published private(set) var connectionStatusText = "Connection: not connected"
    @Published private(set) var discoveredDevices: [ScannedDevice] = []
    /// Total bytes stored in `receivedDataBuffer` (updates as packets arrive).
    @Published private(set) var totalReceivedByteCount = 0
    /// Most recent WAV file from `exportReceiveBufferAsWAV()` (for the share sheet).
    @Published private(set) var lastExportedWAVURL: URL?
    /// Latest server `/analyze` JSON summary for the UI (updated after upload).
    @Published var analysisResultText: String = ""

    private var central: CBCentralManager!
    /// Latest `CBPeripheral` seen for each identifier (needed to connect).
    private var peripheralByID: [UUID: CBPeripheral] = [:]
    /// Latest display name we computed while scanning (advertisement or peripheral name).
    private var nameByID: [UUID: String] = [:]
    /// How many `discoverCharacteristics` calls are still waiting for `didDiscoverCharacteristicsFor`.
    private var outstandingCharacteristicDiscoveries = 0
    /// Running count of characteristics seen (after discovery completes).
    private var totalCharacteristicsFound = 0
    /// How many of those support notify or indicate (common for streamed payloads once you subscribe).
    private var characteristicsWithNotifyOrIndicate = 0
    /// The peripheral we are connected to (used after discovery to subscribe).
    private var connectedPeripheral: CBPeripheral?
    /// Notify/indicate characteristics, in GATT order (services then characteristics).
    private var notifyOrIndicateCandidates: [CBCharacteristic] = []
    /// Raw bytes from notifications, appended in arrival order (for future audio decoding).
    private var receivedDataBuffer = Data()
    /// How many Int16 samples to decode from the newest end of the buffer for debug UI.
    private let recentPCMSampleWindowLength = 512

    override init() {
        super.init()
        print("[BLEManager] init called")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Connects to the peripheral with this id (from the scan list).
    func connect(to deviceID: UUID) {
        guard let peripheral = peripheralByID[deviceID] else {
            print("[BLEManager] connect(to:): no peripheral stored for \(deviceID)")
            connectionStatusText = "Connection: device not found"
            return
        }
        central.stopScan()
        connectionStatusText = "Connection: connecting…"
        central.connect(peripheral, options: nil)
    }

    /// Empties the in-memory receive buffer and resets the byte counter.
    func clearReceivedBuffer() {
        receivedDataBuffer.removeAll(keepingCapacity: true)
        totalReceivedByteCount = 0
        connectionStatusText = "Connection: receive buffer cleared (0 bytes)"
        print("[BLEManager] Receive buffer cleared")
    }

    /// Recent mono 16-bit little-endian PCM samples (tail of `receivedDataBuffer`). Oldest first, newest last.
    /// UI refreshes when `totalReceivedByteCount` updates after each packet.
    var recentPCMSamples: [Int16] {
        let data = receivedDataBuffer
        let pairCount = data.count / 2
        guard pairCount > 0 else { return [] }
        let sampleCount = min(pairCount, recentPCMSampleWindowLength)
        let startByte = data.count - sampleCount * 2
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let b = startByte + i * 2
            let u = UInt16(data[b]) | (UInt16(data[b + 1]) << 8)
            samples.append(Int16(bitPattern: u))
        }
        return samples
    }

    /// Writes the current receive buffer as mono 16-bit little-endian PCM in a WAV file (8000 Hz, DC offset removed, for LSMP debugging).
    func exportReceiveBufferAsWAV() -> WAVExportResult {
        let raw = receivedDataBuffer
        guard !raw.isEmpty else {
            return .failure("Buffer is empty—nothing to export")
        }

        let pcm = Self.removeDCOffset(from: raw)
        guard !pcm.isEmpty else {
            return .failure("No complete 16-bit samples to export")
        }

        // removeDCOffset only drops an incomplete final byte (odd raw length); sample count must be raw.count/2.
        let expectedPCMBytes = (raw.count / 2) * 2
#if DEBUG
        assert(pcm.count == expectedPCMBytes, "removeDCOffset byte count invariant: raw=\(raw.count) pcm=\(pcm.count) expected=\(expectedPCMBytes)")
#endif
        let droppedOddTail = raw.count - pcm.count
        print("[BLEManager] WAV DC check: raw=\(raw.count) B, pcm=\(pcm.count) B, samples=\(pcm.count / 2), oddTailDroppedBytes=\(droppedOddTail)")

        let header = Self.makeWAVHeader(pcmDataByteCount: pcm.count, sampleRate: 8000, channels: 1, bitsPerSample: 16)
        var fileData = Data()
        fileData.append(header)
        fileData.append(pcm)

        let fileName = "LungMonitor_ble_\(Int(Date().timeIntervalSince1970)).wav"
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return .failure("Could not find Documents folder")
        }
        let url = docs.appendingPathComponent(fileName)

        do {
            try fileData.write(to: url, options: .atomic)
            lastExportedWAVURL = url
            print("[BLEManager] WAV export succeeded: \(url.path) (\(fileData.count) bytes on disk)")
            return .success(url)
        } catch {
            print("[BLEManager] WAV export failed: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    func uploadWAVToServer(fileURL: URL) {
        guard let url = URL(string: "https://chemo-shrubbery-expert.ngrok-free.dev/analyze") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        let filename = fileURL.lastPathComponent
        guard let fileData = try? Data(contentsOf: fileURL) else {
            print("[UPLOAD] failed to read file")
            return
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[UPLOAD] error:", error.localizedDescription)
                DispatchQueue.main.async {
                    self.analysisResultText = "Upload failed"
                }
                return
            }

            guard let data = data else { return }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let filename = json["filename"] as? String ?? "-"
                    let size = (json["file_size_bytes"] as? NSNumber)?.intValue ?? json["file_size_bytes"] as? Int ?? 0
                    let wheeze =
                        (json["dummy_wheeze_count"] as? NSNumber)?.intValue ?? json["dummy_wheeze_count"] as? Int ?? 0

                    let text = "File: \(filename) | Size: \(size) bytes | Wheeze: \(wheeze)"

                    DispatchQueue.main.async {
                        self.analysisResultText = text
                    }
                } else {
                    DispatchQueue.main.async {
                        self.analysisResultText = "Parse error"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.analysisResultText = "Parse error"
                }
            }

            let res = String(data: data, encoding: .utf8) ?? ""
            print("[UPLOAD] response:", res)
        }.resume()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let text = Self.describe(state: central.state)
        print("[BLEManager] Bluetooth state: \(text)")
        bluetoothStateText = text

        switch central.state {
        case .poweredOn:
            peripheralByID.removeAll(keepingCapacity: true)
            nameByID.removeAll(keepingCapacity: true)
            discoveredDevices = []
            connectionStatusText = "Connection: not connected"
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        default:
            central.stopScan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let displayName = Self.displayName(for: peripheral, advertisementData: advertisementData)
        print("[BLEManager] Discovered device: \(displayName) (RSSI \(RSSI))")

        peripheralByID[peripheral.identifier] = peripheral
        nameByID[peripheral.identifier] = displayName
        let sortedIDs = peripheralByID.keys.sorted {
            let a = nameByID[$0] ?? ""
            let b = nameByID[$1] ?? ""
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        discoveredDevices = sortedIDs.map { ScannedDevice(id: $0, name: nameByID[$0] ?? "Unknown") }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLEManager] Connected to \(peripheral.identifier)")
        connectedPeripheral = peripheral
        notifyOrIndicateCandidates = []
        connectionStatusText = "Connection: discovering services…"
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        print("[BLEManager] Failed to connect: \(message)")
        connectedPeripheral = nil
        notifyOrIndicateCandidates = []
        connectionStatusText = "Connection: failed (\(message))"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error {
            print("[BLEManager] Disconnected with error: \(error.localizedDescription)")
        } else {
            print("[BLEManager] Disconnected")
        }
        peripheral.delegate = nil
        connectedPeripheral = nil
        notifyOrIndicateCandidates = []
        outstandingCharacteristicDiscoveries = 0
        connectionStatusText = "Connection: not connected"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            print("[BLEManager] Service discovery failed: \(error.localizedDescription)")
            connectionStatusText = "Connection: service discovery failed"
            return
        }
        guard let services = peripheral.services else {
            print("[BLEManager] Service discovery finished (no services)")
            connectionStatusText = "Connection: no services"
            return
        }
        for service in services {
            print("[BLEManager] Service UUID: \(service.uuid)")
        }

        outstandingCharacteristicDiscoveries = services.count
        totalCharacteristicsFound = 0
        characteristicsWithNotifyOrIndicate = 0
        notifyOrIndicateCandidates = []

        if services.isEmpty {
            connectionStatusText = "Connection: found 0 services—nothing to discover"
            return
        }

        connectionStatusText = "Connection: discovering characteristics…"
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        outstandingCharacteristicDiscoveries -= 1

        if let error {
            print("[BLEManager] Characteristic discovery failed for service \(service.uuid): \(error.localizedDescription)")
            finishCharacteristicDiscoveryIfComplete()
            return
        }

        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            totalCharacteristicsFound += 1
            let props = characteristic.properties
            let supportsRead = props.contains(.read)
            let supportsWrite = props.contains(.write) || props.contains(.writeWithoutResponse)
            let supportsNotify = props.contains(.notify)
            let supportsIndicate = props.contains(.indicate)
            if supportsNotify || supportsIndicate {
                characteristicsWithNotifyOrIndicate += 1
            }
            print(
                "[BLEManager] Characteristic — service UUID: \(service.uuid), characteristic UUID: \(characteristic.uuid), read: \(supportsRead), write: \(supportsWrite), notify: \(supportsNotify), indicate: \(supportsIndicate)"
            )
        }

        finishCharacteristicDiscoveryIfComplete()
    }

    /// Updates status once every service has reported characteristic discovery (or failed), then subscribes to the first notify/indicate characteristic.
    private func finishCharacteristicDiscoveryIfComplete() {
        guard outstandingCharacteristicDiscoveries == 0 else { return }
        connectionStatusText =
            "Connection: characteristic discovery finished (\(totalCharacteristicsFound) found, \(characteristicsWithNotifyOrIndicate) with notify/indicate—see console)"
        print(
            "[BLEManager] Tip: for streaming-style data (like audio), characteristics with notify or indicate are common—you subscribe and receive packets. Write / write-without-response can also carry binary data but are less typical for one-way streams."
        )

        guard let peripheral = connectedPeripheral else { return }
        notifyOrIndicateCandidates = Self.collectNotifyOrIndicateCandidates(from: peripheral)
        print("[BLEManager] Stored \(notifyOrIndicateCandidates.count) notify/indicate candidate(s)")

        guard let first = notifyOrIndicateCandidates.first else {
            connectionStatusText =
                "Connection: discovery done—no notify/indicate characteristic to subscribe to"
            return
        }

        connectionStatusText = "Connection: turning on notifications for \(first.uuid)…"
        print("[BLEManager] Subscribing (setNotifyValue true) to first candidate: \(first.uuid)")
        peripheral.setNotifyValue(true, for: first)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[BLEManager] Notification state error for \(characteristic.uuid): \(error.localizedDescription)")
            connectionStatusText = "Connection: could not enable notifications (\(error.localizedDescription))"
            return
        }
        print("[BLEManager] Notification state — characteristic UUID: \(characteristic.uuid), isNotifying: \(characteristic.isNotifying)")
        if characteristic.isNotifying {
            connectionStatusText = "Connection: notifications ON—waiting for packets on \(characteristic.uuid)"
        } else {
            connectionStatusText = "Connection: notifications OFF for \(characteristic.uuid)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[BLEManager] Incoming value error for \(characteristic.uuid): \(error.localizedDescription)")
            connectionStatusText = "Connection: data error on \(characteristic.uuid)"
            return
        }
        guard let data = characteristic.value else {
            print("[BLEManager] Incoming value — characteristic: \(characteristic.uuid), no data")
            connectionStatusText = "Connection: empty packet from \(characteristic.uuid)"
            return
        }
        let preview = Self.hexPreview(of: data, maxBytes: 16)
        print(
            "[BLEManager] Incoming data — characteristic UUID: \(characteristic.uuid), length: \(data.count) bytes, first bytes (hex): \(preview)"
        )
        receivedDataBuffer.append(data)
        totalReceivedByteCount = receivedDataBuffer.count
        connectionStatusText =
            "Connection: buffered \(totalReceivedByteCount) byte(s) total — last packet \(data.count) byte(s) on \(characteristic.uuid)"
    }

    /// Decodes mono 16-bit little-endian PCM (drops trailing odd byte), removes DC by subtracting the sample mean, re-encodes LE.
    private static func removeDCOffset(from pcm: Data) -> Data {
        let pairCount = pcm.count / 2
        guard pairCount > 0 else { return Data() }

        var samples: [Int16] = []
        samples.reserveCapacity(pairCount)
        for i in 0..<pairCount {
            let b = i * 2
            let u = UInt16(pcm[b]) | (UInt16(pcm[b + 1]) << 8)
            samples.append(Int16(bitPattern: u))
        }

        let sum = samples.reduce(Int64(0)) { $0 + Int64($1) }
        let mean = sum / Int64(samples.count)

        var out = Data()
        out.reserveCapacity(samples.count * 2)
        for s in samples {
            let centered = Int32(s) - Int32(mean)
            let clipped = Int16(clamping: centered)
            var le = clipped.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// Candidates in stable order: each service in discovery order, then each characteristic in that service.
    private static func collectNotifyOrIndicateCandidates(from peripheral: CBPeripheral) -> [CBCharacteristic] {
        var candidates: [CBCharacteristic] = []
        for service in peripheral.services ?? [] {
            for characteristic in service.characteristics ?? [] {
                let props = characteristic.properties
                if props.contains(.notify) || props.contains(.indicate) {
                    candidates.append(characteristic)
                }
            }
        }
        return candidates
    }

    /// Standard 44-byte PCM WAV header (little-endian). PCM samples follow immediately after.
    private static func makeWAVHeader(pcmDataByteCount: Int, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataChunkSize = UInt32(pcmDataByteCount)
        let riffChunkSize = 36 + dataChunkSize

        var h = Data()
        h.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        h.append(contentsOf: u32LE(riffChunkSize))
        h.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        h.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        h.append(contentsOf: u32LE(16)) // Subchunk1Size (PCM)
        h.append(contentsOf: u16LE(1)) // Audio format: PCM
        h.append(contentsOf: u16LE(channels))
        h.append(contentsOf: u32LE(sampleRate))
        h.append(contentsOf: u32LE(byteRate))
        h.append(contentsOf: u16LE(blockAlign))
        h.append(contentsOf: u16LE(bitsPerSample))
        h.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        h.append(contentsOf: u32LE(dataChunkSize))
        return h
    }

    private static func u16LE(_ value: UInt16) -> [UInt8] {
        let v = value.littleEndian
        return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
    }

    private static func u32LE(_ value: UInt32) -> [UInt8] {
        let v = value.littleEndian
        return [
            UInt8(truncatingIfNeeded: v),
            UInt8(truncatingIfNeeded: v >> 8),
            UInt8(truncatingIfNeeded: v >> 16),
            UInt8(truncatingIfNeeded: v >> 24),
        ]
    }

    /// First bytes as lowercase hex pairs (easy to read in the console).
    private static func hexPreview(of data: Data, maxBytes: Int) -> String {
        let n = min(maxBytes, data.count)
        guard n > 0 else { return "(none)" }
        return data.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func describe(state: CBManagerState) -> String {
        switch state {
        case .unknown: return "Bluetooth: unknown"
        case .resetting: return "Bluetooth: resetting"
        case .unsupported: return "Bluetooth: unsupported on this device"
        case .unauthorized: return "Bluetooth: permission not granted"
        case .poweredOff: return "Bluetooth: powered off"
        case .poweredOn: return "Bluetooth: powered on"
        @unknown default: return "Bluetooth: unexpected state"
        }
    }

    private static func displayName(for peripheral: CBPeripheral, advertisementData: [String: Any]) -> String {
        if let name = peripheral.name, !name.isEmpty {
            return name
        }
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !localName.isEmpty {
            return localName
        }
        let shortID = peripheral.identifier.uuidString.prefix(8)
        return "Unnamed device (\(shortID))"
    }
}
