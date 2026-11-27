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
| `scripts` | Release helpers (`next-version.sh`, `release-notes.sh`), upgrade fixture generators (`upgrade-fixtures/`) |
| `docs/superpowers` | Design specs and implementation plans (German) |

[`CLAUDE.md`](../CLAUDE.md) describes the architecture, conventions and test helpers in more detail. The web UI is
German; code, comments and documentation are English.

## Upgrade tests

`UpgradeTests` open databases that released versions wrote (`Tests/AppTests/Fixtures/upgrade/<tag>.sqlite`), run
today's migrations on them and check that the data survives and the web UI and the App API work on it. Each fixture is
written by the code of its own release, so it holds exactly what that version stored:

```bash
scripts/upgrade-fixtures/generate.sh v0.1.0
```

The script checks the tag out into a temporary worktree, runs `scripts/upgrade-fixtures/<tag>.swift` there as a test
and stores the database. The fixtures use a fixed `TOKEN_KEY` (`UpgradeTests.fixtureTokenKey`) so encrypted values can
be read back.

Migrations of a released version must never change: an existing database has already run them and skips them, so a
change only reaches new installations. Fix data with a new migration at the end of the list in `configure.swift`.

## Releases

How versions, images and releases are built: [Releases](releases.md).
