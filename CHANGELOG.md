# Changelog

Alle nennenswerten Änderungen an WatchSwifty. Versionen folgen [SemVer](https://semver.org/lang/de/).

## [Unveröffentlicht]

### Neu
- **Mail bei neuem Gerät:** Verbindet sich eine App mit einem Konto, geht eine Mail an die unter **Konto** hinterlegte
  Adresse – mit Gerätename, Zeitpunkt und Link zum Abmelden (nur mit eingerichteter E-Mail).

### Geändert
- **App-Anmeldung:** Die Rücksprung-Adresse heißt jetzt `dev.patmei.watchswifty:/auth` statt `watchswifty://auth`
  (Schema nach Reverse-DNS, RFC 8252). Apps müssen sie anpassen, die alte Adresse wird abgelehnt.

### Sicherer
- Keine Seite lässt sich mehr in fremde Seiten einbetten (`X-Frame-Options: DENY`, `frame-ancestors 'none'`). Das
  schützt vor Clickjacking, auch durch andere Dienste auf demselben Server oder unter derselben Domain.
- Die API-Doku unter `/api` speichert ein eingefügtes Token nicht mehr im Browser; ein früher gespeichertes wird beim
  Öffnen gelöscht.

## [0.3.0] – 2026-11-09

### Neu
- **E-Mail (optional):** SMTP-Versand, eingerichtet als Admin unter **System → E-Mail** und verschlüsselt gespeichert;
  mit „Testmail senden“. Funktioniert mit [SwiftyRelay](https://github.com/PaddXy95/SwiftyRelay) (CA-Datei aus dessen
  Volume) und normalen Anbietern.
- **Einladungen:** Der Admin legt ein Konto mit Benutzername und E-Mail-Adresse an, die Person setzt ihr Passwort über
  den Link selbst (7 Tage gültig, erneut senden möglich). Admins sehen Adressen nur gekürzt.
- **Passwort vergessen** auf der Anmeldeseite: Link per Mail an die unter **Konto** hinterlegte Adresse (1 Stunde gültig).
- **Konto:** eigene E-Mail-Adresse hinterlegen (verschlüsselt gespeichert, Ändern nur mit aktuellem Passwort).
- App-API: Mail-Einstellungen, Einladungen und die eigene Adresse (`/api/v1/admin/mail`, `/api/v1/admin/users/{id}/invite`,
  `/api/v1/me/email`).

### Sicherer
- Die Anmeldung verrät über die Antwortzeit nicht mehr, ob es einen Benutzernamen gibt.

## [0.2.6] – 2026-11-08

### Neu
- **App-Icon:** „WS“ mit einem startenden Mauersegler – als Favicon im Browser-Tab, im Kopf der Seite, als Icon auf
  dem Homescreen (iPhone/Android) und im README.
- **Passwort vergessen:** `reset-password <benutzer>` setzt ein Passwort auf dem Server neu, auch für den
  einzigen Admin (`docker exec -it watchswifty /app/docker-entrypoint.sh reset-password <benutzer>`, Passwort wird
  verdeckt abgefragt).

## [0.2.5] – 2026-11-08

### Neu
- **Statistik übersichtlicher:** Zeitraum oben wählen (alle Jahre oder ein Jahr) – Kennzahlen mit Veränderung zum
  Vorjahr, Diagramm „Zeit pro Monat“ (Serien und Filme gestapelt, Werte beim Drüberfahren), Anteil je Dienst,
  „Meistgesehen“ (Top-5-Serien) und Bewertungen als Diagramm. Die bisherigen Tabellen liegen unter „Alle Zahlen“.
  Die App-API liefert dieselben Felder (`GET /api/v1/stats?year=` filtert jetzt alles).

### Schneller
- Poster werden in passender Größe, verzögert und asynchron geladen.
- „Weiterschauen“ öffnet deutlich schneller.

### Behoben
- App-API: keine Tokens, Cookies oder Passwörter mehr in Fehler-Logs; fehlerhafte Anfragen ergeben 4xx statt 500;
  Größenlimits für Anfragen; riesige Seitenzahlen bringen den Server nicht mehr zum Absturz.

## [0.2.4] – 2026-11-08

### Neu
- **App-API (Phase 5):** Benutzerverwaltung (nie für das eigene Konto) und System (Version, Update-Prüfung) –
  damit kann die API alles, was die Weboberfläche kann.

### Geändert
- **Benutzer (Web):** Admins können ihr eigenes Passwort und Admin-Recht nicht mehr über die Benutzerverwaltung
  ändern (eigenes Passwort unter **Konto**).

## [0.2.3] – 2026-11-08

### Neu
- **App-API (Phase 4):** Netflix-Import (Upload bis 10 MB, Stand, „Zu prüfen“, Zuordnungen ändern, nicht
  zugeordnete Zeilen zuweisen) und Filmliste (Upload bis 2 MB, Vorschläge, Suchen, Überspringen).

## [0.2.2] – 2026-11-08

### Neu
- **App-API (Phase 3):** Verlauf (blättern, Sichtung ändern/löschen), Bibliothek, Statistik und Konto (Passwort,
  TMDB-Token, beobachtete Serien).

## [0.2.1] – 2026-11-08

### Neu
- **App-API (Phase 2):** Weiterschauen inkl. „nächste Folge gesehen“ und Dienst-Link, Hinweise (neue Folgen,
  demnächst), Suche, Serien (Details, Folgen/Staffel/Serie abhaken, Bewertung, Kommentare, Beobachten,
  Ausblenden) und Filme.

## [0.2.0] – 2026-11-08

### Neu
- **App-API (Phase 1):** JSON-API unter `/api/v1`, beschrieben in einer OpenAPI-Datei (Server-Code wird daraus
  erzeugt), Doku mit „Ausprobieren“ unter `/api`.
- **App-Anmeldung:** Login im Browser-Fenster mit Bestätigung („App verbinden“), danach ein Geräte-Token
  (90 Tage gültig, nur als Hash gespeichert). Unter **Konto → Geräte** alle Geräte sehen und abmelden sowie
  Tokens für Skripte erstellen.

## [0.1.2] – 2026-11-08

### Neu
- **Weiterschauen:** Button für den zuletzt genutzten Dienst statt nur „Auf Netflix suchen“ – Suche bei Netflix,
  Prime Video, Apple TV+ und Paramount+; „Disney+ / HBO Max / WOW öffnen“ (dort gibt es ohne Login keine Websuche).
- **TMDB-Bedingungen:** tägliche Cache-Pflege – jeder Titel wird spätestens nach 60 Tagen mit dem Token eines
  Benutzers, der ihn nutzt, neu geholt; ungenutzte Titel werden gelöscht, alte Vorschlagslisten verworfen. Footer
  rechts zeigt TMDB-Logo und -Hinweis (statt „GitHub“).

## [0.1.1] – 2026-11-07

### Neu
- **Filmliste importieren:** eigene CSV (z. B. aus Numbers) mit Datum, Dienst, Bewertung 0–100 → 1–10 und
  Kommentar aus „Mit …“, Übeltäter und Bemerkung; unklare Filme werden zur Auswahl vorgeschlagen.
- **Update-Hinweis:** Admin-Seite „System“ mit optionaler Prüfung auf neue Releases bei GitHub
  (alle 12 Stunden, standardmäßig aus) und „Jetzt prüfen“.
- **Betrieb:** `docker-compose.yml` liest alle Einstellungen aus einer `.env` (Vorlage `.env.example`);
  ohne `TOKEN_KEY` startet Compose nicht.


### Behoben
- Datenordner als Bind-Mount (z. B. `/home/docker/watchswifty:/data`): Der Container übergibt den Ordner beim
  Start dem App-Benutzer (UID 999) statt mit „cantOpen“ abzustürzen; ist das nicht möglich, erklärt eine Meldung,
  was zu tun ist.

### Geändert
- CI: GitHub Actions auf Node-24-Versionen; Image-Build läuft parallel zu den Tests, Abhängigkeiten werden im
  Docker-Build zwischengespeichert – ein Push baut nur noch die App neu.

## [0.1.0] – 2026-11-07

Erste Version.

### Neu
- **Weiterschauen:** eine Karte pro Serie mit der nächsten Folge, „✓ gesehen“, Ausblenden, Link „Auf Netflix suchen“;
  nur Serien der letzten 3 Monate (ältere per „N ältere Serien anzeigen“).
- **Beobachten:** Serien auf der Serienseite beobachten; Kasten „Neue Folgen“ (mit „Erledigt“) und „Demnächst“
  (Folgen der nächsten 14 Tage) auf der Startseite; Liste der beobachteten Serien unter Konto.
- **Manuelles Tracking:** Folgen/Filme abhaken mit Datum und Dienst (Netflix, Prime Video, Disney+, Apple TV+, HBO Max,
  Paramount+, WOW, Kino, Gekauft, Sonstiges), erneut gesehen, „Ganze Staffel“, „bis hier“ und „Gesamte Serie gesehen“,
  Bewertung 1–10, private Kommentare zu Serie, Staffel und Film.
- **Detailseiten:** Klappentext zu Serie, Film und jeder Folge; Links zu TMDB, IMDb, Rotten Tomatoes und SeriesGraph.
- **Netflix-Import:** Wiedergabeaktivität als CSV (auch Excel-Varianten), automatische TMDB-Zuordnung, „Zu prüfen“,
  „Nicht zugeordnet“, „Zuordnungen“, „Erneut versuchen“ und automatische Wiederholung.
- **Verlauf** und **Bibliothek** mit Filter und Sortierung.
- **Statistik:** Filme, Serien, Folgen und verbrachte Zeit (TMDB-Laufzeiten) – insgesamt, pro Jahr und Monat
  sowie nach Bewertung.
- **Benutzer:** mehrere Konten mit getrennten Daten, Admin-Verwaltung, eigener TMDB-Token pro Benutzer
  (in der Datenbank mit AES-GCM verschlüsselt, Schlüssel über `TOKEN_KEY`).
- **Oberfläche:** WatchSwifty-Branding, Smartphone-Layout mit Burger-Menü, Ladebalken und Lade-Animation auf Kacheln,
  deutsche Fehlerseiten.
- **Betrieb:** Docker-Image über GitHub Actions (`ghcr.io/paddxy95/watchswifty`), Compose-Datei, SQLite-Datenbank im
  Volume, Version im Footer und unter `/version`.
