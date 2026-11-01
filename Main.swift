import AppKit
import Combine
import CoreAudio
import Foundation
@preconcurrency import IOBluetooth
import SwiftUI

enum ListeningMode: String, CaseIterable, Identifiable {
    case cancellation = "Noise Cancellation"
    case transparency = "Transparency"
    case off = "Off"

    var id: String { rawValue }

    var protocolBit: UInt8 {
        switch self {
        case .off: 0x01       // Nord Buds 2 profile index 0
        case .cancellation: 0x02 // profile index 1
        case .transparency: 0x04 // profile index 2
        }
    }

    static func from(bit: UInt8) -> ListeningMode? {
        switch bit {
        case 0x01: .off
        case 0x02: .cancellation
        case 0x04: .transparency
        default: nil
        }
    }
}

enum EqualizerPreset: Int, CaseIterable, Identifiable {
    case balanced = 0
    case deepSeaBass = 1
    case brightAndCrisp = 2
    case pureVocals = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .balanced: "Balanced (Default)"
        case .deepSeaBass: "Deep Sea Bass"
        case .brightAndCrisp: "Bright & Crisp"
        case .pureVocals: "Pure Vocals"
        }
    }
}

private struct DeviceCustomEqualizer: Identifiable {
    let id: Int
    let name: String
    let selected: Bool
    let minimum: Int
    let maximum: Int
    let frequencies: [Int]
    let gains: [Int]
}

@MainActor
final class BudsController: NSObject, ObservableObject {
    @Published private(set) var connectionText = "Not connected"
    @Published private(set) var leftBattery: Int?
    @Published private(set) var rightBattery: Int?
    @Published private(set) var caseBattery: Int?
    @Published private(set) var mode: ListeningMode?
    @Published private(set) var equalizerIndex: Int?
    @Published private(set) var customEqualizerGains = Array(repeating: 0, count: 6)
    @Published private(set) var customEqualizerName: String?
    @Published private(set) var outputVolume: Double = 0.5
    @Published private(set) var outputVolumeAdjustable = false
    @Published private(set) var detailText = "Open the panel to connect"

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    // Arrays keep a zero-based index after removing a consumed prefix; Data can
    // retain a nonzero startIndex, which previously made the parser treat an
    // absolute index as a byte count and crash on later Bluetooth packets.
    private var input: [UInt8] = []
    private var sequence: UInt8 = 0x50
    private var connecting = false
    private var refreshTimer: Timer?
    private var modeWriteID = 0
    private var equalizerWriteID = 0
    private var equalizerResponseID = 0
    private var customEqualizers: [DeviceCustomEqualizer] = []
    private var applyingCustomEqualizer = false
    private var pendingCustomPresetID: Int?
    private var pendingCustomPresetGains: [Int]?
    private var pendingCustomPresetSelected = false
    private var customEqWriteID = 0
    private let customEqPresetName = "Mac Custom EQ"
    private let customEqualizerFrequencies = [62, 250, 1000, 4000, 8000, 16000]
    private var outputVolumeAddresses: [AudioObjectPropertyAddress] = []

    var isConnected: Bool { channel?.isOpen() == true }
    var menuTitle: String {
        if let leftBattery, let rightBattery {
            return leftBattery == rightBattery ? "🎧 \(leftBattery)%" : "🎧 \(leftBattery)·\(rightBattery)"
        }
        return "🎧"
    }

    func connectAndRefresh() {
        refreshOutputVolume()
        if isConnected {
            requestStatus()
            return
        }
        guard !connecting else { return }
        connecting = true
        connectionText = "Connecting…"
        detailText = "Opening the Nord Buds 2 control channel"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            guard let target = paired.first(where: {
                ($0.nameOrAddress as String).localizedCaseInsensitiveContains("OnePlus Nord Buds 2")
            }) else {
                Task { @MainActor in
                    self?.connecting = false
                    self?.connectionText = "Not paired"
                    self?.detailText = "Pair the earbuds in System Settings → Bluetooth"
                }
                return
            }

            var opened: IOBluetoothRFCOMMChannel?
            let result = target.openRFCOMMChannelSync(&opened, withChannelID: 15, delegate: self)
            Task { @MainActor in
                self?.connecting = false
                guard result == kIOReturnSuccess, let opened else {
                    self?.connectionText = "Disconnected"
                    self?.detailText = "Could not open RFCOMM channel (\(result))"
                    return
                }
                self?.device = target
                self?.channel = opened
                self?.connectionText = "Connected"
                self?.detailText = "Nord Buds 2 control channel ready"
                // The reference app starts each RFCOMM session with 0x0100.
                // Without this handshake, battery and mode reads may work while
                // the earbuds ignore state-changing commands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isConnected else { return }
                    _ = self.send(command: 0x0100, payload: [])
                }
                self?.requestStatus(after: 0.8)
                self?.startRefreshTimer()
            }
        }
    }

    func disconnect() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        _ = channel?.close()
        channel = nil
        device = nil
        connectionText = "Not connected"
        detailText = "Control channel closed"
    }

    func setMode(_ newMode: ListeningMode) {
        guard isConnected else {
            connectAndRefresh()
            detailText = "Connect first, then choose a listening mode"
            return
        }
        detailText = "Sending \(newMode.rawValue)…"
        guard send(
            command: 0x0404,
            payload: [0x01, 0x01, newMode.protocolBit],
            fixedSequence: 0xF0
        ) == kIOReturnSuccess else {
            if isConnected { detailText = "Could not send the mode command over Bluetooth" }
            return
        }
        modeWriteID += 1
        let writeID = modeWriteID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.modeWriteID == writeID else { return }
            self.requestMode()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.modeWriteID == writeID else { return }
            if self.mode == newMode {
                self.detailText = "Mode changed to \(newMode.rawValue)"
            } else if let actualMode = self.mode {
                self.detailText = "Earbuds still report \(actualMode.rawValue)"
            } else {
                self.detailText = "No mode confirmation received from the earbuds"
            }
        }
    }

    func setEqualizer(_ preset: EqualizerPreset) {
        guard isConnected else {
            connectAndRefresh()
            detailText = "Connect first, then choose an equalizer preset"
            return
        }
        detailText = "Sending \(preset.title)…"
        guard send(command: 0x0406, payload: [UInt8(preset.rawValue)]) == kIOReturnSuccess else {
            if isConnected { detailText = "Could not send the equalizer command over Bluetooth" }
            return
        }

        equalizerWriteID += 1
        let writeID = equalizerWriteID
        let responseID = equalizerResponseID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.equalizerWriteID == writeID else { return }
            self.requestEqualizer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.equalizerWriteID == writeID else { return }
            guard self.equalizerResponseID != responseID else {
                self.detailText = "No equalizer confirmation received from the earbuds"
                return
            }
            if self.equalizerIndex == preset.rawValue {
                self.detailText = "Equalizer changed to \(preset.title)"
            } else if let index = self.equalizerIndex, let actual = EqualizerPreset(rawValue: index) {
                self.detailText = "Earbuds still report \(actual.title)"
            } else {
                self.detailText = "Earbuds reported an unknown equalizer preset (\(self.equalizerIndex ?? -1))"
            }
        }
    }

    func updateCustomEqualizerGain(at index: Int, to gain: Int) {
        guard customEqualizerGains.indices.contains(index) else { return }
        var gains = customEqualizerGains
        gains[index] = min(max(gain, -6), 6)
        customEqualizerGains = gains
    }

    func saveCustomEqualizer() {
        guard isConnected else {
            detailText = "Connect first to save a custom equalizer"
            return
        }
        let existing = customEqualizers.first(where: { $0.name == customEqPresetName })
        guard existing != nil || customEqualizers.count < 2 else {
            detailText = "Both custom EQ slots are used; remove one preset to save this curve"
            return
        }

        let nameBytes = Array(customEqPresetName.utf8)
        let presetID = existing?.id ?? 0
        let action: UInt8 = existing == nil ? 0x01 : 0x02
        var payload: [UInt8] = [action, 0xFA, 0x06, UInt8(presetID & 0xFF), UInt8(nameBytes.count)]
        payload.append(contentsOf: nameBytes)
        payload.append(UInt8(customEqualizerFrequencies.count))
        for (frequency, gain) in zip(customEqualizerFrequencies, customEqualizerGains) {
            payload.append(UInt8(frequency & 0xFF))
            payload.append(UInt8((frequency >> 8) & 0xFF))
            payload.append(UInt8(bitPattern: Int8(gain)))
        }

        guard send(command: 0x0418, payload: payload) == kIOReturnSuccess else {
            if isConnected { detailText = "Could not send the custom EQ over Bluetooth" }
            return
        }
        applyingCustomEqualizer = true
        customEqWriteID += 1
        let writeID = customEqWriteID
        pendingCustomPresetGains = customEqualizerGains
        pendingCustomPresetID = nil
        pendingCustomPresetSelected = false
        detailText = "Saving custom equalizer…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.customEqWriteID == writeID else { return }
            self.requestCustomEqualizers()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.customEqWriteID == writeID,
                  self.applyingCustomEqualizer || self.pendingCustomPresetID != nil else { return }
            self.applyingCustomEqualizer = false
            self.pendingCustomPresetID = nil
            self.pendingCustomPresetGains = nil
            self.pendingCustomPresetSelected = false
            self.detailText = "No confirmation from the earbuds; custom EQ may not be supported by this firmware"
        }
    }

    func setOutputVolume(_ value: Double) {
        guard outputVolumeAdjustable,
              !outputVolumeAddresses.isEmpty,
              let device = defaultOutputDevice() else { return }
        let level = min(max(value, 0), 1)
        var scalar = Float(level)
        var allSet = true
        for storedAddress in outputVolumeAddresses {
            var address = storedAddress
            let result = AudioObjectSetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float>.size),
                &scalar
            )
            if result != noErr { allSet = false }
        }
        if allSet { outputVolume = level }
    }

    private func refreshOutputVolume() {
        outputVolumeAddresses = []
        outputVolumeAdjustable = false
        guard let device = defaultOutputDevice() else { return }

        // Prefer a settable master control. Some outputs expose only separate
        // left and right scalar controls, so use both channels as a fallback.
        let masterAddress = volumeAddress(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
        if let value = readableSettableVolume(device, address: masterAddress) {
            outputVolumeAddresses = [masterAddress]
            outputVolumeAdjustable = true
            outputVolume = value
            return
        }

        var channelValues: [Double] = []
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            let address = volumeAddress(kAudioDevicePropertyVolumeScalar, element: element)
            if let value = readableSettableVolume(device, address: address) {
                outputVolumeAddresses.append(address)
                channelValues.append(value)
            }
        }
        if !channelValues.isEmpty {
            outputVolumeAdjustable = true
            outputVolume = channelValues.reduce(0, +) / Double(channelValues.count)
        }
    }

    private func readableSettableVolume(
        _ device: AudioDeviceID,
        address originalAddress: AudioObjectPropertyAddress
    ) -> Double? {
        var address = originalAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return nil }
        var scalar: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr else { return nil }
        return min(max(Double(scalar), 0), 1)
    }

    private func volumeAddress(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        return result == noErr && device != kAudioObjectUnknown ? device : nil
    }

    func requestStatus(after delay: TimeInterval = 0.1) {
        guard isConnected else { connectAndRefresh(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isConnected else { return }
            self.send(command: 0x0106, payload: [])
            self.requestMode(after: 0.15)
            self.requestEqualizer(after: 0.3)
            self.requestCustomEqualizers(after: 0.5)
        }
    }

    private func requestMode(after delay: TimeInterval = 0.1) {
        guard isConnected else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.send(command: 0x010C, payload: [0x01, 0x01])
        }
    }

    private func requestEqualizer(after delay: TimeInterval = 0.1) {
        guard isConnected else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.send(command: 0x010F, payload: [])
        }
    }

    private func requestCustomEqualizers(after delay: TimeInterval = 0.1) {
        guard isConnected else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.send(command: 0x0122, payload: [0x01, 0x05])
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestStatus() }
        }
    }

    @discardableResult
    private func send(command: UInt16, payload: [UInt8], fixedSequence: UInt8? = nil) -> IOReturn? {
        guard let channel, channel.isOpen() else { return nil }
        if fixedSequence == nil { sequence = sequence >= 0xFE ? 0x01 : sequence + 1 }
        let packetSequence = fixedSequence ?? sequence
        let length = 7 + payload.count
        var packet: [UInt8] = [
            0xAA, UInt8(length), 0x00, 0x00,
            UInt8(command & 0xFF), UInt8((command >> 8) & 0xFF), packetSequence,
            UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF),
        ]
        packet.append(contentsOf: payload)
        var data = Data(packet)
        let result = data.withUnsafeMutableBytes { bytes -> IOReturn in
            guard let base = bytes.baseAddress else { return kIOReturnBadArgument }
            return channel.writeSync(base, length: UInt16(packet.count))
        }
        if result != kIOReturnSuccess {
            detailText = "Bluetooth write failed (\(result))"
        }
        return result
    }

    private func receive(_ bytes: [UInt8]) {
        input.append(contentsOf: bytes)
        while true {
            guard let start = input.firstIndex(of: 0xAA) else { input.removeAll(); return }
            if start > 0 { input.removeFirst(start) }
            guard input.count >= 2 else { return }

            var declared = 0
            var lengthBytes = 0
            var completeLength = false
            while lengthBytes < 2 {
                guard input.count > 1 + lengthBytes else { return }
                let value = Int(input[1 + lengthBytes])
                lengthBytes += 1
                declared |= (value & 0x7F) << (7 * (lengthBytes - 1))
                if value & 0x80 == 0 { completeLength = true; break }
            }
            guard completeLength else { input.removeFirst(); continue }
            let frameLength = 1 + lengthBytes + declared
            guard frameLength >= 9, input.count >= frameLength else { return }
            let frame = Array(input.prefix(frameLength))
            input.removeFirst(frameLength)
            handle(frame)
        }
    }

    private func handle(_ frame: [UInt8]) {
        guard frame.count >= 9, frame[0] == 0xAA else { return }
        let command = UInt16(frame[4]) | (UInt16(frame[5]) << 8)
        let payloadLength = Int(frame[7]) | (Int(frame[8]) << 8)
        guard frame.count >= 9 + payloadLength else { return }
        let payload = Array(frame[9..<(9 + payloadLength)])

        if command == 0x8106 || command == 0x0204 {
            parseBattery(payload)
        }
        if command == 0x810C || command == 0x0204 {
            parseMode(payload)
        }
        if command == 0x810F || command == 0x0504 {
            parseEqualizer(payload)
        }
        if command == 0x8122 {
            parseCustomEqualizers(payload)
        }
    }

    private func parseBattery(_ payload: [UInt8]) {
        guard payload.count >= 2 else { return }
        let count = Int(payload[1])
        guard count >= 2, count <= 3, payload.count >= 2 + count * 2 else { return }
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        for index in 0..<count {
            let id = payload[2 + index * 2]
            let raw = Int(payload[3 + index * 2]) & 0x7F
            guard raw <= 100 else { continue }
            switch id {
            case 0x01: left = raw
            case 0x02: right = raw
            case 0x03: caseLevel = raw
            default: break
            }
        }
        if let left { leftBattery = left }
        if let right { rightBattery = right }
        if let caseLevel { caseBattery = caseLevel }
        detailText = "Battery updated"
    }

    private func parseMode(_ payload: [UInt8]) {
        guard payload.count >= 3 else { return }
        for index in 0..<(payload.count - 2) where payload[index] == 0x01 && payload[index + 1] == 0x01 {
            if let value = ListeningMode.from(bit: payload[index + 2]) {
                mode = value
                detailText = "Mode: \(value.rawValue)"
                return
            }
        }
    }

    private func parseEqualizer(_ payload: [UInt8]) {
        guard payload.count >= 2, payload[0] == 0 else { return }
        equalizerIndex = Int(payload[1])
        equalizerResponseID += 1
        if let expectedID = pendingCustomPresetID {
            if equalizerIndex == expectedID {
                pendingCustomPresetSelected = true
                detailText = "Custom preset selected; checking stored band values…"
            } else {
                pendingCustomPresetSelected = false
                detailText = "Earbuds report EQ preset \(equalizerIndex ?? -1); custom EQ was not selected"
            }
            return
        }
        if let selected = customEqualizers.first(where: { $0.id == equalizerIndex && $0.selected }) {
            customEqualizerName = selected.name
        } else {
            customEqualizerName = nil
        }
    }

    private func parseCustomEqualizers(_ payload: [UInt8]) {
        guard payload.count >= 2, payload[0] == 0 else { return }
        let count = Int(payload[1])
        var offset = 2
        var presets: [DeviceCustomEqualizer] = []
        for _ in 0..<count {
            guard offset + 5 <= payload.count else { return }
            let selected = payload[offset] != 0
            let minimum = Int(Int8(bitPattern: payload[offset + 1]))
            let maximum = Int(Int8(bitPattern: payload[offset + 2]))
            let id = Int(payload[offset + 3])
            let nameLength = Int(payload[offset + 4])
            offset += 5
            guard offset + nameLength < payload.count else { return }
            let name = String(decoding: payload[offset..<(offset + nameLength)], as: UTF8.self)
            offset += nameLength
            let bandCount = Int(payload[offset])
            offset += 1
            guard bandCount <= 32, offset + bandCount * 3 <= payload.count else { return }
            var frequencies: [Int] = []
            var gains: [Int] = []
            for _ in 0..<bandCount {
                frequencies.append(Int(payload[offset]) | (Int(payload[offset + 1]) << 8))
                gains.append(Int(Int8(bitPattern: payload[offset + 2])))
                offset += 3
            }
            presets.append(DeviceCustomEqualizer(
                id: id,
                name: name,
                selected: selected,
                minimum: minimum,
                maximum: maximum,
                frequencies: frequencies,
                gains: gains
            ))
        }

        customEqualizers = presets
        let active = presets.first(where: { $0.selected }) ?? presets.first(where: { $0.name == customEqPresetName })
        if let active {
            customEqualizerGains = customEqualizerFrequencies.indices.map { index in
                let gain = active.gains.indices.contains(index) ? active.gains[index] : 0
                return min(max(gain, -6), 6)
            }
            if active.selected { customEqualizerName = active.name }
        }

        if let expectedID = pendingCustomPresetID,
           let actual = presets.first(where: { $0.id == expectedID }),
           let expectedGains = pendingCustomPresetGains {
            let gainsMatch = actual.gains == expectedGains
            let frequenciesMatch = actual.frequencies == customEqualizerFrequencies
            let isSelected = actual.selected || pendingCustomPresetSelected
            if isSelected && gainsMatch && frequenciesMatch {
                customEqualizerName = actual.name
                applyingCustomEqualizer = false
                pendingCustomPresetID = nil
                pendingCustomPresetGains = nil
                pendingCustomPresetSelected = false
                detailText = "Custom EQ selected; all six band values confirmed"
            } else if !gainsMatch || !frequenciesMatch {
                applyingCustomEqualizer = false
                pendingCustomPresetID = nil
                pendingCustomPresetGains = nil
                pendingCustomPresetSelected = false
                detailText = "Earbuds returned a different custom EQ curve; slider values were not fully saved"
            }
            return
        }

        guard applyingCustomEqualizer,
              let saved = presets.first(where: { $0.name == customEqPresetName }) else { return }
        customEqualizerName = saved.name
        customEqualizerGains = customEqualizerFrequencies.indices.map { index in
            let gain = saved.gains.indices.contains(index) ? saved.gains[index] : 0
            return min(max(gain, -6), 6)
        }
        applyingCustomEqualizer = false
        detailText = "Applying custom equalizer…"
        guard send(command: 0x0406, payload: [UInt8(saved.id & 0xFF)]) == kIOReturnSuccess else {
            applyingCustomEqualizer = false
            detailText = "Saved custom EQ, but could not send the activation command"
            return
        }
        pendingCustomPresetID = saved.id
        pendingCustomPresetGains = customEqualizerGains
        pendingCustomPresetSelected = false
        requestEqualizer(after: 0.5)
        requestCustomEqualizers(after: 0.8)
    }

    @objc func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        Task { @MainActor in self.receive(bytes) }
    }

    @objc func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        Task { @MainActor in
            self.channel = nil
            self.device = nil
            self.connectionText = "Disconnected"
            self.detailText = "Bluetooth control channel closed"
        }
    }

    @objc func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        if status != kIOReturnSuccess {
            Task { @MainActor in
                self.connectionText = "Disconnected"
                self.detailText = "RFCOMM open failed (\(status))"
            }
        }
    }
}

@main
struct NordBudsMacControlApp: App {
    @StateObject private var controller = BudsController()

    var body: some Scene {
        MenuBarExtra {
            BudsPopover(controller: controller)
                .frame(width: 310)
                .padding(16)
                .onAppear { controller.connectAndRefresh() }
        } label: {
            Text(controller.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct BudsPopover: View {
    @ObservedObject var controller: BudsController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "earbuds")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OnePlus Nord Buds 2").font(.headline)
                    Text(controller.connectionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { controller.requestStatus() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh status")
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Volume").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int((controller.outputVolume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { controller.outputVolume },
                            set: { controller.setOutputVolume($0) }
                        ),
                        in: 0...1
                    )
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!controller.outputVolumeAdjustable)
                if !controller.outputVolumeAdjustable {
                    Text("Volume control isn’t available for the current audio output.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Battery").font(.subheadline.weight(.semibold))
                HStack(spacing: 0) {
                    batteryColumn("Left", value: controller.leftBattery, icon: "earbuds")
                    Spacer()
                    batteryColumn("Right", value: controller.rightBattery, icon: "earbuds")
                    Spacer()
                    batteryColumn("Case", value: controller.caseBattery, icon: "battery.100")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Noise Control").font(.subheadline.weight(.semibold))
                ForEach(ListeningMode.allCases) { mode in
                    Button {
                        controller.setMode(mode)
                    } label: {
                        HStack {
                            Image(systemName: modeIcon(mode))
                                .frame(width: 18)
                            Text(mode.rawValue)
                            Spacer()
                            if controller.mode == mode {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .disabled(!controller.isConnected)
                }
            }

            Divider()

            HStack {
                Text("Equalizer").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(EqualizerPreset.allCases) { preset in
                        Button {
                            controller.setEqualizer(preset)
                        } label: {
                            if controller.equalizerIndex == preset.rawValue {
                                Label(preset.title, systemImage: "checkmark")
                            } else {
                                Text(preset.title)
                            }
                        }
                        .disabled(!controller.isConnected)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(controller.equalizerIndex.flatMap(EqualizerPreset.init(rawValue:))?.title ?? "Choose preset")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(!controller.isConnected)
            }

            DisclosureGroup("Custom EQ") {
                Text("Adjust the six bands from −6 to +6 dB. Each slider saves to the earbuds when released.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(Array(["62 Hz", "250 Hz", "1 kHz", "4 kHz", "8 kHz", "16 kHz"].enumerated()), id: \.offset) { index, label in
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { Double(controller.customEqualizerGains[index]) },
                                set: { controller.updateCustomEqualizerGain(at: index, to: Int($0.rounded())) }
                            ),
                            in: -6...6,
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing { controller.saveCustomEqualizer() }
                            }
                        )
                        Text("\(controller.customEqualizerGains[index]) dB")
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                if let name = controller.customEqualizerName {
                    Text("Editing: \(name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!controller.isConnected)

            Text(controller.detailText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            HStack {
                Button("Bluetooth Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                Spacer()
                Button("Disconnect") { controller.disconnect() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(!controller.isConnected)
            }
        }
    }

    private func batteryColumn(_ title: String, value: Int?, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary)
            Text(value.map { "\($0)%" } ?? "—")
                .font(.system(.body, design: .rounded).weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 58)
    }

    private func modeIcon(_ mode: ListeningMode) -> String {
        switch mode {
        case .cancellation: "waveform"
        case .transparency: "ear.and.waveform"
        case .off: "speaker.wave.2"
        }
    }
}
