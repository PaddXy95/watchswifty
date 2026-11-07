# WatchSwifty

Selbst gehosteter Serien- und Film-Tracker in Swift (Vapor 4, Fluent/SQLite, Elementary + htmx).

- **Weiterschauen:** eine Karte pro Serie mit der nächsten Folge (Serien der letzten 3 Monate)
- **Netflix-Import:** Wiedergabeaktivität als CSV hochladen, wird automatisch TMDB zugeordnet
- **Manuell:** Serien/Filme suchen, Folgen abhaken (mit Datum und Dienst), bewerten (1–10),
  private Kommentare zu Serie, Staffel und Film
- **Verlauf** und **Bibliothek**, Klappentext und Links zu TMDB, IMDb, Rotten Tomatoes, SeriesGraph
- **Mehrere Benutzer** mit getrennten Daten; der Admin legt Konten an

Repository: https://github.com/PaddXy95/watchswifty

---

## Schnellstart mit Docker Compose

Die GitHub Action baut bei jedem Push auf `main` das Image `ghcr.io/paddxy95/watchswifty:latest`.

1. `docker-compose.yml` aus diesem Repository auf den Server kopieren (oder das Repo klonen).
2. Ersten Admin festlegen und starten:

   ```bash
   ADMIN_USERNAME=admin ADMIN_PASSWORD='ein-langes-passwort' docker compose up -d
   ```

3. Im Browser `http://<server>:8080` öffnen und mit dem Admin anmelden.
4. Unter **Konto** den eigenen TMDB-Token hinterlegen (siehe unten).

`ADMIN_USERNAME`/`ADMIN_PASSWORD` werden nur beim allerersten Start gebraucht, solange es noch keinen
Benutzer gibt; danach werden sie ignoriert. Weitere Konten legt der Admin unter **Benutzer** an.

Logs ansehen bzw. stoppen:

```bash
docker compose logs -f watchswifty
```

```bash
docker compose down
```

`docker compose down` lässt die Daten im Volume `watchswifty-data` stehen.

## Start mit `docker run`

```bash
docker volume create watchswifty-data
```

```bash
docker run -d --name watchswifty --restart unless-stopped \
  -p 8080:8080 \
  -v watchswifty-data:/data \
  -e TZ=Europe/Berlin \
  -e ADMIN_USERNAME=admin -e ADMIN_PASSWORD='ein-langes-passwort' \
  ghcr.io/paddxy95/watchswifty:latest
```

Statt eines benannten Volumes geht auch ein Verzeichnis, z. B. `-v /srv/watchswifty:/data`
(es muss für den Container-Benutzer beschreibbar sein).

## Update

Mit Compose:

```bash
docker compose pull && docker compose up -d
```

Mit `docker run`:

```bash
docker pull ghcr.io/paddxy95/watchswifty:latest
```

```bash
docker rm -f watchswifty
```

Danach den `docker run`-Befehl von oben erneut ausführen (das Volume bleibt erhalten).
Datenbank-Änderungen neuer Versionen werden beim Start automatisch angewendet.

## TMDB-Token

Jeder Benutzer hinterlegt unter **Konto** seinen eigenen kostenlosen TMDB *Read Access Token*
(themoviedb.org → Einstellungen → API). Ohne Token funktionieren Suche und Netflix-Zuordnung nicht;
bereits bekannte Titel, Weiterschauen, Verlauf und Bibliothek schon. Der Token wird beim Speichern bei
TMDB geprüft und danach nur noch mit den letzten vier Zeichen angezeigt – auch Admins sehen ihn nicht.

## Netflix-Verlauf importieren

1. Auf netflix.com: Profil → Konto → Profil wählen → **Wiedergabeaktivität** → **Alle herunterladen**.
2. In WatchSwifty unter **Import** die Datei `NetflixViewingHistory.csv` hochladen.
3. Eindeutige Serien/Filme werden automatisch zugeordnet. Unklare Namen erscheinen unter
   **Zu prüfen**, nicht gefundene Folgen unter **Nicht zugeordnet**. Falsche Treffer lassen sich unter
   **Zuordnungen** ändern oder zurücksetzen.

Ein erneuter Import desselben (oder eines neueren) Exports legt keine Duplikate an. Auch eine in Excel
(deutsch) neu gespeicherte Datei mit `;` und `TT.MM.JJJJ` wird erkannt.

## Konfiguration

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | nur erster Start | Erster Admin (Passwort mindestens 8 Zeichen) |
| `TZ` | empfohlen | Zeitzone für „heute“, z. B. `Europe/Berlin` |
| `TMDB_LANGUAGE` | nein | Sprache der TMDB-Daten, Standard `de-DE` |
| `PUBLIC_ORIGIN` | nein | Öffentliche Adresse(n) hinter einem Reverse-Proxy, kommagetrennt, z. B. `https://nas.lan:8443` |
| `DATABASE_PATH` | nein | Standard `/data/watchswifty.sqlite` |
| `HOST` / `PORT` | nein | Standard `0.0.0.0` / `8080` |

## Backup und Wiederherstellung

Alle Daten liegen in einer SQLite-Datei im Volume (`/data/watchswifty.sqlite`). Die Datei enthält die
TMDB-Tokens der Benutzer im Klartext – Backups entsprechend geschützt aufbewahren.

Backup (Container kurz stoppen, damit die Datei konsistent ist):

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

Wiederherstellen: Container stoppen, die Sicherung als `/data/watchswifty.sqlite` zurückkopieren
(gleicher `docker run … cp`-Befehl mit vertauschten Pfaden), Container starten.

## Zugriff von außerhalb (Reverse-Proxy)

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

## Image selbst bauen

```bash
git clone https://github.com/PaddXy95/watchswifty.git
```

```bash
cd watchswifty && docker build -t watchswifty .
```

Danach in `docker-compose.yml` `image: watchswifty` eintragen bzw. bei `docker run` `watchswifty`
statt `ghcr.io/paddxy95/watchswifty:latest` verwenden. Das Image wird für die Architektur des
bauenden Rechners erzeugt; die GitHub Action baut `linux/amd64`.

## Entwicklung

Voraussetzung: Swift 6.3 oder neuer.

```bash
swift test
```

```bash
DATABASE_PATH=./dev.sqlite ADMIN_USERNAME=admin ADMIN_PASSWORD=adminpass123 swift run App serve
```
