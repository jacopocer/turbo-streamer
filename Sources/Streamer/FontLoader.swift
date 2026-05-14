import CoreText
import Foundation

enum FontLoader {
    static func loadBundledFonts() {
        let fontsDir = Bundle.main.bundlePath + "/Contents/Resources/Fonts"
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: fontsDir),
            includingPropertiesForKeys: nil
        ) else { return }

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "otf" || ext == "ttf" else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
