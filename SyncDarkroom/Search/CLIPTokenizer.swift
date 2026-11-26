import Foundation

/// OpenAI CLIP byte-pair-encoding tokenizer (the one MobileCLIP's text encoder expects).
/// The vocabulary is rebuilt from the merges list exactly like CLIP's `SimpleTokenizer`.
final class CLIPTokenizer: Sendable {
    static let startToken: Int32 = 49406
    static let endToken: Int32 = 49407
    static let contextLength = 77

    private let encoder: [String: Int32]
    private let ranks: [String: Int]
    private let byteEncoder: [UInt8: Character]
    private let pattern: NSRegularExpression

    init?(mergesURL: URL) {
        guard let text = try? String(contentsOf: mergesURL, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if lines.first?.hasPrefix("#version") == true { lines.removeFirst() }
        let merges = lines.prefix(49152 - 256 - 2).map { $0.split(separator: " ").map(String.init) }
            .filter { $0.count == 2 }

        // bytes_to_unicode: printable bytes map to themselves, the rest to 256+n.
        var bs = Array(UInt8(ascii: "!")...UInt8(ascii: "~")) + Array(UInt8(0xA1)...UInt8(0xAC)) + Array(UInt8(0xAE)...UInt8(0xFF))
        var cs = bs.map { UInt32($0) }
        var n: UInt32 = 0
        for b in 0...255 where !bs.contains(UInt8(b)) {
            bs.append(UInt8(b))
            cs.append(256 + n)
            n += 1
        }
        var byteEncoder: [UInt8: Character] = [:]
        var vocab: [String] = []
        for (b, c) in zip(bs, cs) {
            let ch = Character(UnicodeScalar(c)!)
            byteEncoder[b] = ch
            vocab.append(String(ch))
        }
        vocab += vocab.map { $0 + "</w>" }
        vocab += merges.map { $0[0] + $0[1] }
        vocab += ["<|startoftext|>", "<|endoftext|>"]

        var encoder: [String: Int32] = [:]
        for (i, token) in vocab.enumerated() { encoder[token] = Int32(i) }
        var ranks: [String: Int] = [:]
        for (i, m) in merges.enumerated() { ranks[m[0] + " " + m[1]] = i }

        self.encoder = encoder
        self.ranks = ranks
        self.byteEncoder = byteEncoder
        // swiftlint:disable:next force_try
        pattern = try! NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive])
    }

    /// Token ids padded with zeros to 77, starting with <|startoftext|> and ending with <|endoftext|>.
    func encode(_ text: String) -> [Int32] {
        let cleaned = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        var ids: [Int32] = []
        let ns = cleaned as NSString
        for match in pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            let mapped = String(word.utf8.compactMap { byteEncoder[$0] })
            for piece in bpe(mapped) {
                if let id = encoder[piece] { ids.append(id) }
            }
        }
        var tokens = [Self.startToken] + ids.prefix(Self.contextLength - 2) + [Self.endToken]
        tokens += Array(repeating: 0, count: Self.contextLength - tokens.count)
        return tokens
    }

    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks[word[i] + " " + word[i + 1]], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let best else { break }
            let first = word[best.index], second = word[best.index + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        return word
    }
}
