# WatchSwifty – Statistik erweitern (Kurz-Design)

Stand: 2026-11-13 · Status: vom Nutzer freigegeben · Ergänzt `2026-11-13-feedback-round-design.md` (Genres)

**Warum:** Die Statistik zeigt Zeit, Dienste und die Top-Serien nach Zeit. Der Nutzer möchte sehen, was er am häufigsten
und am längsten gesehen hat, und wie sich das auf Genres verteilt.

## Umfang [Nutzer, Antworten vom 2026-11-13]

Alle neuen Blöcke folgen dem Jahresfilter der Seite (zählen nur Sichtungen im gewählten Jahr) – **außer „komplett
gesehen“**, das immer über alle Jahre zählt (Hinweis „über alle Jahre“). Listen zeigen je höchstens 5 Einträge
*(Entscheidung Claude, wie die bestehende Top-Serien-Liste)*; leere Listen werden nicht angezeigt.

1. **„Längste Serien“** – der bisherige Block „Meistgesehen“, nur umbenannt: Serien nach Gesamtdauer aller gesehenen
   Folgen (Wiederholungen eingeschlossen), mit Folgenzahl, Zeit, Bewertung.
2. **„Längste Filme“** – Filme nach Dauer aller Sichtungen (Laufzeit × Sichtungen): „2× · 4 Std. 32 Min.“. Filme ohne
   bekannte Laufzeit erscheinen hier nicht.
3. **„Meistgesehene Filme“** – Filme nach Anzahl Sichtungen, nur ab 2 Sichtungen *(Claude: sonst wäre die Liste bei
   lauter 1× beliebig)*: „3×“.
4. **„Meistgesehene Folgen“** – einzelne Folgen nach Anzahl Sichtungen, ab 2: „Serie · S01E05 Titel · 3×“, Link zur
   Serie.
5. **„Meistgesehene Serien“** – wie oft eine Serie komplett gesehen wurde: jede **erschienene reguläre Folge**
   (Staffel ≥ 1, Ausstrahlungsdatum ≤ heute; Specials zählen nicht) mindestens n× gesehen = n× komplett. Laufende Serien
   zählen mit. Nur Serien mit mindestens 1× komplett: „2× komplett“.
6. **„Dienste“** – wie bisher Zeit und Anteil, dazu die Anzahl gesehener Folgen und Filme: „12 Std. · 45 % · 80 Folgen ·
   3 Filme“. Ein Dienst erscheint auch, wenn nur Sichtungen ohne bekannte Laufzeit vorliegen.
7. **„Genres“** – pro Genre ein Balken mit Serien- und Filmzeit (gestapelt, Farben wie im Zeitdiagramm) und „N Serien ·
   M Filme“ (verschiedene Titel); sortiert nach Zeit. Ein Titel zählt bei jedem seiner Genres, die Summe ist daher größer
   als die Gesamtzeit (Hinweis darunter). Titel, deren Genres noch nicht geladen sind, zählen nicht.

**App-API** (`GET /v1/stats`): neue Felder, alle optional (ältere Server senden sie nicht): `longestMovies`,
`mostWatchedMovies` (Schema `MovieStat`: tmdbId, name, posterPath, watches, minutes, rating), `mostWatchedEpisodes`
(`EpisodeStat`: tmdbId der Serie, seriesName, posterPath, season, number, name, watches), `mostCompletedSeries`
(`CompletedSeries`: tmdbId, name, posterPath, completions, rating), `genres` (`GenreStat`: genre, seriesMinutes,
movieMinutes, series, movies); `ServiceShare` bekommt `episodes` und `movies`.

**Nicht-Ziele:** eigene Seite pro Liste, Filter nach Dienst oder Genre, Statistik in der iOS-App.

## Ansätze

| Thema | Gewählt | Verworfen |
|---|---|---|
| Berechnung | im bestehenden `StatsService.stats` aus denselben geladenen Sichtungen; für „komplett“ zusätzlich die Folgen der gesehenen Serien laden | eigene Abfragen pro Block (mehr Datenbankzugriffe, doppelte Regeln) |
| „komplett“ | Minimum der Sichtungen über alle erschienenen regulären Folgen | pro Staffel zählen (passt nicht zu „Serie komplett“); nur beendete Serien (Nutzer: laufende zählen mit) |

## Tests

`StatsTests`: je Liste Reihenfolge, Grenze 5, Schwelle ab 2, Jahresfilter (außer „komplett“), „komplett“ mit
unerschienener Folge und Special, Genres mit Mehrfach-Genre und ungeladenen Genres, Dienste mit Anzahl. API: Felder im
`GET /v1/stats`; Client dekodiert eine Antwort ohne die neuen Felder.

## Dem Builder überlassen

Anordnung der Blöcke im Raster, genaue Texte der Hinweise, Poster in den Listen.
