import CoreText
import SwiftUI

/// `text` with its ♭ ♮ ♯ drawn from Piano Tunah Accidentals, the font in
/// Fonts/ (tools/accidentals.py, as the web's), at `size`: the size of the
/// font around them. The system fonts have no ♭ or ♯ of their own, and the
/// fallback draws them thin and out of line with the letters. The rest of
/// the text keeps the view's font.
func noteText(_ text: String, size: CGFloat) -> AttributedString {
    guard accidentalsFont else { return AttributedString(text) }
    let font = Font.custom("PianoTunahAccidentals-Regular", fixedSize: size)
    var out = AttributedString()
    for character in text {
        var piece = AttributedString(String(character))
        if "♭♮♯".contains(character) { piece.font = font }
        out += piece
    }
    return out
}

/// Registers the bundled font for this process, the first time it is asked
/// for; false if it is missing, and then the system draws the accidentals.
private let accidentalsFont: Bool = {
    guard let url = Bundle.main.url(forResource: "Accidentals", withExtension: "ttf") else { return false }
    return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}()
