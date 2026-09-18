import AppKit

enum EditorFont {
    static func monospaced(named name: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard !name.isEmpty, let font = NSFont(name: name, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        guard weight == .regular else {
            return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        return font
    }
}
