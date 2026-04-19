//
//  ContentView.swift
//  LungMonitor
//
//  Created by Kippei Toga on 4/18/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var bleManager = BLEManager()
    @State private var wavExportMessage = ""
    @State private var isShareSheetPresented = false

    private var pcmPreviewLine: String {
        let parts = bleManager.recentPCMSamples.suffix(16).map { String($0) }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GlassEffectContainer(spacing: 28) {
                        VStack(alignment: .leading, spacing: 16) {
                            statusSection
                            waveformSection
                            dataSection
                            actionsSection
                        }
                    }
                    devicesSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .animation(.easeOut(duration: 0.2), value: bleManager.totalReceivedByteCount)
            }
            .background {
                Color(.secondarySystemGroupedBackground)
                    .ignoresSafeArea()
            }
            .fontDesign(.monospaced)
            .navigationTitle("LungMonitor")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isShareSheetPresented) {
                if let url = bleManager.lastExportedWAVURL {
                    ActivityShareSheet(activityItems: [url])
                }
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                statusField(label: "Bluetooth", value: bleManager.bluetoothStateText)
                statusField(label: "Connection", value: bleManager.connectionStatusText)
            }
        }
    }

    private func statusField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private var waveformSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SimplePCMWaveformView(samples: bleManager.recentPCMSamples)
                    .frame(height: 140)
                    .padding(6)
            }
        }
    }

    private var dataSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total bytes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(bleManager.totalReceivedByteCount)")
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pcmPreviewLine)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var actionsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                if !wavExportMessage.isEmpty {
                    Text(wavExportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(bleManager.analysisResultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    glassActionButton(title: "Clear") {
                        bleManager.clearReceivedBuffer()
                    }
                    glassActionButton(title: "Export WAV") {
                        switch bleManager.exportReceiveBufferAsWAV() {
                        case .success(let url):
                            wavExportMessage = "WAV saved: \(url.lastPathComponent)"
                            bleManager.uploadWAVToServer(fileURL: url)
                        case .failure(let reason):
                            wavExportMessage = "WAV export failed: \(reason)"
                        }
                    }
                    glassActionButton(title: "Share", disabled: bleManager.lastExportedWAVURL == nil) {
                        isShareSheetPresented = true
                    }
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices")
                .font(.caption)
                .foregroundStyle(.secondary)

            if bleManager.discoveredDevices.isEmpty {
                Text("No devices found yet")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 16) {
                    ForEach(bleManager.discoveredDevices) { device in
                        Button {
                            bleManager.connect(to: device.id)
                        } label: {
                            HStack {
                                Text(device.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .contentShape(Rectangle())
                            .glassEffect(in: .rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func glassActionButton(title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

#Preview {
    ContentView()
}
