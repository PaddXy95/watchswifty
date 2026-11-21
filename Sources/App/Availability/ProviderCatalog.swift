import Foundation
import NIOConcurrencyHelpers
import Vapor

/// The countries and the services per country for Konto → Streamingdienste, kept in memory for a day so the account
/// page does not ask TMDB on every view (not stored in the database).
final class ProviderCatalog: Sendable {
    static let maxAge: TimeInterval = 86_400

    private struct Entry<Value: Sendable>: Sendable { let value: Value; let at: Date }
    private struct State: Sendable {
        var regions: Entry<[TMDBRegion]>?
        var providers: [String: Entry<[TMDBProviderInfo]>] = [:]
    }

    private let state = NIOLockedValueBox(State())

    /// Countries, by name.
    func regions(tmdb: any TMDBClient, now: Date = .now) async throws -> [TMDBRegion] {
        if let cached = state.withLockedValue({ $0.regions }), now.timeIntervalSince(cached.at) < Self.maxAge { return cached.value }
        let regions = try await tmdb.providerRegions()
            .sorted { $0.name.compare($1.name, locale: Locale(identifier: "de_DE")) == .orderedAscending }
        state.withLockedValue { $0.regions = Entry(value: regions, at: now) }
        return regions
    }

    /// Movie and series services of a country, each once, by TMDB's priority and name.
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
    private struct ProviderCatalogKey: StorageKey { typealias Value = ProviderCatalog }

    var providerCatalog: ProviderCatalog {
        get {
            guard let catalog = storage[ProviderCatalogKey.self] else { fatalError("Provider catalog not configured") }
            return catalog
        }
        set { storage[ProviderCatalogKey.self] = newValue }
    }
}
