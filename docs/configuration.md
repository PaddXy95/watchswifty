# Configuration

WatchSwifty is configured through environment variables (with Compose: the `.env` file next to
`docker-compose.yml`, template `.env.example`). Mail and single sign-on are set up in the web UI under **System**, not
here, see [Mail](email.md) and [Single sign-on](sso.md).

## Environment variables

| Variable | Required | Meaning |
|---|---|---|
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | first start only | First admin (password at least 8 characters) |
| `TZ` | recommended | Time zone for "today" and for the time of the daily run ([notifications](notifications.md)), for example `Europe/Berlin` |
| `TMDB_LANGUAGE` | no | Language of the TMDB data, default `de-DE` |
| `TOKEN_KEY` | recommended | Key for the encrypted secrets (Base64, 32 bytes), see [Encryption key](#encryption-key) |
| `TOKEN_KEY_FILE` | no | File with the key instead of `TOKEN_KEY` (for example a Docker secret) |
| `PUBLIC_ORIGIN` | no | Public address(es) behind a reverse proxy, comma-separated, for example `https://nas.lan:8443` |
| `PASSWORD_LOGIN` | no | Only `true`: emergency switch that forces password login, see [Single sign-on](sso.md#emergency-access-and-changing-the-provider) |
| `DATABASE_PATH` | no | Default `/data/watchswifty.sqlite` |
| `HOST` / `PORT` | no | Default `0.0.0.0` / `8080` |

The Compose file also reads `WATCHSWIFTY_VERSION` (image tag, default `latest`, see [Releases](releases.md#image-tags))
and `WATCHSWIFTY_PORT` (port on the server, default `8080`).

## Encryption key

Each user's TMDB token, the mail settings, the single sign-on settings and users' e-mail addresses are stored
encrypted with AES-GCM. A lost database file or an SQLite backup therefore does not contain them in readable form.
The key comes from:

1. `TOKEN_KEY`: 32 bytes as Base64 (`openssl rand -base64 32`), **recommended**;
2. otherwise `TOKEN_KEY_FILE`: path to a file with this value (for example a Docker secret);
3. otherwise WatchSwifty creates `token.key` next to the database in the volume on the first start (with a notice in
   the log). That protects a plain SQLite backup, but not a copy of the whole volume.

Keep the key separate from the data. If it is lost or changes, the stored secrets can no longer be read: every user
enters their TMDB token and e-mail address under **Konto** (account) again, and the admin sets up mail and single
sign-on again under **System**. All other data stays. Tokens from older versions are encrypted automatically on start.
