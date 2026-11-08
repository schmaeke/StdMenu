import Foundation

/// A menu entry, parsed from a `label<TAB>value<TAB>icon` line.
struct Item: Sendable {
    let label: String
    let value: String
    let icon: String?
    /// The label folded for matching.
    fileprivate let key: [Unicode.Scalar]

    init?(line: String) {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard let label = fields.first, !label.isEmpty else { return nil }
        self.label = String(label)
        value = fields.count > 1 && !fields[1].isEmpty ? String(fields[1]) : self.label
        icon = fields.count > 2 && !fields[2].isEmpty ? String(fields[2]) : nil
        key = Array(fold(self.label).unicodeScalars)
    }

    /// Parses lines ending in `\n` or `\r\n`; other Unicode line separators belong to the line.
    static func parse(_ bytes: some BidirectionalCollection<UInt8>) -> [Item] {
        bytes.split(separator: 0x0A).compactMap { line in
            Item(line: String(decoding: line.last == 0x0D ? line.dropLast() : line, as: UTF8.self))
        }
    }

    /// The characters of the label that the query matches, for highlighting.
    func matches(_ query: Query) -> [Range<String.Index>] {
        guard !query.terms.isEmpty else { return [] }
        // Fold character by character to map matched positions back to the label.
        var key: [Unicode.Scalar] = []
        var origin: [String.Index] = []
        for index in label.indices {
            for scalar in fold(String(label[index])).unicodeScalars {
                key.append(scalar)
                origin.append(index)
            }
        }
        return query.terms.flatMap { term -> [Range<String.Index>] in
            guard let found = match(term, in: key) else { return [] }
            let positions = found.start.map { Array($0..<$0 + term.count) } ?? subsequence(term, in: key) ?? []
            return positions.map { origin[$0]..<label.index(after: origin[$0]) }
        }
    }
}

/// The typed text, folded and split into whitespace-separated terms.
struct Query {
    fileprivate let terms: [[Unicode.Scalar]]
    fileprivate let whole: [Unicode.Scalar]
    /// The text as typed, without surrounding whitespace.
    fileprivate let typed: String
    /// The terms typed with capitals, which favour labels with the same capitals.
    fileprivate let capitalized: [Substring]

    init(_ text: String) {
        let folded = fold(text)
        terms = folded.split(whereSeparator: \.isWhitespace).map { Array($0.unicodeScalars) }
        whole = Array(folded.trimmingCharacters(in: .whitespaces).unicodeScalars)
        typed = text.trimmingCharacters(in: .whitespaces)
        capitalized = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isUppercase) }
    }
}

/// Makes matching insensitive to case, diacritics and Unicode normalization.
private func fold(_ string: String) -> String {
    if string.utf8.allSatisfy({ $0 < 0x80 }) { return string.lowercased() }
    return string.precomposedStringWithCanonicalMapping
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

/// Returns the indices of the items matching every term of the query, best first.
///
/// As in dmenu, an item whose label is the query comes first, in the same case before any other; the
/// others are ordered by match quality. Among equals, a query with capitals favours labels with the
/// same capitals, and otherwise items keep their input order. The order depends only on the input and
/// the query, so the same keys always choose the same item.
func rank(_ items: [Item], by query: Query) -> [Int] {
    var matches: [(index: Int, score: Int, capitals: Int)] = []
    candidates: for (index, item) in items.enumerated() {
        var score = 0
        for term in query.terms {
            guard let found = match(term, in: item.key) else { continue candidates }
            score += found.quality
        }
        if !query.whole.isEmpty && item.key == query.whole { score = item.label == query.typed ? .max : .max - 1 }
        matches.append((index, score, query.capitalized.count { item.label.contains($0) }))
    }
    matches.sort { ($0.score, $0.capitals, $1.index) > ($1.score, $1.capitals, $0.index) }
    return matches.map(\.index)
}

/// How well a term matches, and where: 3 for a prefix of the label, 2 for a prefix of a word, 1 for a
/// substring, each with its start, and 0 for a subsequence, whose positions `subsequence` finds.
private func match(_ term: [Unicode.Scalar], in key: [Unicode.Scalar]) -> (quality: Int, start: Int?)? {
    var first: Int?
    for start in key.indices where key[start...].starts(with: term) {
        if start == 0 { return (3, 0) }
        let previous = key[start - 1].properties
        if !previous.isAlphabetic && previous.numericType == nil { return (2, start) }
        first = first ?? start
    }
    if let first { return (1, first) }
    return subsequence(term, in: key) == nil ? nil : (0, nil)
}

/// The positions of the term's scalars, each found after the previous one.
private func subsequence(_ term: [Unicode.Scalar], in key: [Unicode.Scalar]) -> [Int]? {
    var positions: [Int] = []
    var next = key.startIndex
    for scalar in term {
        guard let found = key[next...].firstIndex(of: scalar) else { return nil }
        positions.append(found)
        next = found + 1
    }
    return positions
}
