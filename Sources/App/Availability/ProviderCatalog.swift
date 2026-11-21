import Foundation
import NIOConcurrencyHelpers
import Vapor

/// The countries and the services per country for Konto → Streamingdienste, kept in memory for a day so the account
/// page does not ask TMDB on every view (not stored in the database).
final class ProviderCatalog: Sendable {
    /// How long the cached lists are reused (one day).
    static let maxAge: TimeInterval = 86_400

    /// A cached value with the time it was fetched.
    private struct Entry<Value: Sendable>: Sendable { let value: Value; let at: Date }
    /// The cached country list and the service lists per country.
    private struct State: Sendable {
        var regions: Entry<[TMDBRegion]>?
        var providers: [String: Entry<[TMDBProviderInfo]>] = [:]
    }

    private let state = NIOLockedValueBox(State())

    /// Countries, by name.
    /// - Parameters:
    ///   - tmdb: The TMDB client used when the cache is empty or older than a day.
    ///   - now: The reference time for the cache age.
    /// - Returns: TMDB's watch provider countries, sorted by name with German collation.
    /// - Throws: `TMDBError` from the fetch.
    func regions(tmdb: any TMDBClient, now: Date = .now) async throws -> [TMDBRegion] {
        if let cached = state.withLockedValue({ $0.regions }), now.timeIntervalSince(cached.at) < Self.maxAge { return cached.value }
        let regions = try await tmdb.providerRegions()
            .sorted { $0.name.compare($1.name, locale: Locale(identifier: "de_DE")) == .orderedAscending }
        state.withLockedValue { $0.regions = Entry(value: regions, at: now) }
        return regions
    }

    /// Movie and series services of a country, each once, by TMDB's priority and name.
    /// - Parameters:
    ///   - region: The country code.
    ///   - tmdb: The TMDB client used when the cache is empty or older than a day.
    ///   - now: The reference time for the cache age.
    /// - Returns: The services, merged from the movie and the series list (keeping the better priority).
    /// - Throws: `TMDBError` from the fetch.
    func providers(region: String, tmdb: any TMDBClient, now: Date = .now) async throws -> [TMDBProviderInfo] {
        if let cached = state.withLockedValue({ $0.providers[region] }), now.timeIntervalSince(cached.at) < Self.maxAge {
            return cached.value
        }
        var byID: [Int: TMDBProviderInfo] = [:]
        for kind in [TitleKind.movie, .tv] {
            for provider in try await tmdb.providers(kind: kind, region: region) {
                if let known = byID[provider.providerID], known.displayPriority <= provider.displayPriority { continue }
                byID[provider.providerID] = provider
            }
        }
        let providers = byID.values.sorted { ($0.displayPriority, $0.name) < ($1.displayPriority, $1.name) }
        state.withLockedValue { $0.providers[region] = Entry(value: providers, at: now) }
        return providers
    }
}

extension Application {
    /// Storage key for the shared ``ProviderCatalog``.
    private struct ProviderCatalogKey: StorageKey { typealias Value = ProviderCatalog }

    /// The app-wide provider catalog; accessing it before `configure` set it is a fatal error.
    var providerCatalog: ProviderCatalog {
        get {
            guard let catalog = storage[ProviderCatalogKey.self] else { fatalError("Provider catalog not configured") }
            return catalog
        }
        set { storage[ProviderCatalogKey.self] = newValue }
    }
}
