# WatchSwifty – iOS-App (Design)

Stand: 2026-11-10 · Status: zur Freigabe · Baut auf `2026-11-08-app-api-design.md` (App-API) und
`2026-11-07-oidc-login-design.md` (SSO) auf

**Warum:** WatchSwifty soll sich auf dem iPhone wie eine echte App anfühlen – native Listen, Wischgesten, Tab-Leiste,
Pull-to-Refresh – statt als Webseite in Safari. Die App soll **nicht mehr können als die Weboberfläche**, sondern
dasselbe, nur nativ. Die App-API (`/api/v1`) mit Browser-Login und Geräte-Tokens gibt es bereits; sie wurde genau
dafür gebaut.

## Entschieden (vom Nutzer)
1. **Native iPhone-App in SwiftUI.**
2. **Kein Offline-Betrieb.** Der Server bleibt die einzige Quelle; ohne Verbindung zeigt die App einen Hinweis.
3. **Umfang: alles wie im Web** – Startseite, Suche, Serien, Filme, Verlauf, Bibliothek, Statistik, Konto,
   Netflix-Import, Filmliste, Benutzerverwaltung und System (inkl. SSO- und Mail-Einstellungen).
4. **Keine lokale Datenbank** – weder Core Data noch SwiftData (Abwägung s. „Ansätze“).
5. **Verteilung über TestFlight – für jeden, der will** (öffentlicher Link, also externe Tester mit Apples
   Beta-Prüfung).
6. **Zugang zum Server per HTTPS oder über ein VPN.**

## Ziele, Nicht-Ziele, Anti-Ziele
**Ziele**
- Jede Funktion der Weboberfläche ist in der App erreichbar, mit denselben Regeln und Ergebnissen (die App ruft nur
  die App-API auf, die dieselben Services wie das Web nutzt).
- Die App fühlt sich an wie eine iOS-App: Tab-Leiste, Navigation-Stacks, Wischaktionen, Kontextmenüs, Blätter
  (Sheets), Pull-to-Refresh, Dynamic Type, Dark Mode, haptisches Feedback beim Abhaken.
- Anmeldung ohne Passworteingabe in der App: Browser-Fenster mit Passwort- oder SSO-Login, danach Geräte-Token.
- Ein Server-Update bricht die App nicht stillschweigend: Ist der Server zu alt, sagt die App das klar.

**Nicht-Ziele**
- Offline-Modus, lokale Datenbank, Synchronisation, Konfliktauflösung.
- Push-Benachrichtigungen, Widgets, Live Activities, App Intents/Siri, Apple Watch.
- Eigenes iPad- oder Mac-Layout (die iPhone-App läuft dort im Kompatibilitätsmodus).
- App Store (später möglich, s. „Später“).
- Eine zusätzliche Anmeldeschicht vor dem Server (z. B. Cloudflare Access, Forward-Auth): die App spricht nur mit
  WatchSwifty selbst; eine vorgeschaltete Login-Seite käme statt JSON zurück und wird nicht unterstützt.
- Neue Server-Funktionen oder geändertes Server-Verhalten – einzige Server-Änderung ist das Client-Target
  (s. „Änderungen am Server“).

**Anti-Ziele** (wäre ein Fehlschlag, auch wenn es technisch funktioniert)
- Die App rechnet Geschäftslogik selbst nach (z. B. „nächste Folge“, Statistik, Zuordnungen) und zeigt dadurch
  etwas anderes als das Web.
- Das Geräte-Token liegt außerhalb des Schlüsselbunds (UserDefaults, Datei) oder erscheint in Logs.
- Der Login läuft über eigene Eingabefelder der App statt über das Browser-Fenster.
- Nach einer Änderung zeigt ein anderer Bildschirm weiter den alten Stand, als wäre er aktuell (z. B. Folge
  abgehakt, Startseite zeigt sie noch als nächste).
- Ein neuer Wert auf dem Server (z. B. ein neuer Streaming-Dienst) lässt die ganze App mit einem Dekodierfehler
  ausfallen.

## Rahmenbedingungen
- Server: App-API unter `/api/v1` (OpenAPI 3.1, `Sources/WatchSwiftyAPI/openapi.yaml`), ~80 Operationen, 88 Schemas.
  Änderungen liefern den neuen Stand gleich zurück (z. B. `markEpisode` → `SeriesDetail`, `markNextEpisode` →
  `ContinueCard` bzw. `204`, wenn aufgeholt). Filtern, Sortieren und Paging macht der Server.
- Die API kennt keine Änderungsabfrage (kein `updatedAt`, `since`, ETag).
- Login nach RFC 8252 (Authorization Code + PKCE S256), Rücksprung fest `dev.patmei.watchswifty:/auth`, Einmal-Code
  60 s gültig, Token `ws_…` 90 Tage gültig; abgelaufen → `401` mit Code `tokenExpired`.
- Fehler kommen als `{"code", "message"}`; `message` ist bereits deutsch und entspricht dem Web.
- Server ist selbst gehostet: Adresse ist pro Installation verschieden. Erreicht wird er per HTTPS (öffentlich,
  z. B. hinter Cloudflare) oder über ein VPN (z. B. WireGuard, Tailscale) – dort oft per HTTP an eine private IP
  oder einen internen Namen. Da jeder die App nutzen kann, verbinden sich auch fremde Instanzen mit älteren
  Server-Versionen.
- Release-Tags des Servers heißen `vX.Y.Z` (z. B. `v0.3.2`); `GET /v1/version` liefert `version` (+ `commit`),
  ohne Anmeldung.
- Poster kommen als `posterPath` und werden wie im Web von `https://image.tmdb.org/t/p/w{breite}{path}` geladen.
- TMDB verlangt einen Quellenhinweis (das Web hat ihn im Footer).
- UI-Sprache Deutsch; Bezeichner und Kommentare im Code englisch (wie im Server-Repo).

## Ansätze

### Datenhaltung [entschieden: A]
Ausgangslage: kein Offline, der Server liefert nach jeder Änderung den neuen Stand, Filter/Sortierung/Paging macht
der Server, und es gibt keine Änderungsabfrage. Eine lokale Datenbank wäre also nur eine zweite Kopie, die man
nachbauen und aktuell halten müsste.

| Ansatz | So funktioniert es | Abwägung | Ergebnis |
|---|---|---|---|
| **A: Ohne Datenbank** | Die erzeugten API-Typen liegen in `@Observable`-Stores im Speicher; Poster im Bild-Cache; die Startseite wird als JSON-Datei für den nächsten Kaltstart gemerkt | Am wenigsten Code, nie veraltet, keine Migrationen, keine zweite Modellschicht. Nach Kaltstart lädt alles außer der Startseite kurz | **gewählt** |
| B: SwiftData als Zwischenspeicher | API-Antworten werden in `@Model`-Klassen gespiegelt, Bildschirme lesen per `@Query` | Bildschirme sofort gefüllt und automatisch konsistent; aber zweite Modellschicht für 88 Typen plus Umwandlung, auf dem Server Gelöschtes muss lokal selbst aufgeräumt werden | verworfen |
| C: Core Data als Zwischenspeicher | wie B mit Core Data | wie B, mit mehr Code und mühsamerer Swift-6-Nebenläufigkeit | verworfen |

**Core Data vs. SwiftData** (für den Fall, dass später doch ein Zwischenspeicher kommt)

| | Core Data | SwiftData |
|---|---|---|
| Reife | seit 2005, gut dokumentiert, kaum Überraschungen | seit iOS 17; frühe Versionen fehlerhaft, ab iOS 18/26 deutlich stabiler |
| Code-Menge | Modell-Editor, `NSManagedObject`-Unterklassen, `NSPredicate` als Text | Modelle als Swift-Klassen (`@Model`), typgeprüftes `#Predicate` |
| SwiftUI | `@FetchRequest`, `@SectionedFetchRequest` | `@Query`, nahtlos |
| Swift 6 (strikte Nebenläufigkeit) | mühsam: Objekte nicht `Sendable`, alles in `perform`-Blöcken | `@ModelActor` und `PersistentIdentifier` passen besser; Modelle aber auch nicht `Sendable` |
| Große Datenmengen | Batch-Insert/-Delete, `NSFetchedResultsController`, gute Werkzeuge | langsamer bei vielen Tausend Datensätzen, nur einfaches Massen-Löschen, Abfragen schwer zu durchschauen |
| Schema-Änderungen | ausgereift (leichte und schrittweise Migration) | `VersionedSchema` + Migrationsplan, weniger erprobt |
| Kontrolle/Fehlersuche | volle Kontrolle (Batches, Faults, SQL-Log) | vieles verborgen, Fehler schwerer zu finden |

**Empfehlung:** Die Stärken von Core Data (Massendaten, Kontrolle, sichere Migrationen) braucht ein Zwischenspeicher
nicht, den man jederzeit wegwerfen und neu füllen kann – also SwiftData vor Core Data. Weil die App aber nichts
lokal braucht, was der Server nicht ohnehin liefert, gilt Ansatz A. Der Datenzugriff steckt in Stores; ein
SwiftData-Cache ließe sich später einziehen, ohne Bildschirme zu ändern.

### API-Client [Entscheidung des Entwurfs]
| Ansatz | Abwägung | Ergebnis |
|---|---|---|
| **Erzeugter Client aus demselben `openapi.yaml`**, als Library-Target `WatchSwiftyClient` im Server-Repo, per SwiftPM eingebunden | App und Server können nicht auseinanderlaufen; ein Server-Tag legt fest, wogegen die App gebaut ist; war in der API-Spec schon als „Später“ vorgesehen | **gewählt** |
| Kopie der `openapi.yaml` im App-Repo, Generator dort | kein Eingriff ins Server-Repo; Kopie veraltet unbemerkt | verworfen |
| Handgeschriebener Client mit `URLSession` + `Codable` | keine Abhängigkeiten; ~80 Operationen von Hand, Abweichungen erst zur Laufzeit sichtbar | verworfen |

## Änderungen am Server
Nur ein neues Produkt, keine Verhaltensänderung:
- Target `WatchSwiftyClient` (Library-Produkt): `generate: [types, client]`, **`accessModifier: public`** (wird aus
  einem anderen Paket genutzt), Abhängigkeit nur `OpenAPIRuntime` – kein Vapor. Das Target nutzt dieselbe
  `openapi.yaml` wie `WatchSwiftyAPI` (Symlink im Target-Ordner; Builder prüft, dass das Generator-Plugin ihn
  liest).
- `Package.swift`: `platforms` um `.iOS(.v26)` ergänzen; Server-Build, Docker-Image und CI bleiben unverändert
  (das neue Target wird in CI mitgebaut, also auch unter Linux kompiliert).
- **Offene Enums nur im Client** [Entscheidung des Entwurfs]: Der Generator erzeugt geschlossene Swift-Enums – ein
  neuer Wert vom Server würde in älteren Apps die ganze Antwort unlesbar machen (Anti-Ziel). Das Spec bleibt
  unverändert (sonst ändern sich auch die Server-Typen, und der Server würde unbekannte Werte nicht mehr
  ablehnen – `updateWatch` würde z. B. stillschweigend ohne Dienst speichern). Stattdessen ersetzt die
  Generator-Konfiguration **nur des Clients** wachsende Schemas per `typeOverrides` durch eigene offene Typen im
  Target `WatchSwiftyClient` (z. B. `struct Service: RawRepresentable, Codable` mit bekannten Konstanten; unbekannte
  Werte bleiben als Text erhalten). Mindestens `Service`; der Builder prüft die übrigen `enum:`-Stellen, die in
  Antworten vorkommen. Unbekannte Werte zeigt die App neutral an (z. B. „Anderer Dienst“) und schickt sie beim
  Bearbeiten unverändert zurück (`updateWatch` ersetzt Datum *und* Dienst – sonst ginge der Dienst verloren).
  Steckt ein wachsendes Enum inline in einem Schema, wird es im Spec als benanntes Schema ausgelagert; im Server
  ändern sich dadurch nur Typnamen, kein Verhalten.
- **Versionen und Pinning** [Entscheidung des Entwurfs]: Während der Entwicklung bindet die App `WatchSwiftyClient`
  über den Branch `beta` ein (Commit-Pin in `Package.resolved`), damit API-Korrekturen aus den App-Phasen kein
  öffentliches Release brauchen. Vor dem ersten TestFlight-Build erscheint ein Server-Release (`beta` → `main`,
  `VERSION` passend erhöht), das `WatchSwiftyClient` enthält; ab dann pinnt die App auf dessen Tag.

## Was man sieht

### Erster Start
1. **Server:** Feld „Server-Adresse“ (z. B. `https://watch.example.de`), „Weiter“ prüft `GET /api/v1/version`.
   Fehlermeldungen: „Unter dieser Adresse antwortet kein WatchSwifty-Server.“ / „Der Server ist zu alt (0.3.2).
   Diese App braucht mindestens 0.4.0.“ Feld „Gerätename“, vorbelegt mit dem Modellnamen (iOS gibt den
   vom Nutzer vergebenen Namen ohne Sonder-Berechtigung nicht heraus).
2. **Anmelden:** öffnet das Browser-Fenster (`ASWebAuthenticationSession`) mit `/api/auth/authorize`. Dort läuft
   der normale Login (Passwort oder SSO, inkl. Passwort vergessen, Einladung) und die Bestätigung „Verbinden“.
   Die Sitzung teilt Cookies mit Safari (nicht `prefersEphemeralWebBrowserSession`), sodass bei bestehender
   Web-Anmeldung ein Tipp auf „Verbinden“ reicht.
3. App tauscht den Code gegen das Token und zeigt die Startseite.

### Navigation
```
┌ Start ───────────────────────────┐
│ Weiterschauen                    │
│ [Poster] Severance   S2E4   [✓]  │  ← Knopf oder Wischen: nächste Folge gesehen
│ [Poster] Andor       S1E7   [✓]  │
│ Neue Folgen  ·  Demnächst        │
└──────────────────────────────────┘
  Start  Bibliothek  Verlauf  Mehr     🔍
```
Tab-Leiste: **Start · Bibliothek · Verlauf · Mehr** plus **Suche** als eigener Such-Tab (iOS-26-Stil).

### Bildschirme (Inhalt jeweils wie im Web, Spec `2026-11-07-watchswifty-design.md` §5)
- **Start:** Weiterschauen-Karten (Poster, Titel, nächste Folge, verbleibende Folgen, „Ansehen bei …“-Link).
  Wischaktion und Knopf „Gesehen“ markieren die nächste Folge (`markNextEpisode`); ist die Serie aufgeholt
  (`204`), verschwindet die Karte. „Ältere anzeigen“ (`all=true`, mit `olderCount`). Abschnitte „Neue Folgen“
  (Ausblenden = `dismissNewEpisodes`) und „Demnächst“ (`getNotes`).
- **Suche:** Suchfeld mit Verzögerung (~300 ms) → Treffer (Serien und Filme) → Detail.
- **Serie:** Kopf mit Poster, Titel, Bewertung, Kommentar, Links wie im Web. „Ansehen bei …“ gibt es – wie im
  Web – nur auf den Weiterschauen-Karten (`SeriesDetail`/`MovieDetail` haben kein `watchLink`; die App baut den
  Link nicht selbst). Menü: Beobachten,
  Ausblenden, „Alles gesehen“. Staffeln als Abschnitte mit Staffelkommentar und „Staffel gesehen“. Pro Folge:
  Wischaktionen „Gesehen“ / „Bis hier gesehen“, Kontextmenü mit „Gesehen am …“ (Blatt mit Datum, Dienst,
  „Erneut gesehen“) und „Nicht gesehen“. Ein Tipp auf eine gesehene Folge zeigt ihre Sichtungen.
- **Film:** Kopf wie Serie; „Gesehen“ (Blatt mit Datum, Dienst, erneut), „Nicht gesehen“, Bewertung, Kommentar.
- **Verlauf:** Sichtungen seitenweise (Nachladen am Listenende), Wischen löscht (mit Bestätigung), Tippen öffnet
  Bearbeiten (Datum, Dienst).
- **Bibliothek:** Filter und Sortierung als Menü in der Navigationsleiste (Werte wie im Web), Raster oder Liste
  mit Postern.
- **Mehr:**
  - **Statistik:** Jahr wählbar; Diagramme mit Swift Charts, Inhalte wie im Web.
  - **Importe:** Netflix-Import und Filmliste. CSV-Auswahl über die Dateien-App (`.fileImporter`), Upload,
    Fortschritt (Abfrage alle ~2 s, solange der Bildschirm sichtbar ist und der Import läuft), Listen „Zu prüfen“
    und „Nicht zugeordnet“, Zuordnungen mit Filter, Aktionen Annehmen / Ändern (mit Suche) / Ignorieren /
    Zurücksetzen, Zeilen zuordnen/ignorieren, Filmliste Annehmen/Suchen/Überspringen, „Erneut versuchen“.
  - **Konto:** Benutzername, Passwort ändern (nur bei `hasPassword` und `passwordLogin`), E-Mail, TMDB-Token
    (setzen, prüfen, entfernen; Anzeige letzte 4 Zeichen), Geräte (Liste, einzeln abmelden, dieses Gerät
    markiert), beobachtete Serien.
  - **Verwaltung** (nur bei `isAdmin`): Benutzer (anlegen, Einladung erneut senden, Passwort zurücksetzen,
    SSO-Verknüpfungslink, Admin-Recht, löschen – nie das eigene Konto, wie die API), System (Version,
    Update-Prüfung an/aus, „Jetzt prüfen“), SSO-Einstellungen (anzeigen, speichern, testen, löschen,
    Passwort-Login an/aus), Mail-Einstellungen (anzeigen, speichern, Testmail, löschen).
  - **Über:** App- und Server-Version, TMDB-Quellenhinweis mit Logo, Link zur Weboberfläche.
  - **Server:** Adresse anzeigen, „Abmelden“ (widerruft das Token per `DELETE /v1/auth/token`, löscht es aus dem
    Schlüsselbund, zurück zum ersten Start).

### Web-Funktionen ohne API (öffnen die Weboberfläche in Safari)
Einige Konto-Funktionen laufen bewusst nur im Browser, weil sie einen Browser-Ablauf brauchen:
- **Token für Skripte erstellen** (Konto → Geräte; bei SSO-Konten mit Bestätigung beim Provider).
- **Konto mit SSO verknüpfen** (Konto → „Mit {Provider} verknüpfen“).
Die App zeigt dafür einen Eintrag „Im Browser öffnen“, der `<server>/account` in Safari öffnet. Damit ist die
Funktion erreichbar, ohne die API zu erweitern (Nicht-Ziel).

### Zustände und Fehler
- **Laden:** erster Aufruf eines Bildschirms zeigt Platzhalter (`.redacted(reason: .placeholder)`), später bleibt
  der alte Inhalt stehen, bis der neue da ist.
- **Fehler der API:** `message` erscheint als Hinweis (Alert bei Aktionen, Inline-Hinweis bei Bildschirmen mit
  „Erneut versuchen“).
- **`missingTMDBToken`:** Hinweis mit Knopf „TMDB-Token eintragen“ → Konto.
- **`401` (`unauthorized`/`tokenExpired`):** App verwirft das Token und zeigt „Bitte erneut verbinden“ mit
  „Anmelden“ (Browser-Fenster wie beim ersten Start; Server-Adresse bleibt).
- **Keine Verbindung / Zeitüberschreitung:** Hinweis „Server nicht erreichbar“ mit „Erneut versuchen“; keine
  Bearbeitung veralteter Daten.
- **Server zu alt** (beim Start geprüft): Vollbild-Hinweis mit beiden Versionen.

## Technik

### Projekt
- Eigenes Repo `watchswifty-ios`, Xcode-Projekt, eine App-Target, Bundle-ID `dev.patmei.watchswifty`, URL-Scheme
  `dev.patmei.watchswifty` (für den Login-Rücksprung).
- Mindestversion **iOS 26** [Entscheidung des Entwurfs: aktuelle und vorige Hauptversion; Such-Tab und Design
  von iOS 26], nur iPhone.
- Swift 6, strikte Nebenläufigkeit; Abhängigkeiten nur `WatchSwiftyClient` (Server-Repo),
  `swift-openapi-runtime`, `swift-openapi-urlsession`.
- Sprache: String Catalog mit Deutsch als einziger Sprache.

### Schichten
```
Views (SwiftUI)
   │  lesen/rufen
Stores (@MainActor @Observable, je Bereich)
   │  any APIProtocol
WatchSwiftyClient (erzeugt) ── URLSessionTransport + AuthMiddleware
```
- **Stores** je Bereich (`HomeStore`, `SearchStore`, `SeriesStore` je geöffneter Serie, `MovieStore`,
  `HistoryStore`, `LibraryStore`, `StatsStore`, `AccountStore`, `NetflixImportStore`, `FilmListStore`,
  `AdminStore`, …) halten die erzeugten API-Typen direkt – keine eigene Modellschicht. Sie hängen nur von
  `any APIProtocol` ab, damit Tests einen Fake einsetzen können.
- **Nach einer Änderung** übernimmt der Store den Stand aus der Antwort. Damit andere Bildschirme nicht veralten
  (Anti-Ziel), zählt ein zentrales `AppModel` einen `changeVersion` hoch; jeder Store merkt sich die Version seines
  letzten Ladens und lädt beim nächsten Erscheinen neu, wenn sie sich geändert hat.
- **Neu laden:** Pull-to-Refresh überall; beim Zurückkehren in die App (`scenePhase == .active`) lädt der
  sichtbare Bildschirm neu.
- **Startseite beim Kaltstart:** die letzte `ContinueWatching`-Antwort liegt als JSON im Caches-Ordner, wird sofort
  angezeigt und gleich danach ersetzt. Sie enthält nur Titel, Folgen und Poster-Pfade.
- **Poster:** `URLCache` mit größerem Plattenspeicher (Vorschlag 200 MB); Breite wie im Web nach Anzeigegröße ×
  Bildschirmskalierung.

### Anmeldung und Token
- **PKCE:** `code_verifier` 32 Zufallsbytes Base64URL, `code_challenge` = SHA-256 (CryptoKit), `state` zufällig und
  beim Rücksprung geprüft.
- **Browser-Fenster:** `ASWebAuthenticationSession` mit Callback `.customScheme("dev.patmei.watchswifty")`;
  `error=access_denied` → zurück zum Startbildschirm ohne Fehlermeldung.
- **Token:** im Schlüsselbund (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, kein iCloud-Sync), zusammen mit
  `expiresAt`. Server-Adresse und Gerätename in `UserDefaults`.
- **AuthMiddleware** (`ClientMiddleware`): setzt `Authorization: Bearer …`, erkennt `401` und meldet dem `AppModel`
  „abgemeldet“. Das Token erscheint nie in Logs.
- **Ablauf vorhersehen** [Vorschlag]: Läuft das Token in weniger als 7 Tagen ab, zeigt „Mehr“ einen Hinweis
  „Verbindung läuft am … ab – jetzt erneuern“ (neuer Browser-Login, altes Token wird danach widerrufen).

### Netzwerk
- **HTTPS und VPN** [Entscheidung des Entwurfs]: Über ein VPN ist der Tunnel verschlüsselt, der Server aber oft
  nur per HTTP an einer privaten IP oder einem internen Namen erreichbar. App Transport Security lässt deshalb HTTP
  zu (`NSAllowsArbitraryLoads`, Begründung für Apples Prüfung: „selbst gehosteter Server, im VPN oft ohne
  Zertifikat“), **die App selbst** erlaubt `http://` aber nur für private Ziele: IPv4 `10/8`, `172.16/12`,
  `192.168/16`, `100.64/10` (Tailscale), IPv6 `fc00::/7`, Namen ohne Punkt sowie `.local`, `.lan`, `.home.arpa`,
  `.internal`. Jede andere `http://`-Adresse lehnt die Server-Eingabe ab: „Bitte eine https://-Adresse verwenden –
  sonst wäre die Anmeldung unverschlüsselt.“ Bei einer erlaubten `http://`-Adresse zeigt sie den Hinweis „Nur im
  Heimnetz oder VPN verwenden“. Ohne Schema wird `https://` angenommen. `NSLocalNetworkUsageDescription` erklärt
  die Abfrage „Lokales Netzwerk“ für Adressen im Heimnetz. Tailscale-Namen (`*.ts.net`) haben ein öffentliches
  Zertifikat und laufen über HTTPS.
- **Versionsprüfung:** Die Mindest-Server-Version ist eine Konstante in der App (`minimumServerVersion`), gesetzt
  auf das erste Server-Release mit `WatchSwiftyClient` und bei jedem Wechsel des Client-Pins mitgezogen.
  `GET /v1/version` beim ersten Start und bei jedem Kaltstart; Beta-Versionen (`0.4.0-beta`) zählen wie die
  Zahl davor; nicht lesbare Versionen (z. B. `dev` auf dem Vorschau-Server) gelten als passend.
- **Uploads:** CSV als `multipart/form-data` über den erzeugten Client (Netflix max. 10 MB, Filmliste max. 2 MB –
  die App prüft die Größe vor dem Upload).
- **„Ansehen bei …“:** `watchLink.url` per `openURL` (öffnet bei Universal Links die Dienst-App).

## Qualität und Tests
- **Swift Testing** im App-Projekt:
  - Stores gegen einen Fake-`APIProtocol` (Laden, Änderungen übernehmen, `changeVersion`, `204` beim Abhaken
    der letzten Folge, Fehlerabbildung inkl. `missingTMDBToken` und `401`).
  - PKCE und `state`-Prüfung, Auswertung der Rücksprung-URL (`code`, `error`, falscher `state`).
  - Versionsvergleich (inkl. Beta), offene Enums mit unbekanntem Wert.
- **Previews** für jeden Bildschirm mit Fake-Daten (Server nicht nötig).
- Keine UI-Tests in v1 [Entscheidung des Entwurfs]; Ende-zu-Ende-Prüfung von Hand gegen den Vorschau-Server
  (`.claude/launch.json` im Server-Repo).
- Server-Repo: das neue Target baut in CI mit; bestehende API-Tests bleiben unverändert grün.

## Verteilung (TestFlight)
- Bezahltes Apple-Entwicklerkonto, App in App Store Connect mit Bundle-ID `dev.patmei.watchswifty`.
- **Externe Tester über einen öffentlichen Link** (bis 10.000): jeder, der will – auch Betreiber anderer
  WatchSwifty-Instanzen. Der erste Build jeder App-Version durchläuft Apples Beta-Prüfung; TestFlight-Builds laufen
  nach 90 Tagen ab, es braucht also regelmäßig neue Builds.
- **Demo-Instanz für die Prüfung** [Entscheidung des Entwurfs]: eine eigene WatchSwifty-Instanz (eigener Container,
  eigene Datenbank, öffentlich per HTTPS), **nie die echte**, damit Prüfer keine Daten echter Benutzer sehen. Darin
  ein Testkonto mit Admin-Recht (die Prüfer sollen auch die Verwaltung sehen können; auf der Demo-Instanz schadet
  das nicht), hinterlegtem TMDB-Token und Beispieldaten (z. B. aus `Tests/AppTests/Fixtures/netflix-sample.csv`
  importiert). Mail-Versand ist dort aus. Server-Adresse, Benutzername und Passwort stehen in den
  Testinformationen von App Store Connect.
- **Testinformationen:** Beschreibung (was WatchSwifty ist, dass ein eigener Server nötig ist), Feedback-Adresse,
  Anmeldedaten der Demo-Instanz, Hinweis zum Login im Browser-Fenster; weitere Pflichtfelder laut App Store
  Connect (z. B. Datenschutzerklärung) – eine kurze Datenschutzerklärung liegt öffentlich im Server-Repo.
- Builds per „Archive“ in Xcode und Upload; Build-Nummer fortlaufend, Versionsnummer der App unabhängig von der
  Server-Version.
- Pflichtangaben: App-Symbol, Exportkonformität (nur Standard-Verschlüsselung über HTTPS), Datenschutz-Manifest
  (keine Tracking-Daten, keine Weitergabe; Daten gehen nur an den eigenen Server und TMDB-Bilder).
- Die README des Servers nennt den TestFlight-Link und die Mindest-Server-Version.

## Umsetzung in Phasen (für den Plan)
1. **Server:** Target `WatchSwiftyClient` mit offenen Enums per `typeOverrides`, auf `beta` (Release erst in
   Phase 7).
2. **Grundgerüst:** Xcode-Projekt, Server-Eingabe, Versionsprüfung, Login/Abmelden, Schlüsselbund,
   AuthMiddleware, Fehlerdarstellung, Tab-Leiste, „Mehr → Über/Server“.
3. **Kern:** Start, Suche, Serie, Film (Abhaken, Bewertung, Kommentare, Beobachten, Ausblenden).
4. **Verlauf, Bibliothek, Statistik, Konto.**
5. **Importe:** Netflix-Import und Filmliste.
6. **Verwaltung:** Benutzer, System, SSO, Mail.
7. **TestFlight:** Server-Release mit `WatchSwiftyClient`, App auf dessen Tag pinnen, Demo-Instanz,
   App-Store-Connect-Eintrag, Symbol, Datenschutz-Manifest und -erklärung, Beta-Prüfung, öffentlicher Link,
   README.
Jede Phase ist für sich lauffähig und getestet.

## Dem Builder überlassen
Ordner- und Dateistruktur im App-Projekt; Namen der Stores und Views; genaue Platzhalter- und Ladeanimationen;
Raster- oder Listenansicht der Bibliothek als Standard; App-Symbol (Vorschlag: aus `Public/favicon.svg`
abgeleitet); Diagrammtypen der Statistik; Größe des Bild-Caches; ob die Symlink-Lösung für die zweite
Generator-Konfiguration funktioniert oder eine andere Lösung nötig ist (Bedingung: eine einzige `openapi.yaml`).

## [Vorschlag] Später
- SwiftData-Zwischenspeicher hinter den Stores, falls die Ladezeiten stören (s. „Ansätze“).
- Widget „Weiterschauen“, App Intents („Nächste Folge von … gesehen“), Push bei neuen Folgen (bräuchte
  Server-Erweiterung).
- iPad-Layout mit `NavigationSplitView`.
- App Store (die Demo-Instanz aus der TestFlight-Prüfung lässt sich dafür weiterverwenden).
- Builds über Xcode Cloud oder GitHub Actions.
