# WatchSwifty – JSON-API für eine App (Design)

Stand: 2026-11-08 · Status: zur Freigabe (Fragen des Gutachters eingearbeitet) · Ergänzt `2026-11-07-watchswifty-design.md`

**Warum:** Der Nutzer will eine native App (iPhone/iPad, Swift) an WatchSwifty anbinden. Heute liefert der Server
nur HTML-Seiten (htmx) mit Cookie-Login und Origin-Prüfung; maschinenlesbar sind nur `/healthz` und `/version`.

## Entschieden (vom Nutzer)
1. **Umfang wie im Web:** jede Funktion der Weboberfläche ist auch per API erreichbar – einschließlich Importe,
   Konto, Benutzerverwaltung und System.
2. **OpenAPI-Dokumentation von Anfang an**, veröffentlicht unter `/api`.
3. **Login im Browser-Fenster:** Die App öffnet die normale Login-Seite in einem System-Browser-Fenster
   (iOS: `ASWebAuthenticationSession`), danach erhält sie ein **Geräte-Token**. Geräte sind unter **Konto**
   einzeln widerrufbar. Die App sieht nie ein Passwort.
4. **Spezifikation zuerst:** `openapi.yaml` ist die Quelle; Server-Code wird mit Apples `swift-openapi-generator`
   erzeugt und über das offizielle Paket `vapor/swift-openapi-vapor` (OpenAPIVapor) an Vapor gehängt.

## Ziele, Nicht-Ziele, Anti-Ziele
**Ziele**
- Eine App kann alles, was die Weboberfläche kann, mit denselben Regeln und Ergebnissen (gleiche Services).
- Anmeldung funktioniert mit Passwort-Login **und** später mit dem geplanten OIDC-Login (SSO)
  (`2026-11-07-oidc-login-design.md`, Passwort-Login dort abschaltbar) – ohne Änderung an der App.
- Die Doku unter `/api` ist immer aktuell (aus derselben Datei wie der Server) und lässt sich mit einem Token
  direkt ausprobieren.
- Die iOS-App kann ihren Client aus derselben `openapi.yaml` erzeugen.

**Nicht-Ziele**
- Die iOS-App selbst (eigenes Projekt).
- Push-Benachrichtigungen, Offline-Synchronisation, Konfliktauflösung.
- Öffentliche API für Dritte (OAuth-Scopes, App-Registrierung, Rate-Limits pro Client).
- Änderungen am Verhalten der Weboberfläche – außer: Geräteliste mit „Token erstellen“ unter Konto,
  Bestätigungsseite für die App-Anmeldung, Rücksprung nach dem Login (s. Anmeldung).

**Anti-Ziele** (wäre ein Fehlschlag, auch wenn es technisch funktioniert)
- Die API akzeptiert Session-Cookies – dann wäre sie per CSRF von fremden Seiten aufrufbar.
- Geräte-Tokens liegen im Klartext in der Datenbank oder erscheinen in Logs.
- Ein Token landet bei einer fremden App oder Webseite (offene Weiterleitung im Login-Ablauf).
- Die API dupliziert Geschäftslogik und verhält sich dadurch anders als das Web.
- Der TMDB-Token eines Benutzers ist über die API abrufbar.

## Rahmenbedingungen
- Vapor 4, Fluent/SQLite, Swift 6.3+ (CI: `swift:6.4-noble`, Linux), Docker `linux/amd64`.
- Die Logik steckt größtenteils in Services (`WatchService`, `ContinueWatchingService`, `NewEpisodesService`,
  `StatsService`, `CatalogService`, `MappingService`, `ImportService`, `FilmListService`/`FilmListImporter`,
  `UpdateService`, `AccountValidation`); die API ruft ausschließlich Services auf. [Entscheidung des Entwurfs]
  Was heute noch in Controllern steckt (Bibliothek, Verlauf mit Paging, Import-Status/-Fortschritt,
  Benutzerverwaltung, TMDB-Token speichern/prüfen, Filmliste „Erneut versuchen“/„Überspringen“, Suche ohne Token),
  wird vorher in Services verschoben, die Web und API gemeinsam nutzen.
- TMDB-Aufrufe laufen wie im Web mit dem TMDB-Token des angemeldeten Benutzers (`req.tmdb`); fehlt er,
  antwortet die API mit einem eigenen Fehlercode (`missingTMDBToken`).
- Datentrennung pro Benutzer und Admin-Rechte gelten genau wie im Web.
- Deutsche Texte nur in Fehlermeldungen (`message`); Feldnamen und Codes englisch.

## Ansätze
| Ansatz | Abwägung | Ergebnis |
|---|---|---|
| **A: Spezifikation zuerst** – `swift-openapi-generator` + `vapor/swift-openapi-vapor` | Eine Datei für Doku, Server und App-Client; Compiler erzwingt Übereinstimmung; drei neue Abhängigkeiten, längere Builds | **gewählt** |
| B: Routen von Hand in Vapor, `openapi.yaml` separat gepflegt | Keine neuen Abhängigkeiten, vertrauter Stil; bei ~65 Endpunkten laufen Doku und Code auseinander | verworfen |
| C: Spezifikation aus dem Code (`dankinsoid/VaporToOpenAPI`) | Kein YAML; Ein-Personen-Paket, nur OpenAPI 3.0.1, Doku nur so gut wie die Annotationen | verworfen |

## Aufbau
- **Neues SwiftPM-Target `WatchSwiftyAPI`** (Library) mit `openapi.yaml` und
  `openapi-generator-config.yaml` (`generate: [types, server]`, `accessModifier: package`); Abhängigkeit
  `OpenAPIRuntime`. Das Target `App` hängt davon und von `OpenAPIVapor` ab. Generierter Code wird nicht eingecheckt.
- **Einhängen:** `VaporTransport` auf einer Routengruppe `/api/v1` mit der Token-Middleware; eine Struktur
  `WatchSwiftyAPI: APIProtocol` im App-Target implementiert jede Operation, indem sie Services aufruft und deren
  Ergebnisse in die erzeugten Typen übersetzt.
- **Zugriff auf Benutzer/Datenbank im Handler:** Eine Vapor-Middleware der Gruppe legt den `Request` in einen
  `@TaskLocal`; die Handler lesen daraus Benutzer, `db`, `tmdb`, Konfiguration.
- **Fehler:** einheitlich `{"code": "...", "message": "..."}` mit passendem HTTP-Status. Codes u. a.
  `unauthorized` (401, Header `WWW-Authenticate: Bearer`), `forbidden` (403), `notFound` (404),
  `validation` (422), `missingTMDBToken` (422), `tmdbUnavailable` (503). Die Texte entsprechen denen der
  Weboberfläche (`TrackingError`, `TMDBError`, `AccountValidation`).
- **Konventionen:** Serien `GET /v1/tv/{tmdbID}`, Filme `GET /v1/movies/{tmdbID}`, Folgen über
  `{season}/{number}`, Sichtungen über ihre UUID; Tage `yyyy-MM-dd`, Zeitpunkte RFC 3339; Dienste als die
  vorhandenen Rohwerte (`netflix`, `prime_video`, …); Listen mit `page`/`perPage` und `total`.

## Anmeldung der App (Geräte-Tokens)
Ablauf nach RFC 8252 (OAuth für native Apps, Authorization Code + PKCE), aber ohne allgemeines OAuth:
1. App erzeugt `code_verifier` (PKCE, S256) und `state` und öffnet
   `GET /api/auth/authorize?redirect_uri=dev.patmei.watchswifty:/auth&state=…&code_challenge=…&code_challenge_method=S256&device_name=…`.
2. Ist der Browser nicht angemeldet, erscheint die normale Login-Seite (Passwort bzw. später SSO) und kehrt
   danach zu diesem Aufruf zurück. Dann zeigt der Server eine Bestätigung: „Die WatchSwifty-App auf
   „{device_name}“ mit deinem Konto verbinden?“ – „Verbinden“ / „Abbrechen“ (POST, durch die Origin-Prüfung).
3. „Verbinden“ erzeugt einen Einmal-Code (zufällig, 60 s gültig, nur einmal einlösbar, gebunden an Benutzer,
   `code_challenge`, `redirect_uri`, Gerätename) und leitet auf `dev.patmei.watchswifty:/auth?code=…&state=…` weiter.
   „Abbrechen“ leitet auf `dev.patmei.watchswifty:/auth?error=access_denied&state=…`.
4. App: `POST /api/v1/auth/token` mit `code`, `code_verifier`, `redirect_uri` → Antwort
   `{token, expiresAt, device: {id, name, createdAt}, user: {username, isAdmin}}`. Das Token wird nur hier einmal gezeigt.
- **Erlaubte Rücksprung-Adresse:** nur `dev.patmei.watchswifty:/auth` (fest im Server); alles andere → Fehlerseite, keine
  Weiterleitung.
- **Token:** `ws_` + 32 zufällige Bytes (Base64URL); gespeichert wird nur der SHA-256-Hash. Tabelle
  `api_tokens`: Benutzer (cascade), Name, Art (Gerät/manuell), Hash (unique), angelegt, läuft ab, zuletzt benutzt
  (höchstens stündlich aktualisiert). Ein Benutzer kann mehrere Geräte haben.
- **Abmelden:** `DELETE /v1/auth/token` widerruft das eigene Token; unter **Konto → Geräte** listet die
  Weboberfläche alle Geräte (Name, angelegt, zuletzt benutzt) mit „Abmelden“ je Gerät.
- **API-Anfragen** authentifizieren sich ausschließlich mit `Authorization: Bearer ws_…`; Session-Cookies werden
  unter `/api/v1` ignoriert. Die Origin-Prüfung entfällt für `/api/v1` (kein Cookie → kein CSRF), bleibt aber
  für `/api/auth/authorize`.
- Passwortänderung oder Admin-Passwort-Reset lassen Geräte bestehen; das Löschen eines Benutzers löscht seine Geräte.
- **Rücksprung nach dem Login** [Entscheidung des Entwurfs]: `/api/auth/authorize` leitet nicht angemeldete Browser
  mit `returnTo` (nur relative Pfade unter `/api/auth/authorize`, sonst verworfen) auf die Login-Seite; der
  Passwort-Login kehrt danach dorthin zurück. Der OIDC-Entwurf bekommt einen Nachtrag, denselben `returnTo` über
  `/auth/oidc/start` (auch beim Wechsel auf die kanonische Adresse) und den Callback mitzunehmen. Damit ist egal, ob
  API oder SSO zuerst kommt.
- **Token-Laufzeit** [entschieden]: **90 Tage ab Ausstellung**, dann neu verbinden. `POST auth/token` liefert
  `expiresAt`; ein abgelaufenes Token ergibt `401` mit Code `tokenExpired`, die App öffnet dann wieder das
  Browser-Fenster (bei bestehender Web-Anmeldung genügt „Verbinden“; bei SSO-Konten wird der Zugang dabei beim
  Provider neu geprüft, s. `2026-11-07-oidc-login-design.md`, „App verbinden“). Abgelaufene Tokens werden von der täglichen Pflege gelöscht; manuell erstellte Tokens laufen ebenso
  nach 90 Tagen ab.
- **Token für Skripte und die Doku** [Entscheidung des Entwurfs, Teil von v1]: Unter **Konto → Geräte** kann man
  zusätzlich ein Token von Hand erstellen (Name eingeben, Token wird einmal angezeigt). Es erscheint in der Liste
  als „manuell erstellt“ und gilt sonst wie ein Geräte-Token. Ohne das ließe sich die Doku nicht ausprobieren,
  weil der Browser-Ablauf nur zur App zurückspringt.

## Endpunkte (Umfang, je Gruppe)
Alle unter `/api/v1`, alle mit Bearer-Token außer `version`, `auth/token`.
- **Meta:** `GET version`.
- **Auth/Konto:** `POST auth/token`, `DELETE auth/token`, `GET me` (Benutzername, Admin, `hasPassword` – bis
  SSO kommt immer `true` –, TMDB-Token vorhanden + letzte 4 Zeichen bzw. „nicht lesbar“),
  `PUT me/password` (verlangt wie im Web das aktuelle Passwort; ohne Passwort-Konto `409 noPassword`),
  `PUT me/tmdb-token` (wird bei TMDB geprüft),
  `DELETE me/tmdb-token`, `GET me/devices`, `DELETE me/devices/{id}`, `GET me/followed` (beobachtete Serien).
- **Startseite:** `GET continue-watching?all=` (Karten inkl. `watchService`/`watchLink`, Anzahl ältere),
  `GET notes` (neue Folgen + demnächst), `POST tv/{id}/next` (nächste Folge gesehen),
  `POST tv/{id}/new-episodes/dismiss`.
- **Suche:** `GET search?q=` (TMDB multi, wie im Web).
- **Serien:** `GET tv/{id}` (Daten, Links, Bewertung, Kommentar, ausgeblendet, beobachtet, Staffeln mit Folgen,
  Gesehen-Status, Staffelkommentaren, zuletzt genutzter Dienst), `POST`/`DELETE tv/{id}/episodes/{s}/{n}/watch`
  (Datum, Dienst, erneut), `POST tv/{id}/episodes/{s}/{n}/watch-up-to`, `POST tv/{id}/seasons/{s}/watch`,
  `POST tv/{id}/watch-all`, `PUT tv/{id}/hidden`, `PUT tv/{id}/follow`, `PUT tv/{id}/rating`,
  `PUT tv/{id}/comment`, `PUT tv/{id}/seasons/{s}/comment`.
- **Filme:** `GET movies/{id}`, `POST`/`DELETE movies/{id}/watch`, `PUT movies/{id}/rating`,
  `PUT movies/{id}/comment`.
- **Verlauf:** `GET history?page=&perPage=`, `PUT watches/{id}` (Datum, Dienst), `DELETE watches/{id}`.
- **Bibliothek:** `GET library?filter=&sort=`.
- **Statistik:** `GET stats?year=`.
- **Netflix-Import:** `POST imports/netflix` (multipart CSV), `GET imports/netflix` (Fortschritt, „Zu prüfen“,
  „Nicht zugeordnet“, Zuordnungen mit Filter), `POST imports/netflix/retry`,
  `GET imports/netflix/mappings/{id}/search?q=`, `POST …/mappings/{id}/accept|ignore|reset|change`,
  `GET imports/netflix/rows/{id}/options`, `POST …/rows/{id}/assign|ignore`.
- **Filmliste:** `POST imports/films` (multipart CSV), `GET imports/films`, `POST imports/films/retry`,
  `POST imports/films/{id}/accept|search|skip`.
- **Admin (nur Admins):** `GET/POST admin/users`, `PUT admin/users/{id}/password`, `PUT admin/users/{id}/admin`,
  `DELETE admin/users/{id}` – [Entscheidung des Entwurfs] nie auf das eigene Konto (`422 selfAction`), damit ein
  gestohlenes Admin-Gerät das eigene Passwort nicht ohne das alte ändern und den Besitzer aussperren kann;
  das eigene Passwort nur über `PUT me/password`. *Änderung 2026-11-14 (Security-Audit F10):* Admin-Rechte vergeben
  (`POST admin/users` mit `isAdmin`, `PUT admin/users/{id}/admin`) sowie Passwort oder Verknüpfungslink für einen
  anderen Admin brauchen `currentPassword` des handelnden Admins (`403 confirmationRequired`, Konten ohne Passwort
  `403 confirmInBrowser` → im Browser) – sonst umgeht ein gestohlenes Gerät die Regel über einen zweiten Admin. Im
  Web gilt eine Bestätigung (Passwort oder SSO) 5 Minuten. `GET admin/system`, `PUT admin/system/update-check`, `POST admin/system/check-now`.

## Dokumentation unter `/api`
- `GET /api` → Doku-Seite (Swagger UI, Dateien im Repo unter `Public/api-docs/`, kein CDN) mit „Authorize“ für
  ein Bearer-Token; `GET /api/openapi.yaml` → die Spezifikation. Beides ohne Login lesbar.
- Zum Ausprobieren braucht man ein Token: [Vorschlag] unter **Konto → Geräte** zusätzlich „Token für Tests
  erstellen“ (Name eingeben, Token wird einmal angezeigt) – technisch dasselbe wie ein Geräte-Token.
- `info.version` der API ist unabhängig von der App-Version (`1.0.0` für `/v1`); inkompatible Änderungen → `/v2`.

## Umsetzung in Phasen (für den Plan)
1. Grundgerüst: Target + Generator, OpenAPIVapor, Token-Tabelle und -Middleware, Login-Ablauf mit Bestätigung,
   Geräte unter Konto, Fehlerformat, Doku unter `/api`, `version`, `me`.
2. Kern: Startseite, Suche, Serien, Filme, Abhaken, Bewertung, Kommentare, Beobachten, Ausblenden.
3. Verlauf, Bibliothek, Statistik, Konto (Passwort, TMDB-Token, beobachtete Serien).
4. Netflix-Import und Filmliste.
5. Benutzerverwaltung und System.
Jede Phase ist für sich lauffähig und getestet (HTTP-Tests mit Bearer-Token je Endpunkt, Isolation zwischen
Benutzern, Admin-Schutz).

## Dem Builder überlassen
Anpassung des Dependency-Schritts im Dockerfile an das neue Target;
Schema-Namen und genaue Feldnamen; Swagger-UI-Version; wie der `@TaskLocal`-Request gebaut wird; ob die
Fehler-Antworten pro Operation oder global im Schema stehen; Paging-Standardwerte (Vorschlag `perPage` 50, max 200);
Struktur der Swift-Dateien im App-Target.

## [Vorschlag] Später
- Eigenes Target `WatchSwiftyClient` (`generate: [types, client]`, nur `OpenAPIRuntime`) als Library-Produkt,
  damit die iOS-App den Client per SwiftPM aus diesem Repo beziehen kann.
