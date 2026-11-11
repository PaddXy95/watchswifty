# Installation

WatchSwifty runs as a single Docker container with one SQLite file in a volume. The image
`ghcr.io/paddxy95/watchswifty` is built for `linux/amd64` on every release, see [Releases](releases.md).

## Docker Compose

1. Create a folder on the server (for example `~/watchswifty`), copy `docker-compose.yml` and `.env.example` from
   this repository into it and rename `.env.example` to `.env`.
2. In `.env`, set at least `TOKEN_KEY` and `ADMIN_PASSWORD`. Create the key with the command below and also keep it
   somewhere safe, see [Encryption key](configuration.md#encryption-key). Make the file readable only for you.

   ```bash
   openssl rand -base64 32
   ```

   ```bash
   chmod 600 .env
   ```

3. Start the container:

   ```bash
   docker compose up -d
   ```

4. Open `http://<server>:8080` and sign in as the admin.
5. Paste your own TMDB token under **Konto** (account), see [TMDB](tmdb.md).

`ADMIN_USERNAME` and `ADMIN_PASSWORD` are only used on the very first start, while there is no user yet; after that
they are ignored. The admin creates further accounts under **Benutzer** (users), see [Accounts](accounts.md).

Show the logs or stop the container:

```bash
docker compose logs -f watchswifty
```

```bash
docker compose down
```

`docker compose down` keeps the data in the volume `watchswifty-data`.

## docker run

```bash
docker volume create watchswifty-data
```

```bash
docker run -d --name watchswifty --restart unless-stopped \
  -p 8080:8080 \
  -v watchswifty-data:/data \
  -e TZ=Europe/Berlin \
  -e TOKEN_KEY='<openssl rand -base64 32>' \
  -e ADMIN_USERNAME=admin -e ADMIN_PASSWORD='a-long-password' \
  ghcr.io/paddxy95/watchswifty:latest
```

## Data directory

Instead of a named volume you can use a directory, for example `-v /srv/watchswifty:/data` (in Compose:
`- /srv/watchswifty:/data`). On start the container hands the folder to the app user (UID 999) and then runs without
root privileges. If you start it with your own `user:` setting, the folder must belong to that UID.

## Reverse proxy (HTTPS)

The app does not speak TLS. For access from outside your home network, put a reverse proxy with HTTPS in front of it
(for example Caddy, Traefik or nginx). To protect against CSRF, the address the browser calls must reach the app:
either through the `Host` header including the port, or through `PUBLIC_ORIGIN`. Example for nginx:

```nginx
location / {
    proxy_pass http://watchswifty:8080;
    proxy_set_header Host $http_host;          # keeps the port, unlike $host
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Alternatively set `PUBLIC_ORIGIN=https://nas.lan:8443`, see [Configuration](configuration.md).

## Building the image yourself

```bash
git clone https://github.com/PaddXy95/watchswifty.git
```

```bash
cd watchswifty && docker build -t watchswifty .
```

Then use `image: watchswifty` in `docker-compose.yml`, or `watchswifty` instead of
`ghcr.io/paddxy95/watchswifty:latest` with `docker run`. The image is built for the architecture of the machine that
builds it; the GitHub Action builds `linux/amd64`.
