import AppKit
import Combine
import CoreText
import SwiftUI

/// 缝合像素字体（Resources/FusionPixel12px.ttf，OFL 许可）的运行时状态。
/// 由 Savings/Module.swift 的 SavingsRuntime.registerFontsOnce 经 CTFontManagerRegisterFontsForURL 注册一次；
/// 这里只按 PostScript 名探测是否可用，不依赖注册动作本身，Smoke 编译或注册失败时自然回退。
private enum FusionPixelFont {
    static let postScriptName = "Fusion-Pixel-12px-Mono-zh_hans-Regular"
    /// 一旦探测到已注册就缓存为 true（注册在 App 生命周期内不会撤销）；
    /// 未注册时每次重新探测，避免与启动注册时机产生顺序依赖。
    static var registered = false
}

extension Font {
    /// 像素字体封装：已注册则用 Fusion Pixel（12px 位图风格，适合标题/数值/徽章），
    /// 否则回退系统等宽字体，任何应用点都不需要自行处理字体缺失。
    static func pixel(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if !FusionPixelFont.registered {
            let names = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
            FusionPixelFont.registered = names.contains(FusionPixelFont.postScriptName)
        }
        let base = FusionPixelFont.registered
            ? Font.custom(FusionPixelFont.postScriptName, size: size)
            : Font.system(size: size, design: .monospaced)
        return base.weight(weight)
    }
}

enum SavingsAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: tS("跟随系统", "System")
        case .light: tS("浅色", "Light")
        case .dark: tS("深色", "Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class SavingsSettings: ObservableObject {
    private enum Keys {
        static let appearance = "savings.appearance"
        static let defaultCurrency = "savings.defaultCurrency"
        static let backgroundHex = "savings.backgroundHex"
    }

    private let defaults: UserDefaults

    @Published var appearance: SavingsAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var defaultCurrency: SavingsCurrency {
        didSet { defaults.set(defaultCurrency.rawValue, forKey: Keys.defaultCurrency) }
    }
    @Published var backgroundHex: String {
        didSet { defaults.set(backgroundHex, forKey: Keys.backgroundHex) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = SavingsAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "system") ?? .system
        defaultCurrency = SavingsCurrency(rawValue: defaults.string(forKey: Keys.defaultCurrency) ?? "CNY") ?? .CNY
        backgroundHex = defaults.string(forKey: Keys.backgroundHex) ?? ""
    }

    var backgroundPickerColor: Color {
        Color(savingsHex: backgroundHex) ?? Color(nsColor: .windowBackgroundColor)
    }

    func setBackgroundColor(_ color: Color) {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
        backgroundHex = String(
            format: "#%02X%02X%02X",
            Int(round(converted.redComponent * 255)),
            Int(round(converted.greenComponent * 255)),
            Int(round(converted.blueComponent * 255))
        )
    }

    func resetBackgroundColor() { backgroundHex = "" }

    func canvasColor(for scheme: ColorScheme) -> Color {
        let baseColor = SavingsTheme.canvas(for: scheme)
        guard let selected = NSColor(savingsHex: backgroundHex),
              let base = NSColor(baseColor).usingColorSpace(.sRGB) else { return baseColor }
        return Color(nsColor: base.blended(withFraction: 0.16, of: selected) ?? base)
    }
}

private extension NSColor {
    convenience init?(savingsHex: String) {
        let clean = savingsHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let value = Int(clean, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension Color {
    init?(savingsHex: String) {
        guard let color = NSColor(savingsHex: savingsHex) else { return nil }
        self.init(nsColor: color)
    }
}

enum SavingsTheme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let accent = dynamic(
        light: NSColor(srgbRed: 0.12, green: 0.34, blue: 0.28, alpha: 1),
        dark: NSColor(srgbRed: 0.35, green: 0.72, blue: 0.60, alpha: 1)
    )
    static let blue = Color(red: 0.22, green: 0.43, blue: 0.48)
    static let teal = Color(red: 0.15, green: 0.55, blue: 0.43)
    static let green = Color(red: 0.24, green: 0.57, blue: 0.35)
    static let orange = Color(red: 0.88, green: 0.48, blue: 0.22)
    static let purple = Color(red: 0.49, green: 0.40, blue: 0.67)
    static let red = Color(red: 0.79, green: 0.29, blue: 0.27)
    static let panel = dynamic(
        light: NSColor(srgbRed: 1.0, green: 0.995, blue: 0.975, alpha: 1),
        dark: NSColor(srgbRed: 0.105, green: 0.135, blue: 0.125, alpha: 1)
    )
    static let editorCanvas = dynamic(
        light: NSColor(srgbRed: 0.975, green: 0.968, blue: 0.942, alpha: 1),
        dark: NSColor(srgbRed: 0.065, green: 0.085, blue: 0.078, alpha: 1)
    )

    static func canvas(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.055, green: 0.074, blue: 0.067)
            : Color(red: 0.965, green: 0.953, blue: 0.917)
    }

    static func goalColor(_ key: String) -> Color {
        switch key {
        case "teal": teal
        case "green": green
        case "orange": orange
        case "purple": purple
        case "red": red
        default: blue
        }
    }
}

struct SavingsSectionHeader: View {
    let section: SavingsSection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SavingsTheme.accent)
                .frame(width: 36, height: 36)
                .background(SavingsTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title).font(.system(size: 20, weight: .bold, design: .rounded))
                Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

struct SavingsStatTile: View {
    let value: String
    let label: String
    let symbol: String
    var color: Color = SavingsTheme.accent

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .savingsPanel(cornerRadius: 16)
    }
}

struct PixelBadge: View {
    let symbol: String
    let text: String
    var tint: Color = .white

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.pixel(13, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.28)))
    }
}

extension View {
    func savingsPanel(cornerRadius: CGFloat = 16) -> some View {
        background(SavingsTheme.panel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.065)))
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}
