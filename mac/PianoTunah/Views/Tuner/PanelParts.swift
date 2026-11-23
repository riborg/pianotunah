import SwiftUI

/// The frame of the survey and tuning order panels: sunk, with an accent
/// border (style.css: .survey-panel).
struct PanelBox<Content: View>: View {
    let palette: Palette
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.sunk.color))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.accent.color, lineWidth: 1))
    }
}

/// How far a survey or the order has come (style.css: .survey-bar).
struct PanelBar: View {
    let fraction: Double
    let palette: Palette

    var body: some View {
        Capsule()
            .fill(palette.line.color)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule()
                        .fill(palette.accent.color)
                        .frame(width: g.size.width * max(0, min(1, fraction)))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A small label in a capsule: a survey reading or an interval to check
/// (style.css: .chk). `done` shows it green with a check mark; `main`
/// outlines it in the accent, for the interval a key is tuned by.
struct PanelChip: View {
    let text: String
    var done = false
    var main = false
    let palette: Palette

    var body: some View {
        let color = done ? palette.good : main ? palette.ink : palette.muted
        let border = done ? palette.good : main ? palette.accent : palette.line
        Text(verbatim: done ? "✓ " + text : text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(color.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.surface.color))
            .overlay(Capsule().strokeBorder(border.color, lineWidth: 1))
    }
}

/// Lays its views out in rows, starting a new row when the next one does
/// not fit (CSS flex-wrap). A view wider than the row gets the row's width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item {
        var index: Int
        var size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat?, _ subviews: Subviews) -> [Row] {
        let limit = width ?? .infinity
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if size.width > limit {
                size = view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                size.width = min(size.width, limit)
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty && x + size.width > limit {
                rows.append(row)
                row = Row()
            }
            let start = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append(Item(index: i, size: size))
            row.width = start + size.width
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
