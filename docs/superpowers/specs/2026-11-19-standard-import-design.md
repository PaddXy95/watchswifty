# WatchSwifty – Standard-Import (CSV) statt eigener Filmliste

Stand: 2026-11-19 · Status: Entwurf · Ersetzt den Nachtrag „Import einer eigenen Filmliste“ aus
`2026-11-07-ui-round-design.md`

Markierung: *(Nutzer)* = vom Nutzer entschieden, *(Claude)* = Vorschlag/Entscheidung von Claude, korrigierbar.

## Warum

Der Filmlisten-Import liest nur das Format einer einzigen privaten Numbers-Tabelle (Spalten „Filmname“, „Mit Ela“,
„Übeltäter“, Datum wie „Mo., 1. Jan. 2024“). Niemand sonst kann ihn nutzen. Wer von einem **anderen Tracker**
(Letterboxd, IMDb, Trakt, TV Time, Simkl …) zu WatchSwifty wechselt, soll seine Historie mitnehmen können *(Nutzer)*:
Er bringt den Export in ein festes, dokumentiertes Format mit den wichtigsten Feldern. Dazu gehören **Serien-Episoden**,
nicht nur Filme *(Nutzer)* – bei Serien-Trackern steckt dort der Großteil der Historie.

## Ziele

- Ein offenes CSV-Format für Filme, Episoden und Serien (Bewertung/Kommentar ohne Sichtung).
- Eindeutige Zuordnung über `tmdb_id` oder `imdb_id`, sonst über Titel + Jahr mit Prüfansicht als Netz.
- Web-UI, App-API und iOS-App können es *(Nutzer: iOS-App in derselben Aufgabe)*.
- Der Filmlisten-Import (Format, Seite, API, Tabelle, iOS-Ansicht) ist vollständig entfernt *(Nutzer)*.

## Nicht-Ziele

- Direkter Import der Original-Exporte (Letterboxd-`diary.csv`, IMDb-`ratings.csv`, Trakt-JSON) mit eigenen Parsern.
  Die Doku zeigt, welche Spalten man wie umbenennt.
- Spalten-Aliase oder automatische Formaterkennung.
- Bewertungen einzelner Episoden (die App kennt Bewertungen nur pro Titel), Staffelkommentare.
- Übernahme der alten `film_list_entries` ins neue Format.

## Anti-Ziele

- Falsche Zuordnungen still übernehmen: lieber „Zu prüfen“ als ein falscher Film/eine falsche Serie.
- Doppelte Sichtungen bei erneutem Import.
- Bestehende Sichtungen, Bewertungen oder Kommentare überschreiben, die nicht aus der Datei stammen.

## Ansätze

- **A. Filmlisten-Ablauf zu einem allgemeinen Import umbauen** – gewählt *(Nutzer)*. Zeilen werden pro Titel
  gesammelt, jeder Titel wird einmal zugeordnet (automatisch oder „Zu prüfen“), bei Serien werden danach die Episoden
  über Staffel-/Episodennummer im Katalog gesucht. Prüfansicht, Hintergrund-Worker und Duplikatschutz bleiben; zu
  prüfen ist pro Serie einmal, nicht pro Episode. Kosten: neues Datenmodell in Tabelle, API und iOS-App.
- **B. Zeilen in den Netflix-Ablauf einspeisen** – verworfen: Netflix-Zuordnungen hängen am Titelnamen und gelten für
  alle späteren Netflix-Importe, Episoden werden über ihren Namen gefunden; IDs, Nummern und Bewertungen passen nicht.
- **C. Nur Zeilen mit ID, ohne Prüfansicht** – verworfen: Letterboxd und selbst gepflegte Listen haben keine IDs, ein
  großer Teil der Umsteiger fiele raus.

## 1. Das Format

CSV, UTF-8 (BOM erlaubt; Windows-1252 als Rückfall wie heute), Trennzeichen `,` oder `;`, Anführungszeichen nach
RFC 4180 (vorhandenes `splitCSVRecords`). Kopfzeile = erste Zeile, die die Spalten `type` und `title` enthält; Zeilen
davor werden ignoriert. Das Trennzeichen wird so bestimmt: die erste Zeile, die beim Trennen mit `;` sowohl `type` als
auch `title` ergibt, legt `;` fest, sonst `,` *(Claude)*.
Spaltennamen englisch *(Claude: Format für Exporte aus aller Welt; UI bleibt deutsch)*, Groß-/Kleinschreibung und
Leerraum egal, Reihenfolge egal, unbekannte Spalten werden ignoriert *(Claude)*.

```
type,title,year,tmdb_id,imdb_id,season,episode,watched_on,service,rating,comment
movie,Dune,2021,438631,,,,2024-03-02,netflix,8,Im Kino besser
episode,Severance,2022,,tt11280740,1,3,2024-05-10,apple_tv,,
series,Severance,2022,,tt11280740,,,,,9,
```

| Spalte | Pflicht | Bedeutung |
|---|---|---|
| `type` | ja | `movie`, `episode` oder `series` (Groß-/Kleinschreibung egal) |
| `title` | ja | Film- bzw. **Serien**titel (bei `episode` der Serientitel, nicht der Episodenname) |
| `year` | nein | Erscheinungsjahr des Films bzw. erstes Ausstrahlungsjahr der Serie |
| `tmdb_id` | nein | TMDB-ID des Films bzw. der Serie (nicht der Episode) |
| `imdb_id` | nein | IMDb-ID `tt…` des Films bzw. der Serie; eine Episoden-ID wird auf ihre Serie aufgelöst *(Claude)* |
| `season`, `episode` | bei `episode` ja | Staffel- und Episodennummer (ganze Zahlen ≥ 0; Staffel 0 = Specials) |
| `watched_on` | nein | `YYYY-MM-DD`, `DD.MM.YYYY`, `D.M.YYYY`, `M/D/YY` (vorhandenes `netflixDay`); zusätzlich ISO-Zeitstempel `YYYY-MM-DDThh:mm…` bzw. `YYYY-MM-DD hh:mm…` – davon zählt der Datumsteil, ohne Zeitzonenumrechnung *(Claude; `netflixDay` kann das heute nicht, wird vorgeschaltet)* |
| `service` | nein | Schlüssel aus `StreamingService` (`netflix`, `prime_video`, `disney_plus`, `apple_tv`, `hbo_max`, `paramount_plus`, `wow`, `cinema`, `purchased`, `other`); zusätzlich die Klartext-Erkennung der Filmliste (`StreamingService(label:)`), Unbekanntes → `other` *(Claude)* |
| `rating` | nein | 1–10; Kommazahlen (`7.5`/`7,5`) werden gerundet, außerhalb 1–10 begrenzt; 0 oder leer = keine Bewertung *(Claude)* |
| `comment` | nein | Freitext |

**Bedeutung der Zeilen** *(Claude, vom Nutzer im Gespräch bestätigt)*
- Jede `movie`- und jede `episode`-Zeile ist **eine Sichtung** (mehrfach = mehrfach gesehen). Ohne/mit unlesbarem
  oder zukünftigem Datum: Sichtung ohne Datum (wie bisher).
- Eine `series`-Zeile legt **keine** Sichtung an; sie nimmt die Serie mit Bewertung/Kommentar in die Bibliothek auf
  (so passt z. B. ein IMDb-Ratings-Export).
- `rating` und `comment` gelten für den Titel, egal in welcher Zeilenart sie stehen *(Claude)*.

**Ungültige Zeilen** *(Claude)*: leere Zeilen werden still übersprungen. Zeilen mit unbekanntem `type`, ohne `title`
oder (`episode`) ohne gültige `season`/`episode` werden übersprungen und gezählt. Die Erfolgsmeldung nennt die Zahl
(„… 3 Zeilen übersprungen (unbekannter Typ, fehlender Titel oder fehlende Staffel/Episode)“).

**Kopfzeile fehlt** (keine Zeile mit `type` und `title`): Fehlermeldung „Kein Standard-Import erkannt – erwartet wird
eine CSV mit einer Kopfzeile, die „type“ und „title“ enthält.“ mit Verweis auf die Doku. Datei ohne gültige Zeilen:
„Die Datei enthält keine Titel.“

**Größe:** höchstens 5 MB *(Claude: ein Trakt-Verlauf mit vielen tausend Episoden passt nicht in 2 MB)*; Web-Route und
`BodyLimitMiddleware` (Operation-Limit etwas darüber, wie heute) entsprechend.

**Beispieldatei:** `Public/import/watchswifty-import-example.csv` mit je einer Zeile pro Art, verlinkt auf der
Import-Seite („Beispieldatei herunterladen“) und in `docs/import.md` *(Claude)*.

## 2. Gruppierung zu Titeln

Zeilen werden zu **Einträgen** (einer pro Titel) zusammengefasst, in Dateireihenfolge des ersten Auftretens:
- Art: `movie` → Film; `episode` und `series` → Serie.
- Schlüssel: Art + `tmdb_id`, sonst Art + `imdb_id`, sonst Art + normalisierter Titel (`normalizeTitle`) + Jahr.
  **Ausnahme `episode`-Zeilen:** ihre `imdb_id` zählt nicht zum Schlüssel (sie kann die ID der Episode sein, die je
  Zeile anders ist); sie gruppieren nach `tmdb_id`, sonst Titel + Jahr. Die erste gefüllte `imdb_id` der Gruppe wird
  als Hinweis für die Zuordnung behalten *(Claude: so bleibt „einmal pro Serie prüfen“ erhalten)*.
  Zeilen mit ID und Zeilen ohne ID desselben Titels werden **nicht** zusammengeführt *(Claude: ohne TMDB-Abfrage
  nicht sicher; landen sie beim selben Titel, verhindert der Duplikatschutz doppelte Sichtungen)*.
- Ein Eintrag hält: Art, Titel und Jahr (der ersten Zeile), `tmdb_id`/`imdb_id` (erste gefüllte), alle Sichtungen
  (`season?`, `episode?`, `day?`, `service?`), Bewertung (letzte gefüllte Zeile in Dateireihenfolge), Kommentar
  (alle unterschiedlichen gefüllten Kommentare in Dateireihenfolge, mit Leerzeile verbunden, auf
  `WatchService.maxCommentLength` gekürzt) *(Claude)*.

## 3. Zuordnung zu TMDB (Hintergrund)

Wie bisher läuft sie im Hintergrund-Worker mit dem Token des Nutzers; Fehler (z. B. kein Token) bleiben am Eintrag
stehen, „Erneut versuchen“ setzt sie zurück. Reihenfolge pro Eintrag:
1. **`tmdb_id`**: Titel über TMDB in der Art des Eintrags laden. TMDB kennt die ID nicht (404) → weiter mit
   Schritt 2/3 *(Claude)*.
2. **`imdb_id`**: neuer TMDB-Aufruf `GET /find/{imdb_id}?external_source=imdb_id` (neue Methode im `TMDBClient`,
   `FakeTMDBClient` mit). Treffer der passenden Art → übernehmen; ein Episodentreffer (`tv_episode_results`) liefert
   über `show_id` die Serie *(Claude)*. Kein Treffer oder nur Treffer der anderen Art → Schritt 3.
   **Plausibilitätsprüfung für 1 und 2** *(Claude, Anti-Ziel „nichts Falsches still übernehmen“)*: Der per ID
   gefundene Titel wird nur automatisch übernommen, wenn sein normalisierter Titel oder Originaltitel dem der Datei
   entspricht **oder** das Jahr ±1 passt (bzw. die Datei kein Jahr hat). Sonst „Zu prüfen“ mit diesem Titel als
   erstem Vorschlag plus den Treffern der Titelsuche.
3. **Titel + Jahr**: Suche in der passenden Art (`search(_, kind:)`), Auswahl mit der vorhandenen Logik von
   `chooseFilm` (exakter Titel innerhalb ±1 Jahr, oder einziger Treffer im Bereich), verallgemeinert auf Serien
   (Jahr = erstes Ausstrahlungsjahr). Unklar → „Zu prüfen“ mit höchstens 5 Vorschlägen; nichts → „Nicht gefunden“.

„Zu prüfen“/„Nicht gefunden“ bieten wie heute: Vorschlag übernehmen, eigener Suchbegriff (Suche in der Art des
Eintrags), Überspringen.

## 4. Übernehmen (Sichtungen, Bewertung, Kommentar)

Ist der Titel zugeordnet:
- **Film**: wie bisher (`FilmListImporter.record`): jede Sichtung wird angelegt, außer es gibt schon eine Sichtung des
  Films am selben Tag ±1 (bzw. für eine Sichtung ohne Datum: irgendeine Sichtung des Films).
- **Serie**: Episoden des Katalogs laden (`CatalogService.episodes(of:)`), jede Sichtung über (Staffel, Nummer)
  zuordnen. Gleicher Duplikatschutz pro Episode (Tag ±1 bzw. ohne Datum: irgendeine Sichtung der Episode). Fehlen
  Episoden und war die Serie schon im Katalog, wird sie einmal neu von TMDB geladen (`CatalogService.refresh`) und
  erneut gesucht *(Claude: sonst blieben neue Staffeln eines alten Cache-Stands unauffindbar)*. Was dann noch fehlt,
  wird gezählt (`missing_episodes`) und nicht angelegt. Noch nicht ausgestrahlte
  Episoden werden trotzdem angelegt, wenn die Datei es sagt *(Claude: die Datei ist die Quelle; anders als der
  „Gesehen“-Knopf)*.
- Sichtungen bekommen `origin: .manual` wie bisher die Filmliste *(Claude)*.
- Bibliothekseintrag (`user_titles`) wird über `WatchService.userTitle` angelegt. Ausgeblendete Titel werden wieder
  eingeblendet, sobald der Import mindestens eine Sichtung anlegt – für Serien wie beim manuellen Markieren einer
  Episode, für Filme ebenso *(Claude: heute blendet `markMovie` nicht ein; ein Import soll importierte Filme sichtbar
  machen)*. Eine `series`-Zeile ohne Sichtung ändert das Ausblenden nicht. Folgen/Beobachten wird nicht verändert *(Claude: wer eine
  Serie früher gesehen hat, will nicht unbedingt neue Folgen gemeldet bekommen; folgen geht mit einem Klick)*.
- Bewertung: gesetzt, wenn die Datei eine hat (überschreibt eine vorhandene, wie bisher).
- Kommentar: ist der vorhandene leer → gesetzt; sonst angehängt (Leerzeile), wenn er nicht schon enthalten ist und die
  Länge reicht (wie bisher).
- Danach Status „Übernommen“ mit `tmdb_id` und Zahl der angelegten Sichtungen *(Claude)*.

## 5. Daten

- Neue Tabelle `import_entries` (Model `ImportEntry`) *(Claude)*: `id`, `user_id` (cascade), `position`, `kind`
  (`movie`/`tv`), `title`, `year?`, `tmdb_hint?` (aus der Datei), `imdb_id?`, `watches` (JSON
  `[{season?, episode?, day?, service?}]`), `rating?`, `comment?`, `status` (`pending`, `imported`, `review`,
  `not_found`, `skipped`), `tmdb_id?` (Ergebnis), `candidates?` (JSON), `missing_episodes` (int, 0), `added_watches`
  (int, 0), `error?`, `created_at`.
- Ein neuer Upload ersetzt die Einträge des Nutzers (angelegte Sichtungen bleiben) – wie bisher.
- Migrationen, hinten angehängt: `CreateImportEntry`, `DropFilmListEntries` (löscht `film_list_entries`;
  `revert` legt sie leer wieder an) *(Claude)*. `CreateFilmListEntry` bleibt in der Liste (Migrationshistorie); da
  das Model `FilmListEntry` entfällt, schreibt sie Tabellen- und Feldnamen direkt aus.
- `CatalogMaintenance`: `titleUsers` zählt zugeordnete `import_entries` (Art + `tmdb_id` → Titel) statt
  `film_list_entries`; die 60-Tage-Bereinigung der Vorschlagslisten gilt für `import_entries.candidates`.

## 6. Web-UI

- Seite **„Aus anderen Trackern importieren“** unter `/import/standard` *(Claude)*, verlinkt von **Import** statt
  „Eigene Filmliste aus Numbers oder Excel?“: kurzer Text („CSV im WatchSwifty-Format – z. B. aus Letterboxd, IMDb oder
  Trakt umgebaut“), `DocsLink` auf `docs/import.md`, Link zur Beispieldatei, Upload-Formular.
- Aufbau wie die Filmlisten-Seite: Statuszeile mit Polling, Zähler, Karten für „Zu prüfen“/„Nicht gefunden“, Liste der
  übernommenen. Jede Karte zeigt zusätzlich die Art (**Film**/**Serie**), „N Sichtungen“ und bei Serien „M Episoden
  nicht gefunden“, wenn M > 0 *(Claude)*.
- Alle Routen `/import/films*` entfallen (404).

## 7. App-API

Neue Operationen unter `/v1/imports/standard` *(Nutzer: neue Endpunkte, alte entfallen)*:
`POST` (Upload, multipart `file`, Antwort `{titles, skippedRows}`), `GET` (Liste), `POST /retry`,
`POST /{id}/accept` (`{tmdbId}`), `POST /{id}/search` (`{q}`), `POST /{id}/skip`.
Schemas: `ImportUploadResult`, `ImportEntry` (`id, kind, title, year?, watchCount, rating?, status, tmdbId?,
candidates, missingEpisodes, addedWatches, error?`), `ImportCounts`, `ImportList`, `ImportAccept`, `ImportSearch`,
Status-Enum `ImportStatus`. `kind` nutzt dasselbe Enum wie `SearchResult.kind`.
Alle `uploadFilmList`/`getFilmList`/… und `Film*`-Schemas entfallen; in `WatchSwiftyClient/OpenValues.swift` wird
`FilmStatusValue` durch `ImportStatusValue` ersetzt (`typeOverrides`, `known`-Liste, Tests). `docs/app-api.md`
entsprechend.

**Kompatibilität:** Ältere iOS-App-Versionen bekommen auf der Filmlisten-Seite einen Fehler (404). Das ist in Kauf
genommen *(Nutzer)*.

## 8. iOS-App (`../watchswifty-ios`)

- `FilmListStore` → `StandardImportStore`, `FilmListView` → `StandardImportView`, Eintrag in `ImportsView`
  („Aus anderen Trackern“); Karten mit Art, Sichtungen, fehlenden Episoden; Upload über den Dateiimporter wie bisher;
  Hinweistext zum Format mit Link auf die Doku. Tests (`FilmListStoreTests`) umziehen.
- Abhängigkeit: die App hängt an einem **Release-Tag** des Servers. Diese Aufgabe **endet beim Merge in `dev`**
  *(Nutzer)*: kein Release, kein Push auf `main`, `VERSION`/CHANGELOG-Release-Abschnitt bleiben unberührt. Die
  iOS-Änderung liegt auf einem eigenen Branch in `watchswifty-ios` und wird lokal mit `path: "../../../watchswifty"`
  gebaut und getestet; diese Pfadänderung wird nicht committet, der Tag nicht angehoben. Beim späteren Release
  (Vorschlag 0.7.0, da Endpunkte entfallen) wird der Tag in der App angehoben und der Branch gemergt.

## 9. Entfernen

`FilmList.swift` (Parser `parseFilmList`, `germanDay`, `filmRating`, `groupFilmList`, Kommentarbau), `FilmListEntry`/
`FilmListService`, `FilmListImporter`/`FilmListWorker`, `FilmListController`, `FilmListPage`, `APIHandler+FilmList`,
Tests `FilmListTests`/`APIFilmListTests`, Doku-Abschnitt „Your own film list“, README-Erwähnung.
Wiederverwendet (verschoben/umbenannt, nicht gelöscht): `StreamingService(label:)`, `chooseFilm` (→ allgemeine
Auswahl), Duplikatschutz und Kommentar-Anhängen aus `record`, Worker-Gerüst.

## 10. Doku

`docs/import.md`: Abschnitt „Other trackers (standard CSV)“ mit Spaltentabelle, Beispiel und kurzen Umbau-Hinweisen
für Letterboxd (`Name`→`title`, `Year`→`year`, `Watched Date`→`watched_on`, `Rating`×2→`rating`, `type`=`movie`) und
IMDb-Ratings (`Const`→`imdb_id`, `Your Rating`→`rating`, `Title Type` → `movie`/`series`, `Date Rated`→`watched_on`
nur bei Filmen) *(Claude)*. README-Feature-Liste und `docs/app-api.md` in dieser Aufgabe; CHANGELOG-Abschnitt (### Changed + ### Added) erst beim Release.

## 11. Tests

- Parser: Kopfzeile (Groß-/Kleinschreibung, `;`, BOM, unbekannte Spalten), Zeilenarten, ungültige Zeilen werden
  gezählt, Datumsformate, Bewertung (Runden, Begrenzen, 0), `service`-Schlüssel und Klartext.
- Gruppierung: Schlüssel mit/ohne ID, Bewertung letzte gewinnt, Kommentare zusammengeführt.
- Zuordnung: `tmdb_id` direkt, `imdb_id` über `/find` (inkl. Episoden-ID → Serie), Titel+Jahr automatisch/zu prüfen/
  nicht gefunden, für Filme und Serien (`FakeTMDBClient`).
- Übernehmen: Film- und Episodensichtungen, Duplikatschutz bei erneutem Import, fehlende Episoden gezählt,
  `series`-Zeile ohne Sichtung, Kommentar anhängen.
- Web und API: Upload, Fehlermeldungen, Polling, accept/search/skip, Isolation (fremde Einträge → 404),
  `/import/films` und `/v1/imports/films` → 404, Migration löscht `film_list_entries`.
- `CatalogMaintenance`: zugeordnete Einträge halten ihre Titel.
- iOS: Store-Tests mit `FakeTransport`.

## Offen für den Umsetzer

Namen von Typen/Dateien, Aufteilung der Dateien, genaue Texte der Karten, Aufbau der iOS-Ansicht im Rahmen der
bestehenden Import-Ansichten.
