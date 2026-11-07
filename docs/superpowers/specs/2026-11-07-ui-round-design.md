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
