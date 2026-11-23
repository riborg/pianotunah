import Foundation
import SwiftUI

/// The help article (the web's Help tab) in a window of its own: help.en.md
/// or help.sv.md from the bundle, in the language the app's strings use.
///
/// The Markdown is the small subset the article needs: `## ` headings,
/// numbered items, and paragraphs, each with inline Markdown (bold,
/// italic). `Text` renders only the inline part, so the blocks are split
/// here.
struct HelpView: View {
    private let blocks = HelpArticle.load().blocks

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks.indices, id: \.self) { i in
                    block(blocks[i])
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func block(_ block: HelpArticle.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title2.bold())
                .padding(.top, 8)
        case .item(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(number).")
                    .monospacedDigit()
                    .frame(minWidth: 18, alignment: .trailing)
                Text(text)
            }
        case .paragraph(let text):
            Text(text)
        }
    }
}

/// The help article as blocks of inline Markdown.
struct HelpArticle {
    enum Block {
        case heading(AttributedString)
        case item(Int, AttributedString)
        case paragraph(AttributedString)
    }

    var blocks: [Block]

    /// The article for the app's language: the localization the bundle
    /// chose (as for the String Catalogs), so it matches the menus.
    static func load(bundle: Bundle = .main) -> HelpArticle {
        let language = bundle.preferredLocalizations.first.map { Locale.Language(identifier: $0) }
            ?? Locale.current.language
        let code = language.languageCode == .swedish ? "sv" : "en"
        guard let url = bundle.url(forResource: "help.\(code)", withExtension: "md")
                ?? bundle.url(forResource: "help.en", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return HelpArticle(blocks: []) }
        return HelpArticle(markdown: text)
    }

    init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// Splits at blank lines; a heading or a numbered item is one line.
    init(markdown: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(Self.inline(paragraph.joined(separator: " ")))) }
            paragraph = []
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(Self.inline(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))))
            } else if let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.item(n, Self.inline(String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        self.blocks = blocks
    }

    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
