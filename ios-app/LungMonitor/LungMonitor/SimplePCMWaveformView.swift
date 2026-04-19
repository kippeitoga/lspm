//
//  SimplePCMWaveformView.swift
//  LungMonitor
//
//  Lightweight polyline of recent signed 16-bit PCM samples (debug only).
//

import SwiftUI

struct SimplePCMWaveformView: View {
    let samples: [Int16]

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if samples.count >= 2 {
                    SimplePCMWaveformShape(samples: samples)
                        .stroke(Color.accentColor, lineWidth: 1)
                } else {
                    Text("Waveform needs PCM data…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Connects each sample to the next; amplitude scaled to the largest |sample| in the window.
private struct SimplePCMWaveformShape: Shape {
    let samples: [Int16]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        guard samples.count >= 2, w > 0, h > 0 else { return path }

        let maxAbs = max(samples.map { abs(Int32($0)) }.max() ?? 1, 1)
        let scaleY = (h * 0.42) / CGFloat(maxAbs)
        let midY = h / 2
        let lastIndex = samples.count - 1

        for (i, s) in samples.enumerated() {
            let x = w * CGFloat(i) / CGFloat(lastIndex)
            let y = midY - CGFloat(Int32(s)) * scaleY
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
