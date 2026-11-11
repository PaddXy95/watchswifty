# Development

Requires Swift 6.3 or newer.

```bash
swift build
```

```bash
swift test
```

Run the server locally:

```bash
DATABASE_PATH=./dev.sqlite ADMIN_USERNAME=admin ADMIN_PASSWORD=adminpass123 swift run App serve
```

## Stack

Swift 6, Vapor 4, Fluent with SQLite, server-rendered HTML with Elementary and htmx (no JavaScript build step), and a
JSON App API generated from [`openapi.yaml`](../Sources/WatchSwiftyAPI/openapi.yaml) with swift-openapi-generator.
Tests use Swift Testing.

## Project layout

| Path | Content |
|---|---|
| `Sources/App` | The server: one folder per feature (`Auth`, `Account`, `Admin`, `Catalog`, `Tracking`, `Import`, `Mail`, `TMDB`, `Web`, `API`) |
| `Sources/WatchSwiftyAPI` | The OpenAPI description; server types are generated from it at build time |
| `Sources/WatchSwiftyClient` | Swift client library for apps, generated from the same description |
| `Tests` | Tests for the server and the client library |
| `scripts` | Release helpers (`next-version.sh`, `release-notes.sh`) |
| `docs/superpowers` | Design specs and implementation plans (German) |

[`CLAUDE.md`](../CLAUDE.md) describes the architecture, conventions and test helpers in more detail. The web UI is
German; code, comments and documentation are English.

## Releases

How versions, images and releases are built: [Releases](releases.md).
