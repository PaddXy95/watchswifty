# Operations

## Updating

With Compose, in the folder with `docker-compose.yml`:

```bash
docker compose pull && docker compose up -d
```

With `docker run`:

```bash
docker pull ghcr.io/paddxy95/watchswifty:latest
```

```bash
docker rm -f watchswifty
```

Then run the `docker run` command from [Installation](installation.md#docker-run) again; the volume is kept. Database
changes of new versions are applied automatically on start. A backup before updating does no harm.

## Update check

As an admin, turn on „Automatisch alle 12 Stunden prüfen“ (check automatically every 12 hours) under **System**, or
click „Jetzt prüfen“ (check now). WatchSwifty then asks the GitHub API (`api.github.com`) for the latest release.
GitHub sees the server's IP address; no data from WatchSwifty is sent. The check is off by default.

If there is a newer version, the footer shows admins „Update auf vX.Y.Z verfügbar“ (update available) and the
**System** page shows the commands to update. The running version is shown on the left of the footer and at
`http://<server>:8080/version`.

## Backup and restore

All data lives in one SQLite file in the volume (`/data/watchswifty.sqlite`). The secrets in it are encrypted (see
[Encryption key](configuration.md#encryption-key)); history, ratings and comments are not, so keep backups protected.
Without `TOKEN_KEY` the key lies in the volume as `/data/token.key`; back it up as well if needed, otherwise the
secrets have to be entered again after a restore.

Backup (stop the container briefly so the file is consistent):

```bash
docker compose stop watchswifty
```

```bash
docker run --rm -v watchswifty-data:/data -v "$PWD":/backup ubuntu:noble \
  cp /data/watchswifty.sqlite /backup/watchswifty-$(date +%F).sqlite
```

```bash
docker compose start watchswifty
```

Restore: stop the container, copy the backup back to `/data/watchswifty.sqlite` (the same `docker run … cp` command
with the paths swapped), start the container.

## Command line

The container runs these commands through `docker-entrypoint.sh`, so the database keeps belonging to the app user:

```bash
docker exec -it watchswifty /app/docker-entrypoint.sh reset-password <username>
```

```bash
docker exec -it watchswifty /app/docker-entrypoint.sh link-oidc <username>
```

```bash
docker exec -it watchswifty /app/docker-entrypoint.sh oidc-move-issuer <old> <new>
```

- `reset-password` sets a new password, see [Accounts](accounts.md#forgot-password).
- `link-oidc` and `oidc-move-issuer` help with single sign-on, see
  [Single sign-on](sso.md#emergency-access-and-changing-the-provider).
