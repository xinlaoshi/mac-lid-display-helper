import AppKit

func makeLinkSymbol() -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
    let laptop = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    let display = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    let image = NSImage(size: NSSize(width: 32, height: 18), flipped: false) { _ in
        for (symbol, box) in [(laptop, NSRect(x: 0, y: 1, width: 15, height: 12)), (display, NSRect(x: 14, y: 0, width: 18, height: 18))] {
            guard let symbol else { continue }
            let scale = min(box.width / symbol.size.width, box.height / symbol.size.height)
            let width = symbol.size.width * scale, height = symbol.size.height * scale
            symbol.draw(in: NSRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height))
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "开盖的 Mac 与外接显示器"
    return image
}
