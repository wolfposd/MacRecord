import SwiftUI

/// Renders Markdown (headings, lists, code blocks, quotes, tables, inline styles) with plain SwiftUI.
/// Foundation parses the text and tags every run with its block (`PresentationIntent`); `MarkdownBlock.parse`
/// regroups those runs into blocks that the view lays out.
struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        content
            .padding(.leading, CGFloat(block.indent) * 18)
            .overlay(alignment: .leading) {
                if block.quoted { Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3) }
            }
            .padding(.leading, block.quoted ? 10 : 0)
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .text(let text, let heading):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let marker = block.marker { Text(marker).frame(minWidth: 16, alignment: .trailing) }
                Text(text).font(Self.font(for: heading))
            }
        case .code(let code, let language):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language).font(.caption2).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { ForEach(header.indices, id: \.self) { Text(header[$0]).fontWeight(.semibold) } }
                    Divider().gridCellColumns(max(header.count, 1))
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow { ForEach(rows[row].indices, id: \.self) { Text(rows[row][$0]) } }
                    }
                }
            }
        }
    }

    private static func font(for heading: Int?) -> Font? {
        switch heading {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        case .some: .subheadline.bold()
        case nil: nil
        }
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
