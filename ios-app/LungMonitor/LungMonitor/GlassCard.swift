//
//  GlassCard.swift
//  LungMonitor
//
//  Uses SwiftUI Liquid Glass via `glassEffect(_:in:)` per Apple’s guidance:
//  https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
//

import SwiftUI

/// Content padded then wrapped in the system **Liquid Glass** material (not a manual blur + stroke).
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .glassEffect(in: .rect(cornerRadius: cornerRadius))
    }
}
