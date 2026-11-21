# WatchSwifty – „Später ansehen“, Streamingdienste und Verfügbarkeit (Design)

Stand: 2026-11-21 · Status: zur Freigabe (Fragen des Gutachters eingearbeitet) · Ergänzt `2026-11-11-notifications-design.md` (Tages-Digest, Kanäle) und
`2026-11-13-tmdb-refresh-design.md` (Cache-Regel)

**Warum:** Der Nutzer merkt sich Filme und Serien, die er sehen will, aber nicht dort sieht, wo er Abos hat. Er will
eine Merkliste („Später ansehen“) und eine Nachricht, sobald ein Titel daraus bei einem seiner Streamingdienste im Abo
läuft – ohne selbst nachzusehen. Außerdem soll jede Serie und jeder Film zeigen, wo er gerade läuft.

## Entschieden (vom Nutzer)

1. **Aktive Streamingdienste** werden unter **Konto** gepflegt.
2. **Liste „Später ansehen“** mit eigenem Menüpunkt; in der Suche (und auf der Detailseite) fügt man Titel hinzu.
3. **Täglich** wird für jeden Eintrag der Liste die Verfügbarkeit abgefragt; taucht ein Titel neu bei einem der
   eigenen Dienste **im Abo** auf, gibt es eine Nachricht per Mail oder Webhook.
4. **Detailseite** zeigt, wo der Titel läuft. **Kein Knopf zum Abrufen** – das läuft automatisch (siehe 6.).
5. **Gespeicherte Verfügbarkeitsdaten höchstens 30 Tage** ohne Aktualisierung.
6. **Datenquelle: TMDB „Watch Providers“ (Daten von JustWatch)** statt Watchmode (siehe Ansätze).
7. **Länderspezifisch:** Land pro Nutzer unter **Konto**, Standard **DE**.
8. **Automatisch entfernen:** Ein Titel verlässt die Liste, sobald eine Sichtung erfasst wird (Film gesehen bzw. erste
   Folge – egal auf welchem Weg).
9. **Leihen/Kaufen** wird auf der Detailseite eingeklappt gezeigt und löst **nie** eine Nachricht aus.
10. **Ansatz B:** eigene Tabelle `watch_later` statt eines Feldes an `user_titles` (siehe Ansätze).
11. **Darstellung** wie in den Entwürfen (siehe 5.): Abo-Dienste getrennt in „In deinen Abos“ (grüner Rand + ✓) und
    „Weitere Abos“; Quellenhinweis verlinkt auf JustWatch, kein zusätzlicher TMDB-Link im Block.

## Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**
- Eine Merkliste, die sich von selbst leert, wenn man anfängt zu schauen.
- Eine Nachricht, sobald ein gemerkter Titel bei einem eigenen Abo-Dienst verfügbar wird – einmal pro Titel und Dienst.
- Auf jeder Detailseite: wo läuft das gerade (Abo, gratis, eingeklappt Leihen/Kaufen), mit Datenstand.
- Web und App-API können dasselbe (gleiche Services).

**Nicht-Ziele**
- Oberfläche in der iOS-App (die API-Endpunkte gibt es, die App nutzt sie vorerst nicht).
- Direkte Links zum Titel beim Dienst (die API liefert keine; vorhandene `watchLink`-Suchlinks werden genutzt).
- Verfügbarkeit pro Staffel, Preise, Qualität (HD/4K).
- Nachrichten für Leihen/Kaufen, für Titel außerhalb der Liste oder für „Titel verschwindet vom Dienst“.
- Watchmode oder andere kostenpflichtige Quellen.

**Anti-Ziele** (wäre ein Fehlschlag, auch wenn es technisch läuft)
- Bestehendes Verhalten ändert sich nebenbei (Bibliothek, Suche, Folgen-Abgleich, Cache-Regel).
- Nachrichten für Titel, die beim Hinzufügen schon beim eigenen Dienst liefen, oder doppelte Nachrichten.
- Die Detailseite wartet beim Laden auf TMDB.
- Verfügbarkeitsdaten ohne Quellenhinweis auf JustWatch (TMDB entzieht sonst den API-Zugang).

## Ansätze

### Datenquelle

| | TMDB Watch Providers (gewählt) | Watchmode (verworfen) |
|---|---|---|
| Limit | kein Monatslimit, nur ~40–50 Anfragen/s (TMDB) | 2.500 Credits/Monat (Gratis), 1 Credit pro Abfrage mit Watchmode-ID, 2 mit TMDB-ID → bei täglicher Prüfung ≈ 80 Titel insgesamt pro Schlüssel |
| Zugang | vorhandener TMDB-Token je Nutzer, gemeinsamer `RateLimiter` | eigener Schlüssel nötig, nicht übertragbar; Gratis-Tarif nur nicht-kommerziell, 3 Länder, keine Changes-Endpunkte |
| Cache | TMDB: 6 Monate (wir halten freiwillig 30 Tage ein) | Gratis: 30 Tage |
| Links | nur Link auf die TMDB-Seite des Titels | direkte Links zum Titel beim Dienst |
| Pflicht | Quelle „JustWatch“ nennen | Link auf Watchmode.com |

JustWatch direkt geht nicht: die Partner-API gibt es nur mit Vertrag; inoffizielle Zugriffe sind nicht freigegeben.

**Endpunkte:** `GET /movie/{id}/watch/providers`, `GET /tv/{id}/watch/providers` (Antwort enthält alle Länder auf einmal,
je Land `link`, `flatrate`, `free`, `ads`, `rent`, `buy` mit `provider_id`, `provider_name`, `logo_path`,
`display_priority`); `GET /watch/providers/movie|tv?watch_region=XX` (Dienste eines Landes); `GET /watch/providers/regions`
(Länder).

### Speicherung der Liste

- **A – Feld `watch_later_at` an `user_titles`:** verworfen. Eine Zeile in `user_titles` bedeutet heute an mehreren
  Stellen „in der Bibliothek“: die Suche zeigte gemerkte Titel als „in der Bibliothek“ mit „0/62 Folgen“
  (`SearchService.inLibrary`), `seriesDueForRefresh` holte jede gemerkte Serie täglich neu, und beim Entfernen bliebe
  eine leere Zeile, die den Titel für immer im Cache hält.
- **B – eigene Tabelle `watch_later` (gewählt):** bestehende Abfragen merken nichts davon. Nötig sind gezielte
  Ergänzungen in `titleUsers`, `usesTitle` und `IsolationTests`; Entfernen löscht die Zeile, danach gilt die normale
  Cache-Regel.
- Verworfen: Verfügbarkeit als JSON an `titles` – der Vergleich „neu bei Netflix in DE“ wäre umständlich.

Alle Migrationen sind additiv (neue Tabellen, eine neue Spalte mit NULL-Standard an `users`), ein Downgrade auf die
Vorversion funktioniert. Die API bekommt nur neue Endpunkte und optionale Felder; ältere iOS-Apps laufen weiter.

## 1. Datenmodell

Neue Migrationen am Ende der Liste in `configure.swift`.

**`watch_later`** – Eintrag der Liste
- `id`, `user_id` (FK users, cascade), `title_id` (FK titles, cascade), `added_at` (Datum/Zeit), `baselined` (Bool,
  siehe 4.3). Eindeutig: (`user_id`, `title_id`).

**`title_availability`** – Stand der Abfrage pro Titel
- `title_id` (eindeutig, FK titles, cascade), `fetched_at`, `regions` (die bei dieser Abfrage gespeicherten Länder,
  z. B. `DE,AT`), `tmdb_link` (TMDB-Seite mit Angeboten, optional). Ist das Land eines Nutzers nicht in `regions`,
  gilt der Stand für ihn als **fehlend** (Detailseite lädt nach, Liste zeigt „noch nicht abgefragt“).

**`title_providers`** – ein Angebot
- `id`, `title_id` (FK titles, cascade), `region` (2 Buchstaben), `provider_id` (Int, TMDB), `provider_name`,
  `logo_path` (optional), `kind` (`flatrate` | `free` | `ads` | `rent` | `buy`), `display_priority` (Int).
- Index auf (`title_id`, `region`). Gespeichert werden **nur die Länder, die mindestens ein Nutzer eingestellt hat**
  (distinct `users.watch_region`, nil zählt als `DE`) – TMDB liefert sonst ~50 Länder pro Titel.

**`user_streaming_services`** – aktive Dienste eines Nutzers
- `user_id` (FK users, cascade), `provider_id` (Int). Eindeutig: (`user_id`, `provider_id`). Namen und Logos kommen
  aus `title_providers` bzw. der Live-Liste in **Konto**, sie werden hier nicht gespeichert.

**`availability_notices`** – bekannte Angebote pro Nutzer (Entscheidung des Entwicklers nach Review)
- `user_id` (FK users, cascade), `title_id` (FK titles, cascade), `provider_id`, `noticed_at`, `state`:
  - `baseline` – lief schon beim Hinzufügen bzw. beim Ändern von Diensten/Land/Schalter (nie gemeldet, nie „neu“),
  - `skipped` – neu aufgetaucht, Schalter aus (keine Nachricht, aber „neu seit“ auf der Liste),
  - `pending` – neu aufgetaucht, Schalter an, wartet auf Versand,
  - `sent` – verschickt.
- Eindeutig: (`user_id`, `title_id`, `provider_id`).

**`users`** – neue Spalten: `watch_region` (String, optional; nil = `DE`), `notify_available` (Bool, optional;
nil = aus).

**Cache-Regel (`CatalogMaintenance`):** `watch_later` **zählt** als Nutzung → in `titleUsers` und `usesTitle`
aufnehmen. `title_availability`, `title_providers` und `availability_notices` zählen **nicht** (wie
`episode_notices`): sie dürfen keinen Titel im Cache halten. Wird ein Titel gelöscht, verschwinden sie per cascade.

## 2. Streamingdienste unter „Konto“

Neuer Abschnitt **Streamingdienste** auf der Kontoseite:
- **Land:** Auswahl aus `GET /watch/providers/regions` (deutsche Namen über `language=de-DE`), Standard Deutschland.
- **Dienste:** Checkboxen mit Logo und Name, Vereinigung von `/watch/providers/movie` und `/tv` für das Land,
  sortiert nach `display_priority` und dann Name. Die Liste wird beim Öffnen live mit dem Token des Nutzers geholt
  (keine Speicherung).
- **Speichern** ersetzt die Dienste des Nutzers; ein Landwechsel entfernt Dienste, die es im neuen Land nicht gibt,
  nicht automatisch (sie zeigen dann einfach nichts an).
- **Ohne TMDB-Token:** Hinweis „Für die Auswahl der Dienste wird ein TMDB-Token benötigt“ mit Verweis auf das Feld
  darüber; bereits gewählte Dienste bleiben gespeichert.
- Ändern sich Dienste oder Land, werden alle Einträge des Nutzers auf `baselined = false` gesetzt (siehe 4.3), damit
  Titel, die beim neuen Dienst schon laufen, keine Nachricht auslösen.
- **Landwechsel:** Titel der eigenen Liste, deren `title_availability.regions` das neue Land nicht enthält, werden im
  Hintergrund sofort mit dem Token des Nutzers abgefragt (eine Anfrage pro Eintrag, gedrosselt über den
  `RateLimiter`; Entscheidung des Entwicklers nach Review). Bis dahin zeigt die Liste „noch nicht abgefragt“.

`StreamingService` (fester Enum für Sichtungen: wo man etwas gesehen hat) bleibt unverändert. Für die Suchlinks auf den
Anbieter-Chips gibt es eine Zuordnung TMDB-`provider_id` → `StreamingService` (z. B. 8 → Netflix, 9 und 119 → Prime
Video, 337 → Disney+, 350 → Apple TV+, 30 → WOW, 531 → Paramount+, HBO Max); die genauen IDs prüft der Entwickler gegen
`/watch/providers/*?watch_region=DE`.

## 3. Liste „Später ansehen“

### 3.1 Hinzufügen und Entfernen
- **Suche:** Jedes Ergebnis bekommt rechts einen Knopf **+ Später** bzw. **✓ Später**, wenn der Titel schon auf der
  Liste steht. Das Ergebnis ist heute ein einziger Link (`a.card.search-result`); Knopf und Link werden Geschwister in
  der Karte (kein Knopf im Link). Klick → `hx-post` und Austausch nur des Knopfes.
- **Detailseite (Serie und Film):** Umschalter **Später ansehen** / **✓ Später ansehen** in `title-actions`, neben
  **Beobachten** und **Ausblenden** (Muster `FollowToggle`).
- **Hinzufügen** legt den Titel bei Bedarf im Katalog an (`CatalogService.title(kind:tmdbID:)`, wie beim Öffnen der
  Detailseite), legt den Eintrag mit `baselined = false` an und holt sofort die Verfügbarkeit (4.1) mit dem Token des
  Nutzers. Gelingt das, wird gleich die Ausgangslage erfasst (4.3). Schlägt die Abfrage fehl, bleibt der Eintrag
  trotzdem bestehen; die Ausgangslage folgt im nächsten Tageslauf.
- Auch Titel mit Sichtungen dürfen auf die Liste; sie verlassen sie bei der nächsten neuen Sichtung.
- **Entfernen** (Knopf auf der Liste, Umschalter, automatisch) löscht den Eintrag und die `availability_notices` des
  Nutzers für diesen Titel.
- **Automatisch entfernen:** Eine neu angelegte Sichtung (`Watch`) für (Nutzer, Titel) entfernt den Eintrag – auch
  erneutes Ansehen. **Manuelle Sichtungen** (Web/API, egal mit welchem Datum oder ohne Datum) entfernen immer.
  **Importierte Sichtungen** (Netflix-Import inkl. nachträglichem Matching durch `MatchingWorker`, Mappings,
  Standard-Import) entfernen nur, wenn ihr Datum am oder nach dem Tag von `added_at` liegt – ein Import alter
  Verläufe soll die Liste nicht leeren (Entscheidung des Entwicklers nach Review). Betroffene Stellen: alle `Watch(...)`-Anlagen in `WatchService` (`markEpisode`, `markMovie`,
  `markSeason`/`markSeries`/`markUpTo` über `markUndated`/`markRound`, `recordImportedWatch` für Netflix-Import und
  Mappings) **und** `StandardImporter` (legt Sichtungen direkt an). Ein gemeinsamer Aufruf im `WatchLaterService`
  (z. B. `removeAfterWatch(userID:titleID:day:origin:)`) hält das an einer Stelle.

### 3.2 Seite „Später ansehen“ (`/watch-later`, Menüpunkt zwischen **Bibliothek** und **Statistik**)
Wie im Entwurf `watch-later-list.html`:
- Filter **Alle / Serien / Filme** (wie Bibliothek).
- **Bei deinen Diensten** (Anzahl): Titel mit mindestens einem Angebot `flatrate`/`free`/`ads` im Land des Nutzers bei
  einem seiner Dienste. Chips mit Logo, grünem Rand und ✓. Ist ein solches Angebot in den letzten 7 Tagen neu
  aufgetaucht (`availability_notices.state` ≠ `baseline`, `noticed_at` ≤ 7 Tage alt), erscheint grün „neu seit
  <TT.MM.>“ – unabhängig davon, ob Benachrichtigungen an sind.
- **Noch nicht bei deinen Diensten** (Anzahl), eine Statuszeile: „Im Abo bei <Dienst(e)>“ (fremde Abo-Dienste) ·
  „Gratis bei …“ · „Nur leihen oder kaufen“ · „Derzeit nirgends verfügbar“ · „Verfügbarkeit noch nicht abgefragt“
  (keine Daten).
- Innerhalb der Gruppen nach `added_at`, neueste zuerst. Poster, Name, Jahr, Badge Serie/Film; Klick öffnet die
  Detailseite; Knopf **Entfernen** (htmx, entfernt die Karte).
- Fußzeile: „Verfügbarkeit in <Land>: JustWatch (Link auf justwatch.com) · Stand <ältestes fetched_at der Liste>“ und
  der Hinweis, dass Titel beim Schauen von der Liste verschwinden.
- Leere Liste: „Noch nichts vorgemerkt. In der Suche fügst du Titel mit **+ Später** hinzu.“
- Ohne eingestellte Dienste: alle Titel unter „Noch nicht bei deinen Diensten“ und ein Hinweis mit Link auf **Konto**.
- Die Seite selbst fragt **nicht** bei TMDB an.

## 4. Verfügbarkeit abfragen

### 4.1 Eine Abfrage
`AvailabilityService.refresh(title, tmdb:)`: ruft `/movie|tv/{id}/watch/providers` (neue Methode am `TMDBClient`,
`FakeTMDBClient` bekommt sie mit), ersetzt in einer Transaktion alle `title_providers` des Titels durch die Angebote
der eingestellten Länder und setzt `title_availability.fetched_at = now`. Bei TMDB-Fehlern bleibt der alte Stand
unverändert.

### 4.2 Wann abgefragt wird
- **Täglich** im Tageslauf (`runDailyPass`), nach dem Folgen-Abgleich und vor `runNotifications`: jeder Titel, der auf
  mindestens einer Liste steht, **einmal** (die Antwort enthält alle Länder). Token: die der Nutzer, die ihn auf der
  Liste haben, nacheinander über `withAcceptedToken` (Muster `refreshTokens`). Ohne gültigen Token wird der Titel
  übersprungen.
- **Detailseite:** Fehlt der Stand oder ist er älter als **7 Tage**, lädt der Block per htmx (`hx-trigger="load"`)
  nach; die Seite selbst rendert sofort mit „Verfügbarkeit wird geladen …“ bzw. dem gespeicherten Stand. Die Abfrage
  läuft mit dem Token des Nutzers; ohne Token zeigt der Block den Token-Hinweis (gespeicherte Daten werden trotzdem
  gezeigt, sofern der Nutzer den Titel nutzt – Regel `usesTitle`).
- **Hinzufügen zur Liste:** sofort (3.1).

### 4.3 Ausgangslage („baseline“) und neue Angebote
Ein Eintrag mit `baselined = false` wird nach der nächsten erfolgreichen Abfrage seines Titels abgeglichen: alle zu dem
Zeitpunkt passenden Angebote (eigenes Land, eigene Dienste, `flatrate`/`free`/`ads`) werden als
`availability_notices` mit `state = baseline` eingetragen, danach `baselined = true`.

Für Einträge mit `baselined = true` werden nach jeder erfolgreichen Abfrage passende Angebote ohne Zeile **für alle
Nutzer** eingetragen – mit `state = pending`, wenn `notify_available` an ist, sonst `skipped`. So staut sich bei
ausgeschaltetem Schalter nichts an, und „neu seit“ funktioniert trotzdem. **Einschalten** des Schalters setzt alle
Einträge des Nutzers auf `baselined = false` (wie Dienst-/Landwechsel), damit nur danach Auftauchendes gemeldet wird. So gibt es keine Nachricht für das,
was beim Hinzufügen bzw. beim Ändern von Diensten oder Land schon lief. Der Abgleich passiert im Tageslauf direkt nach
den Abfragen, beim Hinzufügen direkt nach der Sofort-Abfrage.

### 4.4 30-Tage-Grenze
Im Tageslauf: `title_availability` mit `fetched_at` älter als 30 Tage samt ihren `title_providers` löschen.
`availability_notices` bleiben dabei bestehen (sonst käme nach einer langen Pause eine doppelte Nachricht).

## 5. Detailseite: Block „Verfügbarkeit“

Wie im Entwurf `detail-availability-v2.html` (mit Haken und grünem Rand aus Rückmeldung), unter dem Kopf der Seite,
vor Staffeln bzw. Sichtungen, für Serien und Filme:
- Überschrift „Verfügbarkeit“ + Land (z. B. „Verfügbarkeit · Deutschland“).
- **In deinen Abos:** Angebote `flatrate` bei eigenen Diensten – grüner Rand und ✓.
- **Weitere Abos:** übrige `flatrate`, leicht abgeschwächt.
- **Gratis / mit Werbung:** `free` und `ads`.
- **Leihen oder kaufen (n Anbieter)** als eingeklapptes `<details>` (`rent`, `buy`, je Anbieter einmal mit Art).
- Ohne eingestellte Dienste: nur „Im Abo“ ohne Aufteilung + Link „Deine Dienste unter Konto festlegen“.
- Leere Gruppen entfallen; ohne Abo-Angebot: „Derzeit bei keinem Abo-Dienst verfügbar.“ Steht der Titel auf der Liste,
  folgt der Hinweis, dass eine Nachricht kommt, sobald er bei einem eigenen Dienst läuft.
- Chips mit Logo (`https://image.tmdb.org/t/p/w92<logo_path>`, wie bei `Poster`) und Name; klickbar nur, wenn es für den
  Dienst einen `watchLink` gibt (2.), sonst Text.
- Fußzeile: „Verfügbarkeit: JustWatch“ (Link auf `https://www.justwatch.com/de` bzw. passendes Land) · „Stand
  <TT.MM.JJJJ>“. Kein weiterer TMDB-Link (steht schon in `ExternalLinks`).
- Zustände: lädt · Daten · keine Abo-Angebote · kein Token.

## 6. Benachrichtigung

- **Schalter** unter **Konto → Benachrichtigungen:** „Wenn ein Titel aus „Später ansehen“ bei einem meiner Dienste
  verfügbar wird“ (`users.notify_available`, Standard aus).
- **Fällig** für einen Nutzer: seine `availability_notices` mit `state = pending` (eingetragen nach 4.3), deren Titel
  noch auf seiner Liste steht und deren Angebot noch besteht. Hat der Nutzer keinen Kanal, bleiben sie liegen, bis
  einer eingerichtet ist (wie bei Folgen).
- **Versand** im bestehenden Tages-Digest (`runNotifications`): Die Nutzerabfrage nimmt `notify_available` in die
  Oder-Bedingung auf; der Digest bekommt einen eigenen Abschnitt „Jetzt bei deinen Diensten“ (pro Titel: Name, Jahr,
  Serie/Film, Dienste, Link auf die Detailseite) und einen Teil im Betreff („2 Titel jetzt verfügbar“). Gibt es nur
  Verfügbarkeiten und keine Folgen, entfällt der Folgen-Teil samt Einleitung zu beobachteten Serien. Am Ende steht
  „Verfügbarkeit: JustWatch“.
- **Nach erfolgreichem Versand** werden die gemeldeten Zeilen auf `state = sent` gesetzt; bei Fehlern bleiben sie
  `pending` und werden am nächsten Tag erneut versucht (wie bei Folgen).
- **Wieder verfügbar:** Nach jeder erfolgreichen Abfrage eines Titels werden `availability_notices` dieses Titels
  gelöscht, deren Dienst im Land des jeweiligen Nutzers kein passendes Angebot mehr hat – kommt der Titel später
  zurück, gibt es erneut eine Nachricht.
- Webhook (KNot) bekommt denselben Text wie die Mail.

## 7. App-API (`openapi.yaml`)

Neue Endpunkte (Tags nach vorhandenem Muster; alle über die gemeinsamen Services):
- `GET /v1/watch-later` – Liste mit Titel-Kurzinfo, `addedAt` und Verfügbarkeit im Land des Nutzers.
- `PUT /v1/tv/{tmdbID}/watch-later`, `PUT /v1/movies/{tmdbID}/watch-later` mit `{ "watchLater": bool }` (Muster
  `/follow`).
- `GET /v1/tv/{tmdbID}/availability`, `GET /v1/movies/{tmdbID}/availability` – gespeicherter Stand; älter als 7 Tage
  oder fehlend → vorher abfragen (wie Web).
- `GET /v1/me/streaming-services`, `PUT /v1/me/streaming-services` mit `{ "region": "DE", "providerIDs": [8, 337] }`.
- `GET /v1/streaming-providers?region=DE` (Auswahlliste), `GET /v1/streaming-regions`.
- `/v1/me/notifications` bekommt das Feld `available`.
- Serien-/Film-Details und Suchtreffer bekommen `watchLater: bool`.
- Angebote als Objekt `{ providerID, name, logoPath, kind }`; `kind` (`flatrate`, `free`, `ads`, `rent`, `buy`) ist ein
  wachsender String-Enum → in `OpenValues.swift` als offener Typ abbilden (`typeOverrides`, `known`-Liste, Test in
  `WatchSwiftyClientTests`).
- Ohne TMDB-Token: Endpunkte, die TMDB brauchen, antworten mit dem vorhandenen Fehler für fehlenden Token.

## 8. Rechtliches und Doku

- **Quellenhinweis JustWatch** überall, wo Verfügbarkeit angezeigt oder verschickt wird (Detailseite, Liste, Digest).
- Doku: `docs/notifications.md` (neuer Schalter, Digest-Abschnitt), `docs/tmdb.md` (Watch Providers, JustWatch,
  30 Tage, tägliche Last: eine Anfrage pro gemerktem Titel), `docs/accounts.md` (Streamingdienste, Land),
  `docs/app-api.md` (neue Endpunkte), README-Features, CHANGELOG. UI-Hinweise per `DocsLink`.
- `docs/datenschutz-ios-app.md` / `privacy-ios-app.md`: prüfen, ob Land und Dienste erwähnt werden müssen (gespeichert
  auf dem eigenen Server des Nutzers, nicht in der App).

## 9. Tests (Auswahl)

- Hinzufügen aus Suche/Detailseite legt Titel und Eintrag an; doppelt hinzufügen bleibt ein Eintrag.
- Jede Art der Sichtung (Folge, Staffel, Serie, bis hier, Film, Netflix-Import, Standard-Import) entfernt den Eintrag.
- Isolation: fremde Einträge/Einstellungen → 404 bzw. nicht sichtbar (`IsolationTests`).
- `titleUsers`/`usesTitle` zählen `watch_later`; Provider-Tabellen halten keinen Titel im Cache.
- Tagesabfrage: ein TMDB-Aufruf pro Titel, auch bei mehreren Nutzern; nur eingestellte Länder gespeichert; Fehler
  behalten den alten Stand; Löschung nach 30 Tagen.
- Import alter Sichtungen (Datum vor `added_at`) lässt den Eintrag stehen; manuelle Sichtung mit altem Datum entfernt.
- Schalter aus → neue Angebote als `skipped`, kein Stau; Einschalten → keine Nachricht für vorher Aufgetauchtes;
  „neu seit“ erscheint auch ohne Benachrichtigungen.
- Landwechsel → Liste fragt fehlende Länder nach; `regions` ohne eigenes Land gilt als fehlend.
- Ausgangslage: beim Hinzufügen schon verfügbarer Titel → keine Nachricht; neu auftauchender Dienst → genau eine
  Nachricht; Leihen/Kaufen → keine; Dienst wechselt Land/Dienste → keine Nachricht für Bestehendes; verschwindet und
  kommt zurück → erneute Nachricht; Versandfehler → am nächsten Tag erneut.
- Detailseite: lädt nach bei fehlendem/altem Stand, sonst nicht; Gruppierung eigene/weitere Abos; ohne Token Hinweis.
- Suche und Bibliothek zeigen gemerkte Titel nicht als „in der Bibliothek“.
- API-Endpunkte inkl. `OpenValues`-Test.

## 10. Dem Entwickler überlassen

- Namen von Services, Controllern, Komponenten und Routen (Vorschlag: `WatchLaterService`, `AvailabilityService`,
  `WatchLaterController`, `AvailabilityBlock`, `WatchLaterToggle`).
- Genaue CSS-Umsetzung im vorhandenen `app.css` (Entwürfe unter `.superpowers/brainstorm/` dienen als Vorlage).
- Exakte TMDB-`provider_id`-Zuordnung zu `StreamingService` (2.).
- Ob die Länderliste und die Dienste-Liste für **Konto** kurz im Speicher gehalten werden (nicht in der Datenbank).
