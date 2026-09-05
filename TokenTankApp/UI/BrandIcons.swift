import AppKit
import SwiftUI
import TokenTankDomain

/// Bundled brand marks from [theSVG](https://thesvg.org) `@thesvg/icons@3.3.2`.
/// Codex uses OpenAI, Claude uses Claude, Grok uses Grok, Cursor uses Cursor, Doubao uses Doubao.
/// Marks remain the trademarks of their owners; bundled only for identification.
enum BrandIcon {
    static func resourceName(for providerID: ProviderID, color: Bool) -> String {
        let base: String
        switch providerID {
        case .codex: base = "codex"
        case .claude: base = "claude"
        case .grok: base = "grok"
        case .cursor: base = "cursor"
        case .doubao: base = "doubao"
        }
        if color, hasColorVariant(providerID) {
            return "\(base)-color"
        }
        return base
    }

    static func hasColorVariant(_ providerID: ProviderID) -> Bool {
        switch providerID {
        case .claude, .doubao: true
        case .codex, .grok, .cursor: false
        }
    }

    /// Brand-identifying fill used on popup cards. Status still uses its own badge colors.
    static func tint(for providerID: ProviderID) -> Color {
        switch providerID {
        case .codex:
            Color(red: 16 / 255, green: 163 / 255, blue: 127 / 255)
        case .claude:
            Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        case .grok:
            Color(red: 82 / 255, green: 82 / 255, blue: 91 / 255)
        case .cursor:
            Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
        case .doubao:
            Color(red: 30 / 255, green: 55 / 255, blue: 252 / 255)
        }
    }

    static func image(
        for providerID: ProviderID,
        pointSize: CGFloat,
        color: Bool = false,
        template: Bool? = nil
    ) -> NSImage? {
        let name = resourceName(for: providerID, color: color)
        let url = bundle.url(forResource: name, withExtension: "svg", subdirectory: "BrandIcons")
            ?? bundle.url(forResource: name, withExtension: "svg")
        guard let url else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = template ?? !color
        return image
    }

    static var bundle: Bundle { Bundle(for: AppModel.self) }
}

struct ProviderBrandIcon: View {
    let providerID: ProviderID
    var pointSize: CGFloat = 16
    var color: Bool = false

    var body: some View {
        if let image = BrandIcon.image(
            for: providerID,
            pointSize: pointSize,
            color: color,
            template: !color
        ) {
            Image(nsImage: image)
                .renderingMode(color ? .original : .template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: pointSize, height: pointSize)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle.fill")
                .font(.system(size: pointSize * 0.72, weight: .semibold))
                .frame(width: pointSize, height: pointSize)
                .accessibilityHidden(true)
        }
    }
}

struct MenuBarSummaryItem: Equatable, Sendable {
    let providerID: ProviderID
    let text: String
}

enum MenuBarSummaryRenderer {
    @MainActor
    static func image(for model: AppModel) -> NSImage? {
        let items = model.menuBarSummaryItems()
        guard !items.isEmpty else { return nil }
        return compose(summaryItems: items)
    }

    static func compose(items: [(ProviderID, String)]) -> NSImage? {
        compose(
            summaryItems: items.map { item in
                MenuBarSummaryItem(providerID: item.0, text: item.1)
            }
        )
    }

    static func compose(summaryItems items: [MenuBarSummaryItem]) -> NSImage? {
        let iconSide: CGFloat = 13
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let iconTextGap: CGFloat = 3
        let itemGap: CGFloat = 8
        let height: CGFloat = 16

        var segments: [(NSImage, NSAttributedString, CGSize)] = []
        var totalWidth: CGFloat = 0
        for (index, item) in items.enumerated() {
            guard let icon = BrandIcon.image(
                for: item.providerID,
                pointSize: iconSide,
                color: false,
                template: true
            ) else {
                return nil
            }
            let text = NSAttributedString(string: item.text, attributes: textAttributes)
            let textSize = text.size()
            let width = iconSide + iconTextGap + ceil(textSize.width)
            segments.append((icon, text, NSSize(width: width, height: height)))
            totalWidth += width
            if index + 1 < items.count {
                totalWidth += itemGap
            }
        }
        guard totalWidth > 0 else { return nil }

        let canvasSize = NSSize(width: totalWidth, height: height)
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            var x: CGFloat = 0
            for (index, segment) in segments.enumerated() {
                let iconRect = NSRect(
                    x: x,
                    y: (height - iconSide) / 2,
                    width: iconSide,
                    height: iconSide
                )
                segment.0.draw(
                    in: iconRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
                let textSize = segment.1.size()
                segment.1.draw(
                    at: NSPoint(
                        x: x + iconSide + iconTextGap,
                        y: (height - textSize.height) / 2
                    )
                )
                x += segment.2.width
                if index + 1 < segments.count {
                    x += itemGap
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
