import Foundation

/// Ports of the two rapidfuzz scorers the router uses, so shortlists match what the eval
/// fixtures were recorded against. Scores are 0...100.
public enum Fuzzy {
    /// rapidfuzz `fuzz.ratio`: normalized Indel similarity.
    public static func ratio(_ a: String, _ b: String) -> Double {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        let total = x.count + y.count
        if total == 0 { return 100 }
        return 100.0 * Double(2 * lcsLength(x, y)) / Double(total)
    }

    /// rapidfuzz `fuzz.token_set_ratio`.
    public static func tokenSetRatio(_ a: String, _ b: String) -> Double {
        let ta = Set(a.split(whereSeparator: \.isWhitespace).map(String.init))
        let tb = Set(b.split(whereSeparator: \.isWhitespace).map(String.init))
        if ta.isEmpty || tb.isEmpty { return 0 }
        let sect = ta.intersection(tb).sorted()
        let diffAB = ta.subtracting(tb).sorted()
        let diffBA = tb.subtracting(ta).sorted()
        if !sect.isEmpty && (diffAB.isEmpty || diffBA.isEmpty) { return 100 }
        let s = sect.joined(separator: " ")
        let ab = (sect + diffAB).joined(separator: " ")
        let ba = (sect + diffBA).joined(separator: " ")
        var best = ratio(ab, ba)
        if !sect.isEmpty { best = max(best, ratio(s, ab), ratio(s, ba)) }
        return best
    }

    private static func lcsLength(_ x: [Unicode.Scalar], _ y: [Unicode.Scalar]) -> Int {
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var cur = prev
        for i in 1...x.count {
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
