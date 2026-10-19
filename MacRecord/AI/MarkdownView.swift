import AppKit
import SwiftUI

/// Renders Markdown (headings, lists, code blocks, quotes, tables, inline styles) as one selectable text flow.
/// Foundation parses the text and tags every run with its block (`PresentationIntent`); `MarkdownBlock.parse`
/// regroups those runs into blocks that `MarkdownBlock.attributedString` lays out.
struct MarkdownView: View {
    let text: String

    var body: some View {
        SelectableTextView(attributed: MarkdownBlock.attributedString(from: MarkdownBlock.parse(text)), plainText: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Plain (non-Markdown) selectable text, used for the user's own messages.
struct PlainMessageView: View {
    let text: String

    var body: some View {
        SelectableTextView(
            attributed: NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
            ]),
            plainText: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MarkdownBlock {
    static func attributedString(from blocks: [MarkdownBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)

        for (index, block) in blocks.enumerated() {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8
            var indent = CGFloat(block.indent) * 18 + (block.quoted ? 12 : 0)
            let piece = NSMutableAttributedString()

            switch block.kind {
            case .text(let text, let heading):
                if let marker = block.marker {
                    style.firstLineHeadIndent = indent
                    indent += 18
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    piece.append(NSAttributedString(string: marker + "\t", attributes: [.font: base, .foregroundColor: NSColor.labelColor]))
                }
                piece.append(inline(text, font: font(for: heading, base: base), color: block.quoted ? .secondaryLabelColor : .labelColor, mono: mono))
            case .code(let code, _):
                indent += 6
                style.firstLineHeadIndent = indent
                piece.append(NSAttributedString(string: code, attributes: [
                    .font: mono, .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.15),
                ]))
            case .rule:
                piece.append(NSAttributedString(string: "────────────", attributes: [.font: base, .foregroundColor: NSColor.tertiaryLabelColor]))
            case .table(let header, let rows):
                let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                func line(_ cells: [AttributedString], font: NSFont) -> NSAttributedString {
                    let line = NSMutableAttributedString()
                    for (i, cell) in cells.enumerated() {
                        if i > 0 { line.append(NSAttributedString(string: "  |  ", attributes: [.font: base, .foregroundColor: NSColor.tertiaryLabelColor])) }
                        line.append(inline(cell, font: font, color: .labelColor, mono: mono))
                    }
                    return line
                }
                piece.append(line(header, font: bold))
                for row in rows {
                    piece.append(NSAttributedString(string: "\n"))
                    piece.append(line(row, font: base))
                }
            }

            if block.marker == nil { style.firstLineHeadIndent = max(style.firstLineHeadIndent, indent) }
            style.headIndent = indent
            piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
            result.append(piece)
            if index < blocks.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    private static func font(for heading: Int?, base: NSFont) -> NSFont {
        switch heading {
        case 1: .boldSystemFont(ofSize: base.pointSize + 7)
        case 2: .boldSystemFont(ofSize: base.pointSize + 4)
        case 3: .boldSystemFont(ofSize: base.pointSize + 2)
        case .some: .boldSystemFont(ofSize: base.pointSize)
        case nil: base
        }
    }

    /// Bold, italic, inline code and links.
    private static func inline(_ text: AttributedString, font: NSFont, color: NSColor, mono: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in text.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                runFont = mono
                attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.18)
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                runFont = NSFont(descriptor: runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits)), size: runFont.pointSize) ?? runFont
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return out
    }
}

struct MarkdownBlock: Identifiable {
    enum Kind {
        case text(AttributedString, heading: Int?)
        case code(String, language: String?)
        case rule
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    let id: Int
    var kind: Kind
    var indent = 0          // list nesting depth, 0 = not in a list
    var marker: String?     // bullet or number, on the first block of a list item
    var quoted = false

    // MARK: Parsing

    static func parse(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: closingOpenFence(in: source), options: options) else {
            return [MarkdownBlock(id: 0, kind: .text(AttributedString(source), heading: nil))]
        }
        var builder = Builder()
        var key: Int?
        var components: [PresentationIntent.IntentType] = []
        var pending = AttributedString()
        for run in parsed.runs {
            let runComponents = run.presentationIntent?.components ?? []
            let runKey = runComponents.first?.identity ?? -1
            if runKey != key, key != nil {
                builder.add(pending, components: components)
                pending = AttributedString()
            }
            key = runKey
            components = runComponents
            pending += AttributedString(parsed[run.range])
        }
        if key != nil { builder.add(pending, components: components) }
        builder.finishTable()
        return builder.blocks
    }

    /// While streaming, a code fence may still be open; close it so the code shows as code right away.
    private static func closingOpenFence(in source: String) -> String {
        let fences = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        return fences % 2 == 1 ? source + "\n```" : source
    }

    private struct Builder {
        var blocks: [MarkdownBlock] = []
        private var seenItems = Set<Int>()
        private var table: (header: [Int: AttributedString], rows: [Int: [Int: AttributedString]], columns: Int)?
        private var tableRowOrder: [Int] = []

        mutating func add(_ text: AttributedString, components: [PresentationIntent.IntentType]) {
            guard let innermost = components.first else {
                finishTable()
                append(.text(styled(text), heading: nil))
                return
            }
            if case .tableCell(let column) = innermost.kind {
                addTableCell(styled(text), column: column, components: components)
                return
            }
            finishTable()

            var block: MarkdownBlock
            switch innermost.kind {
            case .codeBlock(let language):
                var code = String(text.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                block = MarkdownBlock(id: blocks.count, kind: .code(code, language: language))
            case .thematicBreak:
                block = MarkdownBlock(id: blocks.count, kind: .rule)
            case .header(let level):
                block = MarkdownBlock(id: blocks.count, kind: .text(styled(text), heading: level))
            default:
                block = MarkdownBlock(id: blocks.count, kind: .text(styled(text), heading: nil))
            }
            decorate(&block, components: components)
            blocks.append(block)
        }

        private mutating func append(_ kind: Kind) { blocks.append(MarkdownBlock(id: blocks.count, kind: kind)) }

        /// Indentation, list marker and quote bar come from the enclosing blocks.
        private mutating func decorate(_ block: inout MarkdownBlock, components: [PresentationIntent.IntentType]) {
            var lists = 0
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .orderedList, .unorderedList:
                    lists += 1
                case .blockQuote:
                    block.quoted = true
                case .listItem(let ordinal):
                    // Only the innermost item's first block gets a marker.
                    guard block.marker == nil, !seenItems.contains(component.identity) else { break }
                    seenItems.insert(component.identity)
                    var ordered = false
                    if index + 1 < components.count, case .orderedList = components[index + 1].kind { ordered = true }
                    block.marker = ordered ? "\(ordinal)." : "•"
                default:
                    break
                }
            }
            block.indent = max(lists - 1, 0)
        }

        private mutating func addTableCell(_ text: AttributedString, column: Int, components: [PresentationIntent.IntentType]) {
            var columns = 0
            var rowID = -1
            var isHeader = false
            for component in components {
                switch component.kind {
                case .table(let tableColumns): columns = tableColumns.count
                case .tableHeaderRow: isHeader = true; rowID = component.identity
                case .tableRow: rowID = component.identity
                default: break
                }
            }
            if table == nil { table = ([:], [:], columns); tableRowOrder = [] }
            if isHeader {
                table?.header[column] = text
            } else {
                if table?.rows[rowID] == nil { tableRowOrder.append(rowID) }
                table?.rows[rowID, default: [:]][column] = text
            }
        }

        mutating func finishTable() {
            guard let table else { return }
            self.table = nil
            let columns = max(table.columns, table.header.count)
            func row(_ cells: [Int: AttributedString]) -> [AttributedString] {
                (0..<columns).map { cells[$0] ?? AttributedString() }   // empty cells produce no run
            }
            append(.table(header: row(table.header), rows: tableRowOrder.map { row(table.rows[$0] ?? [:]) }))
            tableRowOrder = []
        }

        /// Monospaced font and a light background for `inline code`; bold, italic and links are handled by `Text`.
        private func styled(_ text: AttributedString) -> AttributedString {
            var text = text
            for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
                text[run.range].font = .system(.body, design: .monospaced)
                text[run.range].backgroundColor = Color.secondary.opacity(0.18)
            }
            return text
        }
    }
}
