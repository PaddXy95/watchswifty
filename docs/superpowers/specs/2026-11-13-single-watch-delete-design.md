# Einzelne Sichtungen löschen – Design

Kleine Änderung, Stand 2026-11-13.

## Warum

Wer eine Folge oder einen Film mehrfach gesehen hat, kann heute nur alle Sichtungen auf einmal löschen: Der Haken
links an der Folge löscht ohne Rückfrage alle Sichtungen der Folge, „Nicht gesehen“ auf der Filmseite alle des Films.
Einzelne Sichtungen gehen nur im **Verlauf**. Ziel: gezielt eine Sichtung (ein Datum) löschen, dort wo man die Folge
oder den Film sieht – und nicht mehr versehentlich alle.

## Ziele

- In den Details einer gesehenen Folge: Liste ihrer Sichtungen (Datum · Dienst, neueste zuerst), je mit „Löschen“.
- Auf der Filmseite: dieselbe Liste mit „Löschen“ je Sichtung.
- Links an der Folge kein Löschen mehr: gesehene Folgen zeigen ein grünes Häkchen (nur Anzeige).
- Ungesehene, erschienene Folgen: leerer Kreis, ein Klick markiert sie wie bisher als heute gesehen (zuletzt genutzter
  Dienst).

## Nicht-Ziele

- Sichtungen hier bearbeiten (Datum/Dienst ändern) – das bleibt im **Verlauf**.
- Änderungen an der App-API: `DELETE /v1/watches/{id}` gibt es schon; `unmarkEpisode`/`unmarkMovie` bleiben.

## Anti-Ziele

- Ein Klick, der unbemerkt mehrere Sichtungen löscht.
- Mehr Klicks fürs Markieren einer Folge als heute.

## Ansätze

1. **Kreis klickbar, Löschen in den Details** (gewählt): links Häkchen bzw. klickbarer Kreis; Löschen nur über die
   Liste in den Details. Markieren bleibt ein Klick, Löschen ist immer gezielt.
2. **Nur Häkchen, Markieren nur über die Details:** am aufgeräumtesten, aber jede Folge braucht Aufklappen plus Klick.
3. **Checkbox behalten, beim Abhaken eine Auswahl der Sichtungen zeigen:** kleinste Änderung, aber das Abhaken bleibt
   eine Löschaktion, und bei einer einzigen Sichtung löscht es weiter ohne Rückfrage.

Patrick hat Ansatz 1 gewählt.

## Verhalten

- „Löschen“ fragt nach („Diese Sichtung löschen?“, wie im Verlauf) und löscht genau diese Sichtung. Netflix-Zeilen,
  die auf sie zeigen, werden wie beim Löschen im Verlauf `discarded`, damit ein neuer Import sie nicht zurückbringt.
- Nach dem Löschen wird bei Folgen die Staffel neu gezeigt, die Folge bleibt aufgeklappt; ist es die letzte Sichtung,
  ist die Folge wieder ungesehen (Kreis). Bei Filmen wird der Abschnitt „Gesehen“ neu gezeigt.
- Eine Sichtung eines anderen Nutzers, einer anderen Folge oder eines anderen Films ergibt 404.
- Noch nicht erschienene Folgen: ausgegrauter Kreis, nicht klickbar (wie die heutige gesperrte Checkbox).
- Filmseite: Der Knopf „Nicht gesehen“ (alle löschen) entfällt.

## Entscheidungen des Builders (Claude)

- Neue Web-Routen `DELETE /tv/:tmdbID/episodes/:season/:number/watches/:watchID` und
  `DELETE /movie/:tmdbID/watches/:watchID`; die alten Web-Routen `DELETE …/watch` (alle löschen) entfallen.
- Logik im `WatchService` (eine Sichtung eines bestimmten Titels/einer Folge löschen), damit Web und API sie teilen
  können.
- Kreis und Häkchen sind Buttons bzw. Elemente mit `aria-label` („S01E02 als gesehen markieren“, „gesehen“).
