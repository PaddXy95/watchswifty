<img src="Public/favicon.svg" width="96" height="96" alt="WatchSwifty icon">

# WatchSwifty

[![CI/CD](https://github.com/PaddXy95/watchswifty/actions/workflows/docker.yml/badge.svg?branch=main)](https://github.com/PaddXy95/watchswifty/actions/workflows/docker.yml)
[![Release](https://img.shields.io/github/v/release/PaddXy95/watchswifty?sort=semver)](https://github.com/PaddXy95/watchswifty/releases)
![Swift](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)
![Vapor](https://img.shields.io/badge/Vapor-4-0D0D0D?logo=vapor&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue)

A self-hosted tracker for series and movies. Mark episodes and movies as watched, rate and comment on them, import
your Netflix history and always see the next episode to watch, for yourself or a small group of people. One Docker
container, one SQLite file, data from TMDB. The web UI is in German; apps such as
[WatchSwifty for iOS](https://github.com/PaddXy95/watchswifty-ios) use its JSON API.

## Features

- **Continue watching:** one card per series with the next episode (series of the last 3 months)
- **Netflix import:** upload your viewing history as CSV, titles are matched to TMDB automatically
- **Tracking by hand:** search series and movies, mark episodes as watched (with date and streaming service), rate
  them 1–10, private comments on series, seasons and movies
- **History and library** with synopsis, genres (library filter) and links to TMDB, IMDb, Rotten Tomatoes and SeriesGraph
- **Statistics:** movies, series, episodes and time watched, in total, per year and month, by rating, service and genre;
  longest and most watched series, movies and episodes
- **Several users** with separate data; the admin creates accounts or invites people by mail
- **Single sign-on (optional)** through your own OpenID Connect provider
- **Mail (optional)** for invitations, password resets and new devices, for example through
  [SwiftyRelay](https://github.com/PaddXy95/SwiftyRelay)
- **Notifications (optional)** about new episodes of followed series, by mail or through a
  [KNot](https://github.com/nexus421/KNot) webhook, once a day at a time the admin chooses
- **App API** (`/api/v1`, OpenAPI) with device tokens and a Swift client library
- Secrets such as TMDB tokens and mail settings are encrypted at rest

## Quick start

Requires Docker with Compose. Every user needs a free [TMDB token](docs/tmdb.md).

Copy `docker-compose.yml` and `.env.example` from this repository into a folder on your server and rename
`.env.example` to `.env`. Fill in `TOKEN_KEY` (output of the first command, keep it somewhere safe) and
`ADMIN_PASSWORD`, then start:

```bash
openssl rand -base64 32
```

```bash
chmod 600 .env
```

```bash
docker compose up -d
```

Open `http://<server>:8080`, sign in as the admin and paste your TMDB token under **Konto** (account). For HTTPS, put a
reverse proxy in front, see [Installation](docs/installation.md#reverse-proxy-https).

## Documentation

- [Installation](docs/installation.md): Docker Compose, `docker run`, data directory, reverse proxy, own image
- [Configuration](docs/configuration.md): environment variables and the encryption key
- [Operations](docs/operations.md): updates, update check, backup and restore, command line
- [Accounts](docs/accounts.md): users, invitations, forgotten passwords
- [TMDB](docs/tmdb.md): getting a token, cached data
- [Single sign-on](docs/sso.md): OIDC setup, moving an existing installation, emergency access
- [Mail](docs/email.md): SMTP setup, SwiftyRelay
- [Notifications](docs/notifications.md): new episodes by mail or KNot webhook, daily run time
- [Import](docs/import.md): Netflix viewing history and your own film list
- [App API](docs/app-api.md): connecting apps, tokens, Swift client
- [Releases](docs/releases.md): versions, image tags, testing a beta
- [Development](docs/development.md): build, tests, project layout
- [Changelog](CHANGELOG.md) · Privacy policy of the iOS app: [English](docs/privacy-ios-app.md),
  [Deutsch](docs/datenschutz-ios-app.md)

## TMDB

Movie and series data come from [TMDB](https://www.themoviedb.org). This product uses the TMDB API but is not endorsed
or certified by TMDB. Cached data is refreshed after 60 days at the latest and deleted when nobody uses it any more,
see [TMDB](docs/tmdb.md#cached-data).

## Written with AI

WatchSwifty is written with AI. Code, tests and documentation were created with Claude by Anthropic and fully
reviewed by me.

## License

[MIT](LICENSE), Copyright (c) 2026 PaddXy95.
