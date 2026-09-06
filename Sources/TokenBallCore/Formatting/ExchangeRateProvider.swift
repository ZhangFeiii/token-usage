import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A USD→CNY rate together with provenance information for the dashboard.
public struct ExchangeRateResult: Equatable, Sendable {
    public let rate: Double
    /// Time at which the successful value was cached. Nil means the explicit
    /// first-run fallback is being used.
    public let updatedAt: Date?
    public let isFallback: Bool

    public var lastUpdatedAt: Date? { updatedAt }
    public var wasFallback: Bool { isFallback }

    public init(rate: Double, updatedAt: Date?, isFallback: Bool) {
        self.rate = rate
        self.updatedAt = updatedAt
        self.isFallback = isFallback
    }
}

public protocol ExchangeRateProviding: Sendable {
    func currentRate(now: Date) async -> ExchangeRateResult
}

public extension ExchangeRateProviding {
    func currentRate(now: Date = Date()) async -> ExchangeRateResult {
        await currentRate(now: now)
    }
}

public enum ECBExchangeRateParserError: Error, Equatable, Sendable {
    case malformedXML
    case missingCurrencyRates
    case invalidRate
}

/// Parses the ECB euro reference-rate XML and cross-calculates USD→CNY as
/// CNY-per-EUR divided by USD-per-EUR.
public enum ECBExchangeRateParser {
    public static func parse(data: Data) throws -> Double {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ECBExchangeRateParserError.malformedXML }
        guard let usd = delegate.rates["USD"], let cny = delegate.rates["CNY"] else {
            throw ECBExchangeRateParserError.missingCurrencyRates
        }
        let rate = cny / usd
        guard rate.isFinite, rate > 0 else { throw ECBExchangeRateParserError.invalidRate }
        return rate
    }

    public static func parse(xml: String) throws -> Double {
        try parse(data: Data(xml.utf8))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var rates: [String: Double] = [:]

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "Cube" || qName == "Cube",
                  let currency = attributeDict["currency"],
                  let rawRate = attributeDict["rate"],
                  let rate = Double(rawRate),
                  rate.isFinite,
                  rate > 0 else { return }
            rates[currency.uppercased()] = rate
        }
    }
}

/// Daily, cached ECB-backed USD→CNY provider. It performs at most one request
/// per local calendar day and remains usable when the network is unavailable.
public actor DailyUSDToCNYRateProvider: ExchangeRateProviding {
    public static let fallbackRate = 7.2
    public static let ecbURL = URL(
        string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
    )!

    public static var defaultCacheURL: URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return support
            .appendingPathComponent("TokenBall", isDirectory: true)
            .appendingPathComponent("exchange-rate-usd-cny.json", isDirectory: false)
    }

    private let cacheURL: URL
    private let endpointURL: URL
    private let dataLoader: @Sendable (URL) async throws -> Data
    private var cache: CacheEntry?

    public init(
        cacheURL: URL = DailyUSDToCNYRateProvider.defaultCacheURL,
        endpointURL: URL = DailyUSDToCNYRateProvider.ecbURL,
        dataLoader: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        self.cacheURL = cacheURL
        self.endpointURL = endpointURL
        self.dataLoader = dataLoader ?? { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    public func currentRate(now: Date = Date()) async -> ExchangeRateResult {
        let day = Self.dayKey(for: now)
        if cache == nil { cache = loadCache() }
        if let cache, cache.attemptedDay == day {
            return cache.result
        }

        do {
            let data = try await dataLoader(endpointURL)
            let rate = try ECBExchangeRateParser.parse(data: data)
            let entry = CacheEntry(
                rate: rate,
                updatedAt: now.timeIntervalSince1970,
                attemptedDay: day,
                isFallback: false
            )
            cache = entry
            saveCache(entry)
            return entry.result
        } catch {
            if let prior = cache {
                // Remember the failed attempt for this day but preserve the
                // last successful value and timestamp.
                let entry = CacheEntry(
                    rate: prior.rate,
                    updatedAt: prior.updatedAt,
                    attemptedDay: day,
                    isFallback: prior.isFallback
                )
                cache = entry
                saveCache(entry)
                return entry.result
            }
            let entry = CacheEntry(
                rate: Self.fallbackRate,
                updatedAt: nil,
                attemptedDay: day,
                isFallback: true
            )
            cache = entry
            saveCache(entry)
            return entry.result
        }
    }

    /// Convenience name for callers that want to make the currency direction
    /// explicit at the call site.
    public func usdToCNYRate(now: Date = Date()) async -> ExchangeRateResult {
        await currentRate(now: now)
    }

    private static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func loadCache() -> CacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              entry.rate.isFinite,
              entry.rate > 0 else { return nil }
        return entry
    }

    private func saveCache(_ entry: CacheEntry) {
        let directory = cacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // A read-only Application Support directory should not make the
            // dashboard unavailable; the in-memory cache still prevents
            // duplicate requests during this provider lifetime.
        }
    }
}

private struct CacheEntry: Codable, Sendable {
    let rate: Double
    let updatedAt: TimeInterval?
    let attemptedDay: String
    let isFallback: Bool

    var result: ExchangeRateResult {
        ExchangeRateResult(
            rate: rate,
            updatedAt: updatedAt.map(Date.init(timeIntervalSince1970:)),
            isFallback: isFallback
        )
    }
}

public typealias USDToCNYRateProvider = DailyUSDToCNYRateProvider
