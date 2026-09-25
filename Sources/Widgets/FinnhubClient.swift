import Foundation

/// The user supplies their own key; it never enters UserDefaults or a URL.
enum FinnhubCredentials {
    static let service = "com.pmh10401.penguinnotch.finnhub"
    private static let cache = CredentialCache<String> { _ in false }

    static func load() -> String {
        (try? cache.value { KeychainItem.read(service: service, account: "api-key") ?? "" }) ?? ""
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let saved = KeychainItem.store(service: service, account: "api-key", value: value)
        if saved { cache.forget() }
        return saved
    }

    static func clear() {
        KeychainItem.delete(service: service, account: "api-key")
        cache.forget()
    }
}

enum FinnhubAPI {
    enum Failure: Error { case invalidResponse, http(Int) }

    static func quote(symbol: String, key: String, session: URLSession = .shared) async throws -> (StockTick, Decimal?) {
        var components = URLComponents(string: "https://finnhub.io/api/v1/quote")!
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "X-Finnhub-Token")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = (json["c"] as? NSNumber).flatMap({ Decimal(string: $0.stringValue) }), current > 0,
              let timestamp = (json["t"] as? NSNumber)?.doubleValue, timestamp > 0
        else { throw Failure.invalidResponse }
        let previous = (json["pc"] as? NSNumber).flatMap { Decimal(string: $0.stringValue) }
        return (StockTick(price: current, volume: nil, timestamp: Date(timeIntervalSince1970: timestamp),
                          currency: "USD"), previous.flatMap { $0 > 0 ? $0 : nil })
    }
}
