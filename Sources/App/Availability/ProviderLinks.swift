/// TMDB provider ids (watch providers, region DE) of the services WatchSwifty has a search link for (`watchLink`).
extension StreamingService {
    init?(tmdbProviderID: Int) {
        switch tmdbProviderID {
        case 8, 1796: self = .netflix                  // Netflix, Netflix basic with Ads
        case 9, 10, 119: self = .primeVideo            // Amazon Prime Video, Amazon Video, Prime Video
        case 337: self = .disneyPlus
        case 350, 2: self = .appleTV                   // Apple TV+, Apple TV (store)
        case 30, 29: self = .wow                       // WOW, Sky Go
        case 531: self = .paramountPlus
        case 1899, 384: self = .hboMax                 // Max, HBO Max
        default: return nil
        }
    }
}
