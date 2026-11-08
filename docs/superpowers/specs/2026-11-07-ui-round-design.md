# WatchSwifty – UI-Runde 1 (Kurz-Design)

Stand: 2026-11-07 · Status: vom Nutzer freigegeben · Ergänzt `2026-11-07-watchswifty-design.md`

**Warum:** Erster manueller Test war positiv („schon mal super“); es fehlen einige Funktionen und
der Feinschliff für Smartphone, Branding und Rückmeldung beim Laden.

## Umfang [entschieden]
1. **„Gesamte Serie gesehen“** – Button über den Staffeln; hakt alle erschienenen regulären Folgen ab
   (ohne Datum, Dienst wie zuletzt genutzt) – analog „Ganze Staffel gesehen“.
2. **Kommentare** – privat pro Benutzer: einer pro Serie (oben bei der Bewertung), einer pro Staffel
   (in der aufgeklappten Staffel), einer pro Film. Textfeld + „Speichern“, max. 2.000 Zeichen,
   leer = löschen.
3. **„WatchSwifty“** als Tab-Titel-Suffix und Markenname in der Kopfleiste.
4. **Login** – Formular horizontal und vertikal mittig.
5. **Smartphone** – unter 700 px wird das Menü zum Burger-Menü (reines CSS, kein JS); Desktop bleibt
   unverändert. Karten stapeln, Verlauf als Karten statt Tabelle, Formulare volle Breite.
6. **Design** – nur leichte Politur im Zuge von 5 (Nutzer: „eigentlich schon voll in Ordnung“).
7. **Ladebalken** – dünner Balken oben bei jeder htmx-Anfrage; Links aus Suche, Bibliothek und
   Weiterschauen laden per `hx-boost`, damit der Balken auch beim Öffnen einer Serie erscheint.
8. **Kandidaten-Button** auf der Import-Seite: „Titel (Jahr) · Übernehmen“ (ohne „Film“/„Serie“);
   sonst unverändert.
9. **Footer** auf jeder Seite: mittig „Built with Swift and Vapor with ❤️“ (Swift → swift.org,
   Vapor → vapor.codes), rechts „GitHub“ → https://github.com/PaddXy95/watchswifty; mobil untereinander.
10. **Git-Remote** `origin` = `https://github.com/PaddXy95/watchswifty.git` (kein Push). Image-Name
    `ghcr.io/paddxy95/watchswifty` (GHCR verlangt Kleinbuchstaben) in Compose und README.
11. **README** mit ausführlicher Anleitung für `docker run` und Docker Compose (Start, erster Admin,
    Token, Update, Backup, Reverse-Proxy, selbst bauen).

## Ansätze
| Thema | Gewählt | Verworfen |
|---|---|---|
| Burger-Menü | CSS-Checkbox-Toggle, nur unter 700 px sichtbar | JavaScript (App hat bewusst kein eigenes JS); `<details>` (lässt sich am Desktop nicht sauber offen halten) |
| Ladeanzeige | htmx-Indikator auf `body` + `hx-boost` für Detail-Links | eigenes JS für Navigation |
| Staffel-Kommentare | eigene Tabelle `season_notes` (user, title, season) | Spalte am Episoden-Cache (gemeinsame Daten, nicht pro Benutzer) |

## Dem Builder überlassen
Genaue Breakpoints/Abstände, Animation des Ladebalkens (mit `prefers-reduced-motion` statisch),
Platzierung der Kommentar-Felder im Detail.

## Nachtrag: Neue-Folgen-Erinnerung für beobachtete Serien [entschieden: bewusst markieren]
- Schalter „🔔 Beobachten“ / „Nicht mehr beobachten“ auf der Serienseite (pro Benutzer).
- Startseite: Kasten „Neue Folgen“ rechts (mobil oberhalb der Karten), nur für beobachtete Serien,
  auch wenn sie ausgeblendet oder länger als 3 Monate pausiert sind. [entschieden]
- „Neu“ = erschienene, ungesehene reguläre Folge, deren Ausstrahlung nach dem spätesten von
  Beobachten-Start, letzter datierter Sichtung und letztem „Erledigt“ liegt (Rückstand zählt nicht). [Vorschlag]
- Hinweis verschwindet beim Sehen der neuen Folgen oder per „Erledigt“; neue Folgen danach lassen ihn
  wieder erscheinen. [Vorschlag]
- Täglicher TMDB-Abgleich bezieht beobachtete Serien auch dann ein, wenn sie ausgeblendet sind. [Vorschlag]

## Nachtrag: Versionierung [entschieden: in der App sichtbar]
- SemVer über Git-Tags `vX.Y.Z`; Startversion 0.1.0 [Vorschlag, nicht widersprochen]. Die GitHub Action baut bei
  Tags zusätzlich `ghcr.io/paddxy95/watchswifty:X.Y.Z` und `:X.Y`.
- Version und Commit werden als `APP_VERSION`/`GIT_COMMIT` ins Image geschrieben; Footer links zeigt
  „vX.Y.Z“ (Link zum GitHub-Release), Branch-Builds „main (abc1234)“, lokale Builds „dev“. `GET /version` liefert
  `{"version": …, "commit": …}` ohne Login.
- `CHANGELOG.md` (deutsch) pro Version; README: Version festpinnen, Release erstellen.

## Nachtrag: Statistik [entschieden]
- Neuer Menüpunkt „Statistik“ (`/stats`, nach „Bibliothek“), nur eigene Daten.
- **Insgesamt:** gesehene Filme, gesehene Serien (mind. eine Folge), gesehene Folgen, verbrachte Zeit.
- **Pro Jahr** (nach Sichtungsdatum): Filme, Serien, Folgen, Zeit mit schlichtem Balken; ein Jahr lässt sich
  aufklappen und zeigt die Monate. Eine Serie zählt in jedem Jahr/Monat, in dem mindestens eine Folge
  gesehen wurde. Sichtungen ohne Datum zählen insgesamt mit und stehen als eigene Zeile „ohne Datum“. [entschieden]
- **Nach Bewertung:** je Note 10 … 1 und „ohne Bewertung“ Filme, Serien und Zeit, wahlweise auf ein Jahr
  eingegrenzt. [entschieden]
- **Zeit** [entschieden: anzeigen]: aus den TMDB-Laufzeiten (Film: `runtime`; Folge: `runtime` der Folge,
  sonst typische Folgenlänge der Serie `episode_run_time`). [Vorschlag] Laufzeiten werden im Katalog
  gespeichert (`nil` = noch nicht geladen, `0` = TMDB kennt keine); bereits gespeicherte Titel holen sie
  einmalig im Hintergrund nach (und beim Öffnen der Detailseite). Sichtungen ohne bekannte Laufzeit
  werden nicht mitgezählt und als Hinweis ausgewiesen.
- Zählweise [Vorschlag]: Filme und Serien je Zeitraum eindeutig; Folgen = Sichtungen inkl. erneut
  gesehen; Zeit = alle Sichtungen (erneut gesehen zählt doppelt). Ausgeblendete Titel zählen mit.

## Nachtrag: TMDB-Tokens verschlüsselt speichern [entschieden: Server-Schlüssel]
- Tokens werden mit AES-GCM (swift-crypto) verschlüsselt in `users.tmdb_token` gespeichert (`enc:v1:` + Base64).
  Schützt eine abhandengekommene DB-Datei bzw. ein SQLite-Backup; Hintergrund-Jobs laufen weiter. [entschieden]
- Abgelehnt: Schlüssel aus dem Passwort-Hash (liegt selbst in der DB) bzw. aus dem Klartext-Passwort (Jobs nur bei
  eingeloggtem Nutzer); Verschlüsselung aller Nutzerdaten (Abfragen, Jobs, Datenverlust bei Passwort-Reset).
- Schlüssel [Vorschlag]: `TOKEN_KEY` (Base64, 32 Byte) oder `TOKEN_KEY_FILE` (z. B. Docker-Secret); ohne beides
  wird einmalig `token.key` neben der Datenbank erzeugt (Hinweis im Log). Ungültiger Schlüssel → Start bricht ab.
- Bestehende Klartext-Tokens werden beim Start verschlüsselt. Nicht entschlüsselbarer Token (Schlüssel gewechselt)
  gilt als fehlend; Konto zeigt „Token nicht lesbar – bitte neu eintragen“.

## Nachtrag: Hinweis auf neue Versionen [entschieden: in der App, abschaltbar, „Jetzt prüfen“]
- Neue Admin-Seite „System“ (`/admin/system`): installierte Version, Abschnitt „Updates“ mit Hinweis, dass dafür
  die GitHub-API (api.github.com) abgefragt wird (GitHub sieht die Server-IP, keine WatchSwifty-Daten), Schalter
  „Automatisch alle 12 Stunden prüfen“ und Button „Jetzt prüfen“. [entschieden]
- Standard: aus (keine Anfrage an GitHub ohne Zustimmung des Admins). Einschalten prüft sofort einmal. [Vorschlag]
- Ergebnis wird gespeichert (letzte Prüfung, neueste Version, Link zu den Release-Notes, Fehler). Ist eine neuere
  Version da, zeigt die Seite die Update-Befehle und der Footer zeigt Admins „Update auf vX.Y.Z verfügbar“. [Vorschlag]
- Aktualisieren bleibt Handarbeit (`docker compose pull && docker compose up -d`); die App tauscht sich nicht selbst aus.

## Nachtrag: Import einer eigenen Filmliste (CSV aus Numbers) [entschieden]
Vorlage: Nutzer-Tabelle mit Kopfzeile `;Filmname;Erscheinungsjahr;Genre;Datum;Mit Ela;Mit Martin;Streamingdienst;
Übeltäter;Bewertung;Detail;Bemerkung`, Gruppenzeilen „5 ★“ usw. (ohne Filmname), Häkchen als WAHR/FALSCH,
Datum wie „Mo., 1. Jan. 2024“, Bewertung in Sternen (0,5–5) und „Detail“ 0–100.
- „Mit …“-Spalten, „Übeltäter“ und „Bemerkung“ landen im Kommentar zum Film. [entschieden]
- Bewertung: „Detail“ 0–100 → 1–10 (gerundet, mindestens 1, weil die App 1–10 kennt); fehlt sie, Sterne × 2. [entschieden, Rundung Vorschlag]
- Steht ein Film mehrfach mit Datum drin, wird jede Zeile eine Sichtung mit ihrem Datum. [entschieden]
- [Vorschlag] Eigene Seite „Filmliste“ (`/import/films`, verlinkt von „Import“). Die Zuordnung zu TMDB läuft im
  Hintergrund mit dem eigenen Token (Titel + Erscheinungsjahr ±1; eindeutiger Treffer → automatisch). Unklare Filme
  erscheinen mit Vorschlägen („Titel (Jahr) · Übernehmen“), anderem Suchbegriff oder „Überspringen“.
- [Vorschlag] Kommentar: „Mit Ela und Martin“, „Übeltäter: Patrick“, Bemerkung – je Zeile; bei mehreren Zeilen mit
  Datum davor. Vorhandener Kommentar wird ergänzt, nicht ersetzt. Dienste: Netflix, Amazon Prime → Prime Video,
  Disney+, AppleTV+, WowTV → WOW, Gekauft, Kino; Unbekanntes (YouTube, Geliehen) → Sonstiges.
- [Vorschlag] Erneuter Import legt keine doppelten Sichtungen an (gleicher Film, Datum ±1 Tag bzw. schon eine ohne
  Datum). Unlesbare/zukünftige Daten → Sichtung ohne Datum.

## Nachtrag: TMDB-Bedingungen (Cache höchstens 6 Monate, Attribution) [entschieden]
TMDB API Terms: keine TMDB-Daten länger als 6 Monate zwischenspeichern; TMDB-Logo und Hinweis „… nicht von TMDB
unterstützt …“ sind Pflicht.
- **Frist 60 Tage** [entschieden]: Täglich wird jeder Titel, dessen letzter TMDB-Abgleich älter als 60 Tage ist, neu
  geholt (höchstens 200 pro Tag, älteste zuerst).
- **Token** [entschieden]: immer der Token eines Benutzers, der den Titel nutzt (Sichtung, Bibliothek/Beobachten,
  Netflix-Zuordnung, Filmliste) – nie der Token eines Unbeteiligten.
- [Vorschlag] Titel, die niemand nutzt, werden nach 60 Tagen gelöscht. Hat kein Nutzer des Titels einen Token, werden
  nach 6 Monaten Klappentexte, IMDb-ID und Laufzeiten geleert (Name, Folgen und Sendedaten bleiben für den Verlauf).
- [Vorschlag] Gespeicherte Vorschlagslisten (Netflix „Zu prüfen“, Filmliste) werden nach 60 Tagen verworfen; man
  sucht dann neu.
- **Footer rechts** [entschieden]: statt „GitHub“ das offizielle TMDB-Logo (kleiner als der Markenname, Link zu
  themoviedb.org) mit dem Hinweis „Diese Anwendung verwendet TMDB und die TMDB-APIs, ist aber nicht von TMDB
  unterstützt, zertifiziert oder anderweitig genehmigt.“
