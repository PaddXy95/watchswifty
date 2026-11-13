# Releases

WatchSwifty follows [SemVer](https://semver.org); changes are listed in the [CHANGELOG](../CHANGELOG.md). The running
version is shown on the left of the footer (after signing in) and at `http://<server>:8080/version`. To be told about new versions, see
[Update check](operations.md#update-check).

## Image tags

| Tag | Content |
|---|---|
| `latest` | newest release |
| `0.1.3` | exactly this version |
| `0.1` | newest 0.1.x version |
| `beta` | newest beta build (untested, only for a test instance) |
| `beta-abc1234` | beta build of exactly this commit |

For planned updates pin a version, for example `image: ghcr.io/paddxy95/watchswifty:0.1.3` (with the Compose file
from this repository: `WATCHSWIFTY_VERSION=0.1.3` in `.env`).

## How releases are built

GitHub Actions:

- Pull request: tests. A trial build of the image (nothing is uploaded) runs only when the pull request changes the
  Docker build: `Dockerfile`, `.dockerignore`, `scripts/docker-entrypoint.sh`, `Package.swift`, `Package.resolved`,
  `Public/api/` or the workflows.
- Push to `main`: tests and image build run in parallel; only if the tests pass, the image is pushed to GHCR and a
  GitHub release `vX.Y.Z` is created.
- Push to `beta`, or "Run workflow" (GitHub → Actions → CI/CD) on any branch: like `main`, but only the `beta` image
  is pushed and no release is created, see [Testing a beta](#testing-a-beta).

The dependencies are compiled in their own layer of the Docker build and kept in the GitHub Actions cache; as long as
`Package.swift` and `Package.resolved` do not change, a push only rebuilds the app itself.

**Version number:** `VERSION` holds the intended version (start: `0.1.0`). If there is no release for it yet, exactly
this version is published; every further push to `main` increases the last digit (`0.1.1`, `0.1.2`, …). For a new
minor or major version, change `VERSION`, for example to `0.2.0`. If the CHANGELOG has a section `## [X.Y.Z]`, it is
used as the release text; otherwise GitHub generates the list of changes.

On the very first release GitHub creates the package `watchswifty` as private. So that servers can pull it without
signing in, set its visibility to "Public" under GitHub → Packages → watchswifty → Package settings (or run
`docker login ghcr.io` with a token on the server). The update check also needs the repository to be public.

## Testing a beta

New features can be tried in a second instance before the release. A push to the `beta` branch builds
`ghcr.io/paddxy95/watchswifty:beta` (plus `beta-<commit>`) once the tests pass; any other branch can be built with
GitHub → Actions → CI/CD → "Run workflow". No release is created and `latest` stays unchanged. The beta shows its
version as, for example, `0.3.1-beta (abc1234)` and reports no updates.

Give the beta its own folder with this `docker-compose.yml` (plus an `.env` as for the normal instance). Do **not**
copy the normal `docker-compose.yml` with `WATCHSWIFTY_VERSION=beta`: container and volume names are fixed there, so
the beta would change your real data, and database changes of a beta cannot be undone.

```yaml
services:
  watchswifty-beta:
    image: ghcr.io/paddxy95/watchswifty:beta
    container_name: watchswifty-beta
    restart: unless-stopped
    ports:
      - "8081:8080"
    environment:
      TOKEN_KEY: ${TOKEN_KEY:?TOKEN_KEY is missing in .env (openssl rand -base64 32)}
      ADMIN_USERNAME: ${ADMIN_USERNAME:-admin}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:-}
      TZ: ${TZ:-Europe/Berlin}
      TMDB_LANGUAGE: ${TMDB_LANGUAGE:-de-DE}
      PUBLIC_ORIGIN: ${PUBLIC_ORIGIN:-}
    volumes:
      - watchswifty-beta-data:/data

volumes:
  watchswifty-beta-data:
    name: watchswifty-beta-data
```

Get the newest beta build with `docker compose pull && docker compose up -d` in the beta folder.

**Testing with a copy of the real data:** put the same `TOKEN_KEY` in the beta's `.env` as in the normal one,
otherwise TMDB tokens, e-mail addresses and mail settings cannot be decrypted. Then stop both containers and copy the
volume:

```bash
docker run --rm -v watchswifty-data:/from:ro -v watchswifty-beta-data:/to ubuntu:noble cp -a /from/. /to/
```

Start both again afterwards. The copy includes the mail settings, so the beta then sends real mails to the users (for
example about a newly connected device). If you don't want that, delete the mail settings in the beta under
**System**.

Browsers do not separate cookies by port: if both instances run under the same host name, signing in to the beta
signs you out of the normal instance. Reach the beta under a different name instead (its own subdomain, or the IP
address instead of the host name).
