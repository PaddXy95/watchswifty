# WatchSwifty – Feedback-Runde (Kurz-Design)

Stand: 2026-11-13 · Status: vom Nutzer freigegeben · Ergänzt `2026-11-07-watchswifty-design.md`, `2026-11-11-notifications-design.md`

**Warum:** Rückmeldungen aus der Nutzung von 0.4.0: kleine Fehler und Unschönheiten in der Oberfläche, fehlende
Informationen beim Import und auf der Serienseite, Genres als Grundlage für eine spätere Genre-Statistik.

**Nicht-Ziele:** Genre-Statistik (kommt extra); deutsche Erstausstrahlung (siehe §9); iOS-App (`watchswifty-ios`
– sie läuft unverändert weiter, ihr Passwortfeld beim Webhook-Schlüssel wird ignoriert; Genres in der App sind ein
eigener Punkt nach dem Release, weil die App `WatchSwiftyClient` über den Release-Tag bezieht); Punkt 11 (fehlt in der
Liste des Nutzers); Release (VERSION/CHANGELOG-Abschnitt
und Tag entscheidet der Nutzer nach der Umsetzung).

## Umfang [entschieden]

1. **Version ausblenden** – auf allen Seiten ohne Anmeldung (Anmelden, Passwort vergessen/zurücksetzen, neues SSO-Konto,
   jede Seite mit `nav == nil`) zeigt der Footer keine Version und keinen Update-Hinweis. Angemeldete sehen sie wie
   bisher. `GET /api/v1/version` bleibt öffentlich (die App braucht sie vor dem Login).
2. **Netflix-Anleitung** – Import-Seite und `docs/import.md`: „Netflix im Browser: Konto → Einstellungen →
   Titelverlauf → ganz unten „Alle herunterladen“. Die Datei heißt NetflixViewingHistory.csv.“ *(Pfad vom Nutzer
   bestätigt.)*
3. **Pocket ID statt Authentik als Beispiel** – System → OIDC: Platzhalter des Anzeigenamens „z. B. Pocket ID“, in der
   Aufzählung steht Pocket ID vorn. `docs/sso.md`: Pocket ID zuerst in der Liste und als durchgehendes Beispiel, mit
   kurzem Einrichtungsabschnitt (OIDC-Client anlegen, Callback-URL, Client-ID/-Secret). Der Authentik-Hinweis in der
   HS*-Fehlermeldung und der Authentik-Abschnitt in `docs/sso.md` bleiben (betreffen nur Authentik).
4. **Import „Zu prüfen“: Sichtungsdaten** – jeder Eintrag zeigt, wann laut Netflix-Datei gesehen wurde: eine Zeile →
   „gesehen am 07.11.2026“, mehrere → „gesehen 03.02.2025 – 07.11.2026“. Darunter aufklappbar („Zeilen anzeigen“) die
   einzelnen Netflix-Zeilen mit Datum (neueste zuerst, höchstens 20, dann „… und N weitere“). Grundlage sind die noch
   offenen Zeilen der Zuordnung. API: Schema `MappingReview` bekommt `firstDay`, `lastDay` (`YYYY-MM-DD`) und
   `rows` (`[{rawTitle, day}]`, gleiche Auswahl und Grenze wie im Web; Namen wie bei `UnmatchedRow`).
   1. **Kandidaten** (Zu prüfen, Eigene Suche, Zuordnung ändern, Filmliste): jede Zeile besteht aus Poster, Name
      (Jahr), Link „TMDB ↗“ (neuer Tab, `themoviedb.org/{tv|movie}/{id}`) und eigenem Knopf „Übernehmen“. Klick auf das
      Poster zeigt es groß (ca. 342 px breit) als Overlay; schließen per Klick daneben oder Escape.
5. **Webhook-Schlüssel ohne Passwort** – Setzen, Ändern und Entfernen brauchen kein Passwort mehr, im Web und in der
   API. Die API nimmt `currentPassword` weiter an und ignoriert es (alte App-Versionen schicken es mit). Ersetzt die
   Regel in `2026-11-11-notifications-design.md` („braucht das aktuelle Passwort“); der Nutzer nimmt das Restrisiko
   (gekaperte Sitzung leitet „Neues Gerät“ um) bewusst in Kauf.
6. **Konto → Benachrichtigungen** – „Speichern“ und „Testnachricht senden“ bekommen Abstand zueinander (und zum Text
   „Senden per …“ davor).
7. **Genres** – aus TMDB (Serien- und Film-Details) gespeichert, auf Serien- und Filmseite unter dem Titel angezeigt,
   in der Bibliothek filterbar.
   - **Gemeinsame Liste für Serien und Filme** *(Nutzer)*: eigene, stabile Schlüssel mit deutschen Namen; die
     Mischgenres der Serien werden aufgeteilt: „Action & Adventure“ → Action + Abenteuer, „Sci-Fi & Fantasy“ →
     Science-Fiction + Fantasy, „War & Politics“ → Krieg + Politik. Alle übrigen TMDB-Genres (Film- und Serienliste)
     bekommen je einen Schlüssel; unbekannte TMDB-IDs werden ignoriert.
   - Bibliothek: Auswahlliste „Genre“ neben den vorhandenen Filtern, nur Genres, die in der eigenen Bibliothek
     vorkommen, alphabetisch; kombinierbar mit Serien/Filme/Ausgeblendet und Sortierung. Ein Genre zur Zeit.
   - Bestehende Titel: Genres werden wie Laufzeiten nachgeladen – beim Öffnen der Detailseite und im täglichen
     Abgleich für gesehene Titel. Bis dahin taucht ein Titel unter keinem Genre auf.
   - TMDB-Cache-Regel: Genres gelten als TMDB-Daten und werden nach 180 Tagen ohne Refresh mit den Texten gelöscht.
   - API: `genres` (Liste von Schlüsseln) an `SeriesDetail`, `MovieDetail` und `LibraryEntry`; `GET /v1/library`
     bekommt den Parameter `genre`. Im Swift-Client ein offener Typ `GenreValue` (wie `ServiceValue`).
8. **Folgen auf der Serienseite** – jede Folge ist zugeklappt; der Folgentitel ist der Knopf zum Aufklappen (ersetzt
   „Details“). Aufgeklappt: Beschreibung, Datum/Dienst-Formular („Gesehen“/„Erneut gesehen“) und „bis hier gesehen“.
   Die Checkbox vorne bleibt zum schnellen Abhaken und klappt nichts auf; sie steht außerhalb des `<summary>`
   (Bedienelement im `<summary>` ist für Screenreader ungültig), das Layout hält ein CSS-Grid. Nach „Gesehen“, „Erneut gesehen“ oder
   „bis hier gesehen“ bleibt genau diese Folge aufgeklappt; nach der Checkbox ist alles zu. Nicht erschienene Folgen
   ohne Beschreibung haben keinen Aufklapp-Knopf.
9. **Deutsche Erstausstrahlung** – nicht umsetzbar für Serienfolgen: TMDB führt pro Folge nur ein Ausstrahlungsdatum
   (in der Regel das des Ursprungslands), keine Länderdaten. Für Filme gäbe es deutsche Kino-/Digitaltermine; das wäre
   ein eigener Punkt, falls gewünscht.
10. **System-Seite aufräumen** – die Blöcke Version & Updates, E-Mail, Benachrichtigungen und Anmeldung über OIDC sind
    einklappbar und beim Aufruf zu. Nach einer Aktion (Speichern, Testmail, Prüfen, Löschen …) ist der Block, zu dem
    sie gehört, offen; Meldung wie bisher oben. Der Update-Hinweis im Footer öffnet „Version & Updates“
    (`/admin/system?open=updates`).
12. **Dienst bei Staffel/Serie** – „Ganze Staffel gesehen“ und „Gesamte Serie gesehen“ werden zu einem kleinen Formular:
    Auswahl „Dienst“ (vorbelegt mit dem zuletzt genutzten Dienst der Serie, „unbekannt“ wählbar) + Knopf. Die
    Rückfrage bei „Gesamte Serie gesehen“ bleibt. „bis hier gesehen“ übernimmt den Dienst aus dem Formular der Folge.
    Die API kann das schon (`service` an `/seasons/{n}/watch` und `/watch-all`).
13. **Mehrfach-Sichtungen beim Import** – jede Netflix-Zeile wird schon heute eine eigene Sichtung. Der Randfall
    (eine eigene Markierung ±1 Tag nimmt mehrere Netflix-Zeilen auf) bleibt bewusst, wie er ist *(Nutzer: ohne Fix)*.

## App-API [Nutzer: „muss mit erweitert werden, falls betroffen“]

| Punkt | Änderung |
|---|---|
| 4 | `MappingReview`: `firstDay`, `lastDay`, `rows` |
| 4.1 | keine – Kandidaten (`SearchResult`) haben schon `id`, `kind` und `posterPath`; Link und großes Poster baut die App |
| 5 | `PUT/DELETE /v1/me/notifications/webhook-key`: kein Passwort mehr; `currentPassword` bleibt optional im Schema, wird ignoriert und als „deprecated“ beschrieben; Beschreibungen angepasst |
| 7 | Schema `Genre` (String-Enum der Schlüssel), `genres` an `SeriesDetail`, `MovieDetail`, `LibraryEntry`; `GET /v1/library?genre=`; offener Client-Typ `GenreValue` |
| 12 | keine – `service` an Staffel, Serie und „bis hier“ gibt es schon |
| 1, 2, 3, 6, 8, 10 | keine (reine Web-Oberfläche; `/v1/version` bleibt öffentlich) |

## Ansätze

| Thema | Gewählt | Verworfen |
|---|---|---|
| Genres speichern | Spalte `titles.genres` (Text, Schlüssel kommagetrennt; `nil` = noch nicht geladen, `""` = keine) – wie `overview`/`runtime`, Filter und spätere Statistik rechnen ohnehin im Speicher über die Titel des Nutzers | eigene Tabelle `title_genres` (Join, „nicht geladen“ vs. „keine“ braucht eine Extra-Markierung); TMDB-Genre-IDs roh speichern (Serien/Film-Mischung bliebe ungelöst) |
| Genre-Namen | deutsche Namen fest im Code pro Schlüssel | TMDB-Namen in der Nutzersprache (schwanken mit TMDB-Übersetzungen, passen nicht zur Aufteilung) |
| Folge aufklappen | Checkbox + `<details>` nebeneinander im Grid; `<summary>` = Code, Titel (als Knopf gestaltet), Laufzeit, Status; offen halten per Server-Render (`open`-Parameter der gesehenen Folge) | Panel per JavaScript (App hat bewusst kein eigenes JS); `<details>` nur um den Titel (Panel säße in der schmalen Titelspalte) |
| Poster groß | natives HTML-Popover (`popovertarget`), kein JS | `<dialog>` (braucht JS zum Öffnen); `:target`-Overlay (verändert URL/History) |
| System-Blöcke | `<details>` je Block, Server setzt `open` für den Block der letzten Aktion | Tabs (mehr Umbau, Meldungen schwerer zuzuordnen) |

## Tests

Swift Testing wie gewohnt: Footer ohne Version für `nav == nil`; Review-Daten im Import (Web + API); Kandidaten-Markup
(TMDB-Link, Übernehmen-Knopf); Webhook-Schlüssel ohne Passwort (Web + API, `currentPassword` ignoriert); Genre-Mapping
(Mischgenres, unbekannte IDs), Speichern beim Refresh, Nachladen, Cache-Löschen nach 180 Tagen, Bibliotheksfilter
(Web + API, Isolation); Folgen-Markup (zu, nach „Gesehen“ offen); Staffel/Serie mit Dienst; System-Seite öffnet den
Block der Aktion.

## Doku

`docs/import.md` (Netflix-Pfad, Daten bei „Zu prüfen“), `docs/sso.md` (Pocket ID), `docs/notifications.md` und
`docs/app-api.md` (Webhook-Schlüssel ohne Passwort, Genres, `genre`-Filter), `openapi.yaml`-Beschreibungen. Die Regel
im Notifications-Spec wird mit Verweis auf dieses Dokument angepasst.

## Dem Builder überlassen

Genaue Gestaltung (Abstände, Overlay-Größe auf dem Handy, Platz der Genre-Auswahl), deutsche Genre-Namen im Detail,
Reihenfolge der Umsetzung.
