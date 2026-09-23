import Foundation

/// KRX KIND's listed-company snapshot. Codes remain the stored identity;
/// names are only an input aid, so a rename never changes an existing watch.
struct KoreanStockDirectory {
    struct Company: Identifiable {
        let code: String
        let name: String
        let market: String
        var id: String { code }
    }

    static let shared: KoreanStockDirectory = {
        guard let url = Bundle.main.url(forResource: "krx-listed-companies", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return KoreanStockDirectory(text: "") }
        return KoreanStockDirectory(text: text)
    }()

    let companies: [Company]
    private let byName: [String: Company]
    private let byCode: [String: Company]

    init(text: String) {
        companies = text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, WatchedStock.parse("KR:\(fields[0])") != nil,
                  !fields[1].isEmpty else { return nil }
            return Company(code: String(fields[0]), name: String(fields[1]), market: String(fields[2]))
        }
        byName = Dictionary(companies.map { (Self.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        byCode = Dictionary(companies.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func name(for code: String) -> String? { byCode[code]?.name }

    func resolve(_ input: String) -> WatchedStock? {
        if let stock = WatchedStock.parse(input) { return stock }
        guard let company = byName[Self.key(input)] else { return nil }
        return WatchedStock(symbol: company.code, market: .kr)
    }

    func search(_ input: String, limit: Int = 8) -> [Company] {
        let query = Self.key(input)
        guard !query.isEmpty else { return [] }
        let matches = companies.filter { Self.key($0.name).contains(query) }
        return Array(matches.sorted {
            let left = Self.key($0.name).hasPrefix(query)
            let right = Self.key($1.name).hasPrefix(query)
            if left != right { return left }
            if $0.name.count != $1.name.count { return $0.name.count < $1.name.count }
            return $0.name < $1.name
        }.prefix(limit))
    }

    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}
