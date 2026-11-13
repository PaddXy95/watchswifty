# WatchSwifty – Alle Daten von TMDB neu laden (Kurz-Design)

Stand: 2026-11-13 · Status: Entwurf · Ergänzt `2026-11-13-feedback-round-design.md` (Genres)

**Warum:** Nach einem Update mit neuen Daten (0.5.0: Genres) oder nach Korrekturen bei TMDB will man sofort alle eigenen
Serien und Filme neu laden, statt auf den täglichen Lauf zu warten oder jede Detailseite einzeln zu öffnen. Heute lädt
der tägliche Lauf fehlende Genres/Laufzeiten nur für gesehene Titel nach, beendete Serien und Filme werden sonst erst
nach 60 Tagen neu geholt.

**Nicht-Ziele:** Admin-Knopf „Täglichen Lauf jetzt starten“ (Ansatz B, verworfen); Knopf für einen einzelnen Titel
(die Detailseite lädt bei Bedarf schon nach); Fortschritt über einen Neustart hinweg; Benachrichtigungen auslösen.

## Umfang

1. **Knopf** „Alle Daten von TMDB neu laden“ unter **Konto** *(Nutzer: pro Nutzer, Serien und Filme, „alle Daten“,
   im Konto)*, im Block „TMDB-Token“ unter dem Token-Formular mit einem Satz Erklärung *(Claude: der Lauf nutzt diesen
   Token)*. Nach dem Start bleibt der Block offen (Block der letzten Aktion, wie die übrigen Konto-Blöcke).
2. **Welche Titel:** alle eigenen Titel – gesehene und alle Einträge in `user_titles` (bewertet, ausgeblendet, nur
   beobachtet) –, Serien und Filme, auch bei TMDB beendete *(Claude)*. Reihenfolge: zuerst
   Titel mit fehlenden Genres oder Laufzeiten, dann der Rest *(Claude: die neuen Daten sind am schnellsten da)*.
3. **Token:** der eigene TMDB-Token des Nutzers (`req.tmdb`). Ohne Token startet nichts; Meldung wie überall:
   „Kein TMDB-Token hinterlegt – bitte unter Konto eintragen.“
4. **Hintergrund:** Der Lauf blockiert keine Anfrage (300 Titel ≈ 1.000 TMDB-Anfragen, bei 20/s gemeinsamem Budget
   ein bis drei Minuten). Pro Nutzer höchstens ein Lauf; ein Klick während des Laufs zeigt nur den Stand. Ein
   fehlgeschlagener Titel wird gezählt, der Lauf geht weiter; ein ungültiger Token (401) bricht ab und zeigt die
   Meldung. Nach jeder Serie wie im täglichen Lauf `requeueUnmatchedRows`, am Ende `matchingWorker.kick()` *(Claude)*.
5. **Fortschritt:** Der Knopf wird zur Statuszeile „Lädt neu … 37 von 212“, htmx fragt alle 2 s nach (wie Import und
   Filmliste). Danach „Fertig: 212 Titel neu geladen, 2 fehlgeschlagen“ mit Link „Zur Bibliothek“ und wieder dem
   Knopf. Der Stand lebt nur im Speicher; nach einem Neustart ist er weg und der Lauf lässt sich neu starten *(Claude)*.
6. **App-API** *(Nutzer: „muss mit erweitert werden, falls betroffen“)*: `POST /v1/library/refresh` startet einen Lauf
   oder liefert den laufenden (202), `GET /v1/library/refresh` liefert den Stand. Schema `LibraryRefresh`: `running`,
   `done`, `total`, `failed`, optional `finishedAt`, `error`. Ohne Token 422 `missingTMDBToken` (gibt es schon).

## Ansätze

| Thema | Gewählt | Verworfen |
|---|---|---|
| Wer | jeder Nutzer für die eigene Bibliothek, mit eigenem Token | Admin startet den täglichen Lauf (nur Admins, lädt nur Fehlendes und laufende Serien nach, verschickt fällige Benachrichtigungen) |
| Wie | Hintergrundlauf in einem Actor im `Application.storage`, Status per htmx-Polling | synchron in der Anfrage (Hunderte TMDB-Anfragen, Timeout im Browser und hinter Proxys) |

## Release *(Claude)*

Zusammen mit dem Fix für den Update-Hinweis (Branch `fix/update-notice`) als **0.6.0** (neue Funktion → Minor);
der CHANGELOG-Abschnitt `0.5.1` wird zu `0.6.0`.

## Tests

Swift Testing mit `FakeTMDBClient`: Auswahl der Titel (Serien, Filme, ausgeblendete, nur eigene), Reihenfolge,
Fortschritt und Endstand, Fehler eines Titels zählt und läuft weiter, 401 bricht ab, kein zweiter Lauf parallel,
ohne Token keine Anfrage; Web (Knopf, Statuszeile, Polling) und API (`POST`/`GET`, 422, Isolation).

## Doku

`docs/tmdb.md` (Abschnitt zum Cache: manuelles Neuladen), `docs/app-api.md`, `openapi.yaml`, CHANGELOG.

## Dem Builder überlassen

Gestaltung im Block „TMDB-Token“, Texte im Detail, Aufbau des Actors.
