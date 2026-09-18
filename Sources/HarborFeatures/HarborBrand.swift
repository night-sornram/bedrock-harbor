import AppKit
import Foundation
import SwiftUI

public enum HarborBrand {
    public static let appName = "BedrockHarbor"

    public static func logoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "BedrockHarbor", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // Fallback when running from SPM debug binary outside the app bundle.
        let fallback = URL(fileURLWithPath: "/Applications/BedrockHarbor.app/Contents/Resources/BedrockHarbor.png")
        return NSImage(contentsOf: fallback)
    }
}

public struct HarborLogo: View {
    public var size: CGFloat
    public init(size: CGFloat = 72) { self.size = size }

    public var body: some View {
        Group {
            if let img = HarborBrand.logoImage() {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "light.beacon.max")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.cyan)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("BedrockHarbor logo")
    }
}

public struct HarborCover: View {
    public var height: CGFloat
    public init(height: CGFloat = 140) { self.height = height }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.cyan.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 16) {
                HarborLogo(size: height * 0.72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BedrockHarbor")
                        .font(.system(size: height * 0.18, weight: .bold))
                    Text("Minecraft launcher for macOS")
                        .font(.system(size: height * 0.09))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
