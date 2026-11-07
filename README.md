# watchswifty

Selbst gehosteter Serien- und Film-Tracker in Swift (Vapor 4, Fluent/SQLite, Elementary + htmx).

- **Weiterschauen:** eine Karte pro Serie mit der nächsten Folge
- **Netflix-Import:** Wiedergabeaktivität als CSV hochladen, wird automatisch TMDB zugeordnet
- **Manuell:** Serien/Filme suchen, Folgen abhaken (mit Datum und Dienst), bewerten (1–10)
- **Verlauf** und **Bibliothek**
- **Mehrere Benutzer** mit getrennten Daten; der Admin legt Konten an

## Starten (Docker Compose)

Die GitHub Action baut bei jedem Push auf `main` ein Image nach `ghcr.io/<github-name>/watchswifty`.
In `docker-compose.yml` `dein-github-name` ersetzen, dann:

```bash
ADMIN_USERNAME=admin ADMIN_PASSWORD=… docker compose up -d
```

Die App läuft auf Port 8080. Beim ersten Start wird der Admin aus `ADMIN_USERNAME`/`ADMIN_PASSWORD`
angelegt; danach werden die beiden Variablen ignoriert. Weitere Konten legt der Admin unter
**Benutzer** an.

## TMDB-Token

Jeder Benutzer hinterlegt unter **Konto** seinen eigenen kostenlosen TMDB *Read Access Token*
(themoviedb.org → Einstellungen → API). Ohne Token funktionieren Suche und Netflix-Zuordnung nicht;
bereits bekannte Titel, Weiterschauen, Verlauf und Bibliothek schon. Der Token wird beim Speichern bei
TMDB geprüft und danach nur noch mit den letzten vier Zeichen angezeigt – auch Admins sehen ihn nicht.

## Konfiguration

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `TMDB_LANGUAGE` | nein | Sprache der TMDB-Daten, Standard `de-DE` |
| `DATABASE_PATH` | nein | Standard `/data/watchswifty.sqlite` |
| `HOST` / `PORT` | nein | Standard `0.0.0.0` / `8080` |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | nur erster Start | Erster Admin (Passwort mindestens 8 Zeichen) |
| `TZ` | nein | Zeitzone für „heute“, z. B. `Europe/Berlin` |
| `PUBLIC_ORIGIN` | nein | Öffentliche Adresse(n) hinter einem Reverse-Proxy, kommagetrennt, z. B. `https://nas.lan:8443` |

## Netflix-Verlauf importieren

1. Auf netflix.com: Profil → Konto → Profil wählen → **Wiedergabeaktivität** → **Alle herunterladen**.
2. In watchswifty unter **Import** die Datei `NetflixViewingHistory.csv` hochladen.
3. Eindeutige Serien/Filme werden automatisch zugeordnet. Unklare Namen erscheinen unter
   **Zu prüfen**, nicht gefundene Folgen unter **Nicht zugeordnet**. Falsche Treffer lassen sich unter
   **Zuordnungen** ändern oder zurücksetzen.

Ein erneuter Import desselben (oder eines neueren) Exports legt keine Duplikate an.

## Backup

Alle Daten liegen in einer SQLite-Datei im Volume (`/data/watchswifty.sqlite`). Für ein Backup diese
Datei kopieren, am besten bei gestopptem Container. Die Datei enthält die TMDB-Tokens der Benutzer im
Klartext – Backups entsprechend geschützt aufbewahren.

## Zugriff von außerhalb

Die App spricht kein TLS. Für Zugriff außerhalb des Heimnetzes einen Reverse-Proxy (z. B. Caddy,
Traefik, nginx) mit HTTPS davorsetzen. Zum Schutz vor CSRF muss die Adresse, die der Browser
aufruft, bei der App ankommen – entweder über den `Host`-Header inklusive Port oder über
`PUBLIC_ORIGIN`. Beispiel nginx:

```nginx
location / {
    proxy_pass http://watchswifty:8080;
    proxy_set_header Host $http_host;          # behält den Port, anders als $host
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Alternativ `PUBLIC_ORIGIN=https://nas.lan:8443` setzen.

## Entwicklung

```bash
swift test
DATABASE_PATH=./dev.sqlite ADMIN_USERNAME=admin ADMIN_PASSWORD=adminpass123 swift run App serve
```

Voraussetzung: Swift 6.3 oder neuer.
