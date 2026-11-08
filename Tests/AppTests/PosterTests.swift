@testable import App
import Elementary
import Testing

@Suite("Poster")
struct PosterTests {
    @Test func cardPosterUsesSmallImagesAndAsyncDecoding() {
        let html = Poster(path: "/x.jpg", alt: "X").render()
        #expect(html.contains(#"src="https://image.tmdb.org/t/p/w92/x.jpg""#))
        #expect(html.contains(#"srcset="https://image.tmdb.org/t/p/w92/x.jpg 1x, https://image.tmdb.org/t/p/w185/x.jpg 2x""#))
        #expect(html.contains(#"loading="lazy""#))
        #expect(html.contains(#"decoding="async""#))
        #expect(html.contains(#"width="92""#))
        #expect(html.contains(#"height="138""#))
    }

    @Test func largerPostersPickLargerSizes() {
        #expect(Poster(path: "/x.jpg", alt: "X", displayWidth: 140).render().contains("w154/x.jpg 1x, https://image.tmdb.org/t/p/w342/x.jpg 2x"))
        #expect(Poster(path: "/x.jpg", alt: "X", displayWidth: 200).render().contains("w342/x.jpg 1x, https://image.tmdb.org/t/p/w500/x.jpg 2x"))
        #expect(Poster(path: "/x.jpg", alt: "X", displayWidth: 40).render().contains("w92/x.jpg 1x, https://image.tmdb.org/t/p/w92/x.jpg 2x"))
    }

    @Test func placeholderWithoutPath() {
        let html = Poster(path: nil, alt: "Breaking Bad").render()
        #expect(html.contains("poster-placeholder"))
        #expect(html.contains("BB"))
    }
}
