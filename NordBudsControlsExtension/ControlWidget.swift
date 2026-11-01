import AppIntents
import Foundation
import WidgetKit
import SwiftUI
@preconcurrency import IOBluetooth

enum NordListeningMode: String, AppEnum, CaseIterable {
    case noiseCancellation
    case transparency
    case off

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Nord Buds 2 mode"
    static var caseDisplayRepresentations: [NordListeningMode: DisplayRepresentation] = [
        .noiseCancellation: "Noise Cancellation",
        .transparency: "Transparency",
        .off: "Off",
    ]

    var protocolBit: UInt8 {
        switch self {
        case .off: 0x01
        case .noiseCancellation: 0x02
        case .transparency: 0x04
        }
    }

    var label: String {
        switch self {
        case .noiseCancellation: "Noise Cancellation"
        case .transparency: "Transparency"
        case .off: "Noise Control Off"
        }
    }

    var symbol: String {
        switch self {
        case .noiseCancellation: "waveform"
        case .transparency: "ear.and.waveform"
        case .off: "speaker.wave.2"
        }
    }
}

struct SetNordBudsModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Nord Buds 2 Noise Control"
    static var description = IntentDescription("Changes the listening mode on OnePlus Nord Buds 2.")
    static var openAppWhenRun = false

    @Parameter(title: "Mode")
    var mode: NordListeningMode

    init() { mode = .noiseCancellation }
    init(mode: NordListeningMode) { self.mode = mode }

    func perform() async throws -> some IntentResult {
        let selectedMode = mode
        try await Task.detached(priority: .userInitiated) {
            try NordBudsBluetooth.setMode(selectedMode)
        }.value
        return .result()
    }
}

private enum NordBudsBluetooth {
    static func setMode(_ mode: NordListeningMode) throws {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        guard let device = paired.first(where: {
            ($0.nameOrAddress as String).localizedCaseInsensitiveContains("OnePlus Nord Buds 2")
        }) else {
            throw ControlError("Pair OnePlus Nord Buds 2 with this Mac first.")
        }

        var channel: IOBluetoothRFCOMMChannel?
        let openResult = device.openRFCOMMChannelSync(&channel, withChannelID: 15, delegate: nil)
        guard openResult == kIOReturnSuccess, let channel else {
            throw ControlError("Could not open the Nord Buds 2 control channel (\(openResult)).")
        }
        defer { _ = channel.close() }

        // Opening RFCOMM can complete before the earbuds are ready to accept their first write.
        Thread.sleep(forTimeInterval: 0.8)
        let packet: [UInt8] = [
            0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x51,
            0x03, 0x00, 0x01, 0x01, mode.protocolBit,
        ]
        var data = Data(packet)
        let writeResult = data.withUnsafeMutableBytes { bytes -> IOReturn in
            guard let base = bytes.baseAddress else { return kIOReturnBadArgument }
            return channel.writeSync(base, length: UInt16(packet.count))
        }
        guard writeResult == kIOReturnSuccess else {
            throw ControlError("Bluetooth write failed (\(writeResult)).")
        }
    }
}

private struct ControlError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct NordNoiseCancellationControl: ControlWidget {
    static let kind = "local.codex.nordbuds-controls.anc"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SetNordBudsModeIntent(mode: .noiseCancellation)) {
                Label("Nord Buds ANC", systemImage: "waveform")
            }
        }
        .displayName("Nord Buds 2: Noise Cancellation")
        .description("Turn on Noise Cancellation.")
    }
}

struct NordTransparencyControl: ControlWidget {
    static let kind = "local.codex.nordbuds-controls.transparency"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SetNordBudsModeIntent(mode: .transparency)) {
                Label("Nord Buds Transparency", systemImage: "ear.and.waveform")
            }
        }
        .displayName("Nord Buds 2: Transparency")
        .description("Turn on Transparency mode.")
    }
}

struct NordNoiseOffControl: ControlWidget {
    static let kind = "local.codex.nordbuds-controls.off"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SetNordBudsModeIntent(mode: .off)) {
                Label("Nord Buds Noise Control Off", systemImage: "speaker.wave.2")
            }
        }
        .displayName("Nord Buds 2: Noise Control Off")
        .description("Turn off noise control.")
    }
}

@main
struct NordBudsControlWidgets: WidgetBundle {
    var body: some Widget {
        NordNoiseCancellationControl()
        NordTransparencyControl()
        NordNoiseOffControl()
    }
}
