# watchswifty – Design

Stand: 2026-11-07 · Status: vom Nutzer freigegeben (2026-11-07)

Selbst gehosteter Serien- und Film-Tracker in Swift (Vapor 4, Fluent, Elementary + htmx). Ersetzt das
nicht mehr gepflegte Open-Source-Projekt *vod-tracker* (`~/Downloads/tv-tracker-main`,
NestJS + Next.js), das nur als Referenz für Ideen dient – es wird kein Code portiert.

Markierung in diesem Dokument:
- **[entschieden]** – vom Nutzer so festgelegt
- **[Vorschlag]** – von Claude vorgeschlagen, vom Nutzer nicht widersprochen bzw. noch zu bestätigen
- **[Builder]** – bewusst dem Umsetzenden überlassen

---

## 1. Warum

Das bisherige Tool ist fehleranfällig und wird nicht mehr gepflegt. Sein größter
Schwachpunkt: Es loggt sich per ferngesteuertem Chromium bei Streamingdiensten ein und
liest private APIs bzw. das gerenderte HTML aus. Das bricht bei jeder Änderung der Dienste.

watchswifty soll **relativ simpel** sein und eine Frage beantworten: *Was schaue ich als
Nächstes weiter?* Dazu kommt ein manuelles Logbuch: Serien und Filme selbst suchen, als
gesehen markieren und persönlich bewerten.

## 2. Ziele, Nicht-Ziele, Anti-Ziele

### Ziele (v1)
1. **Netflix-Import** – die Sofort-CSV aus Netflix („Wiedergabeaktivität → Alle
   herunterladen“, Datei `NetflixViewingHistory.csv`) hochladen; wiederholte Importe sind
   idempotent. **[entschieden]**
2. **Manuell suchen & markieren** – Serien und Filme über TMDB suchen, Serien **pro Folge**
   als gesehen markieren, Filme als gesehen markieren, **persönliche Bewertung**.
   **[entschieden]** Beim Markieren lassen sich ein **früheres Datum** und **wo** geschaut
   wurde (Dienst/Kino) angeben, auch erneutes Sehen. **[entschieden: „ja soll man“]**
3. **Weiterschauen** – eine Karte pro Serie mit der nächsten Folge. **[entschieden]**
4. **Verlauf** – chronologische Liste auf Folgen-/Filmebene. **[entschieden]**
5. **Ausblenden** – Serie aus Weiterschauen entfernen. **[entschieden]** (aus der
   Funktionsliste übernommen, nicht widersprochen; gilt nur für Serien, s. 5.2)
6. **Benutzerkonten mit Login** – mehrere Benutzer mit **getrennten Daten** (Häkchen,
   Bewertungen, Ausblendungen, Netflix-Import); ein **Admin legt weitere Konten an**.
   **[entschieden]** Login mit Benutzername + Passwort, weil die App auf einem Server im
   Netzwerk läuft.

### Nicht-Ziele (v1)
- Live-Sync, Browser-Automatisierung, Scraping, private Provider-APIs **[entschieden]**
- Andere Dienste (Prime, Disney+, Apple TV, Max, Jellyfin) **[entschieden]** – Prime- und
  Disney+-Import sind Kandidaten für später, sobald echte Exportdateien vorliegen.
- Browser-Extension, Home Assistant/MQTT, MCP, JustWatch-Export **[entschieden]**
- Watchlist, kommende Premieren, Statistiken **[entschieden: später]**
- Selbstregistrierung, Passwort-vergessen-per-Mail, Teilen von Daten zwischen Benutzern
  **[Vorschlag]**
- Fortschritt innerhalb einer Folge (die Sofort-CSV enthält ihn nicht) **[entschieden]**
- Übernahme von Daten aus dem alten vod-tracker **[entschieden]**

### Anti-Ziele – daran wäre v1 gescheitert, selbst wenn es „funktioniert“
- **Falsche Zuordnungen, die still den Bestand verschmutzen.** Lieber „nicht zugeordnet“
  als falsch zugeordnet. Automatisch übernommen wird nur, was eindeutig ist.
- **Datenverlust oder Duplikate bei erneutem Import.**
- **Daten eines Benutzers sind für einen anderen sichtbar oder änderbar** – auch der Admin
  sieht keine fremden Häkchen/Bewertungen, er verwaltet nur Konten.
- **Betriebsaufwand** wie beim Vorgänger: kein Redis, kein Node, kein zweiter Container.
- **Fragilität**: keine Abhängigkeit von Webseiten-Strukturen der Streamingdienste.

## 3. Rahmenbedingungen

| Thema | Festlegung |
|---|---|
| Sprache/Framework | Swift, **Vapor 4**, **Fluent** **[entschieden]** (Vapor 5 Beta bewusst verworfen, s. §4) |
| HTML | **Elementary** (HTML als Swift-Komponenten) **[entschieden]**, Version exakt gepinnt (vor 1.0, Breaking Changes zwischen Minor-Versionen; aktuell 0.9.0). Vapor-Anbindung über `vapor-elementary` oder eigenen dünnen Adapter **[Builder]** |
| Interaktivität | Server-gerendertes HTML + **htmx 2.x** (aktuell 2.0.11) mit **ElementaryHTMX** (`ElementaryHTMX2`, typisierte `hx`-Attribute), kein SPA, kein JS-Build **[entschieden: „HTML aus Swift“]**. Komponenten werden sowohl in Seiten als auch als htmx-Teilantworten verwendet. |
| Datenbank | **SQLite** über `fluent-sqlite-driver` (4.9.0) **[Vorschlag]** |
| Metadaten | **TMDB API v3**, Bearer-Read-Access-Token, Sprache `de-DE` – Pflicht, nicht optional |
| Betrieb | Docker-Container auf einem Linux-Server im Heimnetz, ein Volume für die DB **[entschieden: Server im Netzwerk]** |
| Entwicklung | Lokal vorhanden: Swift 6.4.2, macOS 27, Docker |
| Nutzer | Mehrere Benutzer mit getrennten Daten, Konten legt der Admin an **[entschieden]**; je Benutzer der Export *seines* Netflix-Profils |
| Projektname/Ort | `watchswifty` **[entschieden]**, `~/Downloads/watchswifty` **[Vorschlag]** |

## 4. Betrachtete Ansätze

### Frontend
| Ansatz | Trade-off | Ergebnis |
|---|---|---|
| **A: Server-gerendertes HTML + htmx** | Eine Sprache, ein Binary, ein Container. Aufwendige Client-Interaktion wäre mühsam – wird nicht gebraucht. | **gewählt** |
| B: JSON-API + SPA (React/Svelte) | Volle UI-Freiheit, API wiederverwendbar; aber zwei Codebasen, Node-Toolchain, doppelte Typen. Widerspricht „simpel“. | verworfen |
| Altes Next.js-Dashboard weiterverwenden | Zu eng an alte API gekoppelt, Altlast. | verworfen |

### Framework-Version
| Ansatz | Trade-off | Ergebnis |
|---|---|---|
| **Vapor 4** | Stabil, Fluent voll integriert, Sessions/Auth/Multipart eingebaut, gute Doku. Späterer Umstieg auf Vapor 5 = Umbau (für diese App-Größe überschaubar). | **gewählt** |
| Vapor 5 Beta (5.0.0-beta.4) | Zukunftssicher, aber: kein Leaf, Fluent-API „in flux“, keine Session-API, Multipart undokumentiert, nicht produktionsempfohlen. | verworfen |

### HTML-Erzeugung
| Ansatz | Trade-off | Ergebnis |
|---|---|---|
| **Elementary + ElementaryHTMX** | Fehler zur Compile-Zeit, Models direkt nutzbar, eine Komponente = Seitenteil und htmx-Antwort, typisierte htmx-Attribute, framework-unabhängig (zieht bei Vapor 5 mit). Markup-Änderung braucht Rebuild; vor 1.0. | **gewählt** |
| Leaf 4.5 | Offiziell, stabil, Templates im Dev-Modus ohne Rebuild änderbar. Aber Fehler erst zur Laufzeit, `Encodable`-Kontext pro Seite, kein htmx-Support, 2026 zwei Escaping-Lücken (gefixt ab leaf-kit 1.14.2), für Vapor 5 noch nicht verfügbar. | verworfen |

### Datenquelle Netflix
| Ansatz | Trade-off | Ergebnis |
|---|---|---|
| **Sofort-CSV (Title, Date)** | Sofort verfügbar, beliebig oft neu exportierbar, wird pro Netflix-Profil heruntergeladen – passt zu „ein Benutzer = ein Profil“. Kein Fortschritt innerhalb einer Folge, nur tagesgenaues Datum. | **gewählt** |
| Vollständiger DSGVO-Export (`ViewingActivity.csv`) | Profil, Uhrzeit, Abspielposition; dauert aber Tage bis Wochen pro Export und enthält alle Profile des Kontos in einer Datei. | verworfen |
| Live-Sync per gesteuertem Browser | Aktuell, aber genau die Fragilität, die ersetzt werden soll. | verworfen |

## 5. Was der Nutzer sieht

Navigation (Seitenleiste oder Kopfzeile): **Weiterschauen · Verlauf · Bibliothek · Suche ·
Import · Konto** und – nur für Admins – **Benutzer**. Alles, was ein Benutzer sieht und
ändert, sind ausschließlich *seine* Daten; nur der TMDB-Cache (Serien, Folgen, Poster) ist
gemeinsam.

### 5.1 Login
- Login-Seite mit Benutzername + Passwort. **[entschieden: User-Login]**
- Nach Login: Session-Cookie (Vapor `SessionsMiddleware` + `ModelSessionAuthenticatable` für
  das User-Model, Sessions in der DB via Fluent, damit ein Neustart nicht ausloggt), Laufzeit
  30 Tage, `HttpOnly`, `SameSite=Lax`. **[Vorschlag]**
- Alle Seiten außer Login und statischen Assets erfordern Login. Logout-Link.
- **Erster Admin [Vorschlag]:** Gibt es beim Start noch keinen Benutzer, legt die App aus
  `ADMIN_USERNAME` + `ADMIN_PASSWORD` einen Admin an. Existieren Benutzer, werden die Variablen
  ignoriert. (Keine offene Einrichtungsseite, damit niemand im Netz zuvorkommt.)

### 5.2 Weiterschauen (Startseite)
```
┌──────────┐  The Mentalist                         zuletzt 07.11.2026
│  Poster  │  Weiter mit S04E15 · „Der rote Faden“
│          │  noch 9 Folgen · zuletzt auf Netflix  ★ 8  [✓ gesehen] [Ausblenden]
└──────────┘
```
- Eine Karte pro Serie, sortiert nach letztem Ansehdatum (neueste zuerst). **[entschieden]**
- Regel **[Vorschlag]**: Eine Serie erscheint, wenn sie mindestens eine gesehene Folge hat,
  nicht ausgeblendet ist und es **nach der höchsten gesehenen Folge** (Reihenfolge Staffel,
  Folge; Staffel 0/Specials ignoriert) mindestens eine bereits ausgestrahlte, ungesehene Folge
  gibt. Diese erste Folge ist die „nächste Folge“. Lücken *vor* der höchsten gesehenen Folge
  zählen nicht – sie sind nur auf der Detailseite sichtbar.
- Serien ohne nächste Folge („aufgeholt“) erscheinen nicht; sobald TMDB eine neue Folge
  meldet, tauchen sie wieder auf.
- Filme erscheinen hier nicht (kein Fortschritt bekannt). Ausblenden gibt es deshalb nur für
  Serien. **[Vorschlag]**
- **Ausblenden** gilt, bis man die Serie in der Bibliothek wieder einblendet. Ein Import
  blendet nicht wieder ein; ein manuelles Abhaken einer Folge dieser Serie schon (bewusste
  Handlung). Beim Wiedereinblenden werden die TMDB-Daten sofort aktualisiert, weil der
  tägliche Lauf ausgeblendete Serien überspringt. **[Vorschlag]**
- **[✓ gesehen]** markiert die nächste Folge mit heutigem Datum und dem Dienst der letzten
  Sichtung dieser Serie (htmx, Karte aktualisiert sich). **[Vorschlag]**
- Klick auf die Karte → Detailseite. Link „Auf Netflix suchen“ nur, wenn Netflix-Daten zu
  dieser Serie existieren (`https://www.netflix.com/search?q=<Serienname>`), weil der Export
  keine Netflix-IDs enthält.

### 5.3 Verlauf
- Chronologisch absteigend: Datum · Serie + SxxEyy + Folgentitel bzw. Film · Dienst · Herkunft
  (Import/manuell).
- Jeder Eintrag lässt sich bearbeiten (Datum, Dienst) und löschen. Beim Löschen einer
  importierten Sichtung werden ihre Netflix-Zeilen „verworfen“ (wie beim Haken-Entfernen).
  **[Vorschlag]**
- Paginierung oder „Mehr laden“ (htmx). **[Builder]**
- Einträge ohne Datum (Sammelmarkierungen, s. 5.5) erscheinen nicht im Verlauf. **[Vorschlag]**

### 5.4 Bibliothek **[Vorschlag – nicht explizit gewünscht, aber nötig, um Bewertungen wiederzufinden]**
- Alle Titel, die mindestens eine Markierung oder Bewertung haben, als Poster-Raster.
- Filter: Serien / Filme / Ausgeblendet. Sortierung: zuletzt gesehen / Bewertung / Name.
- Ausgeblendete Titel lassen sich hier wieder einblenden.

### 5.5 Detailseite (Serie)
```
The Mentalist (2008)        ★ Bewertung: [ 1 … 10 ▾ ]     [Ausblenden]
Staffel 4  ▸ 12/24 gesehen                      [Ganze Staffel gesehen]
  ☑ 1  Scharlachrote Briefe        12.10.2026
  ☑ 2  …
  ☐ 13 Der rote Faden                          [bis hier gesehen]
Staffel 5  ▸ 0/22 gesehen
```
- Daten (Staffeln, Folgen, Ausstrahlungsdaten, Poster) aus TMDB, lokal zwischengespeichert.
- Staffeln aufklappbar; die Staffel mit der nächsten Folge ist standardmäßig offen.
- **Folge abhaken** → gesehen mit heutigem Datum und dem zuletzt für diese Serie genutzten
  Dienst. **[entschieden: pro Folge; Standardwerte: Vorschlag]**
- **Details** (kleines Menü je Folge): Formular mit Datum (Standard heute, frühere Daten
  erlaubt, keine zukünftigen) und Dienst. Dasselbe Formular dient für **„Erneut gesehen“** bei
  bereits gesehenen Folgen – es legt eine weitere Sichtung an. **[entschieden: Datum + Ort;
  Bedienung: Vorschlag]**
- **Dienste** sind eine feste Liste im Code: Netflix, Prime Video, Disney+, Apple TV+, Kino,
  Sonstiges; „unbekannt“ ist erlaubt. **[Vorschlag]**
- **Haken entfernen** → alle Sichtungen dieser Folge werden gelöscht – auch importierte. Die
  zugehörigen Netflix-Zeilen werden als „verworfen“ markiert, damit ein erneuter Import sie
  nicht wieder anlegt. **[Vorschlag]**
- **„Ganze Staffel gesehen“** und **„bis hier gesehen“** (alle ausgestrahlten, ungesehenen
  Folgen bis einschließlich dieser) → Markierung **ohne Datum**, Dienst optional wählbar.
  Gedacht für Serien, die man mittendrin zu tracken beginnt. **[Vorschlag]**
- Noch nicht ausgestrahlte Folgen werden angezeigt, sind aber nicht abhakbar.
- Bei mehrfach gesehenen Folgen: Haken + Datum der letzten Sichtung, Anzahl als kleiner Hinweis.

### 5.6 Detailseite (Film)
- Poster, Jahr, Bewertung, Button „Gesehen“ (öffnet dasselbe Formular wie bei Folgen: Datum,
  Dienst – z. B. „Kino, letzten Samstag“) bzw. „Nicht gesehen“ (löscht alle Sichtungen).
- Liste der eigenen Sichtungen dieses Films mit Datum und Dienst; „Erneut gesehen“ legt eine
  weitere an. **[entschieden: Datum + Ort; Darstellung: Vorschlag]**

### 5.7 Bewertung
- **Pro Serie bzw. pro Film, Skala 1–10**, optional, jederzeit änderbar oder entfernbar. **[Vorschlag]**
- Bewerten geht auch ohne Markierung.

### 5.8 Suche
- Ein Suchfeld, Ergebnisse während der Eingabe (htmx, entprellt) aus TMDB – Serien und Filme
  gemischt, mit Poster, Jahr, Typ und eigenem Status (z. B. „12/24 gesehen“, „★ 8“).
- Klick → Detailseite. Ein Titel landet erst beim ersten Markieren oder Bewerten in der
  Bibliothek des Benutzers. **[Vorschlag]**

### 5.9 Import
Vier Bereiche auf einer Seite:
1. **Upload** – CSV wählen und hochladen; danach Zusammenfassung „N neu, M bereits bekannt,
   K übersprungen (leerer Titel)“ und ein Fortschrittsbalken für die Zuordnung (htmx-Polling).
2. **Zu prüfen** – Serien-/Filmnamen aus Netflix, für die keine eindeutige TMDB-Zuordnung
   gefunden wurde. Je Eintrag: Netflix-Name, Anzahl Zeilen, Top-Kandidaten aus TMDB mit Poster
   und Jahr, ein Suchfeld für eigene Suche, Aktionen „Übernehmen“ und „Ignorieren“.
3. **Nicht zugeordnet** – einzelne Netflix-Zeilen, deren Serie bekannt ist, deren Folge aber
   nicht gefunden wurde (oder deren Titel keiner Serie/keinem Film zuzuordnen war). Je Zeile:
   Rohtitel, Datum, Auswahl der Folge (Staffel/Folge der zugeordneten Serie) oder „Ignorieren“.
4. **Zuordnungen** **[Vorschlag – Korrekturweg für falsche Treffer, s. Anti-Ziele]** – Liste
   aller Netflix-Namen mit ihrer TMDB-Zuordnung (automatisch / bestätigt / ignoriert), filterbar.
   Je Eintrag „Ändern“ und „Zurücksetzen“: Die per Import entstandenen Sichtungen dieses Namens
   werden gelöscht, seine Zeilen gehen auf „ausstehend“ und werden mit der neuen Zuordnung
   (bzw. nach erneuter Prüfung) neu verarbeitet. Manuelle Sichtungen bleiben unberührt.

Import, Zuordnungen und „Nicht zugeordnet“ gehören jeweils dem Benutzer, der importiert hat.
Bestätigt ein Benutzer eine Zuordnung, wirkt das nicht bei anderen. **[Vorschlag]**

### 5.10 Benutzer (nur Admin) **[entschieden: Admin legt Konten an; Details: Vorschlag]**
- Liste aller Konten: Benutzername, Admin ja/nein, angelegt am.
- **Konto anlegen:** Benutzername, Startpasswort, Admin-Häkchen.
- **Passwort zurücksetzen** für ein Konto (Admin vergibt ein neues).
- **Admin-Recht** vergeben/entziehen.
- **Konto löschen** mit Bestätigung – löscht alle Daten dieses Benutzers (Sichtungen,
  Bewertungen, Importe, Zuordnungen). Der letzte Admin kann weder gelöscht noch herabgestuft
  werden; man kann sich nicht selbst löschen.
- Der Admin sieht keine Inhalte anderer Benutzer.

### 5.11 Konto
- Eigenes Passwort ändern (altes Passwort erforderlich). Mindestlänge 8 Zeichen. **[Vorschlag]**

## 6. Netflix-Import im Detail

### 6.1 Was die Datei enthält (analysiert am echten Export des Nutzers, 4.395 Zeilen, 10/2015–11/2026)
- Kopfzeile `Title,Date`, UTF-8, Felder in Anführungszeichen, ohne BOM.
- **Datum immer `M/D/YY`** (US-Format), obwohl die Titel deutsch sind. Jahr → `20YY`.
- Neueste Zeile zuerst. Eine Zeile = ein Titel an einem Tag.
- Titelmuster (Anteil am echten Export):

| Muster | Anteil | Beispiel |
|---|---|---|
| `Serie: Staffel N: Folge` | 64 % | `The Mentalist: Staffel 4: Die Aura des Todes` |
| `Serie: Folge` (ohne Staffel) | 14 % | `Pokémon: Pika-Pikachu`, `Keine Fremde: Folge 2` |
| ohne Doppelpunkt (meist Film) | 8 % | `Das fünfte Element` |
| Serienname mit Doppelpunkt | ~8 % | `Star Trek: Deep Space Nine: Staffel 7: Extreme Maßnahmen (7)`, `DAHMER: Monster: Die Geschichte von Jeffrey Dahmer: Verstummt` |
| andere Staffel-Marker | <2 % | `Season 3`, `Teil 2`, `Kapitel 1`, `Ted: Ted – Staffel 1: …`, `HIS & HERS: Miniserie: Folge 6`, `…: Limited Series: …` |
| leerer Titel | 127 Zeilen | `" "`, `" : Folge 1"` (vermutlich entfernte Inhalte) → überspringen |
| Folgen-Suffixe | vereinzelt | `… (8)`, `… – Teil 1 und 2`, `…: Teil 1` (Doppelfolgen) |

- 29 Titel kommen mehrfach vor (an verschiedenen Tagen) = Wiederholungen → mehrere Sichtungen.

### 6.2 Ablauf
1. **Upload & Einlesen (synchron):** Kopfzeile prüfen, Datum parsen, leere Titel überspringen.
   Jede Zeile bekommt einen Fingerabdruck aus `(Rohtitel, Datum, laufende Nummer bei identischen
   Zeilen)`. Nur unbekannte Fingerabdrücke werden gespeichert. Damit ist jeder Re-Import
   idempotent, auch wenn der neue Export die alten Zeilen wieder enthält.
2. **Zerlegen:** Jede neue Zeile → Serienkandidat + optional Staffelnummer + Folgentitel, oder
   Filmkandidat. Regeln **[Builder, mit den Beispielen aus 6.1 als Testfälle]**; Leitlinien:
   - Ein Staffel-Marker (`Staffel|Season|Teil|Part|Kapitel N`, auch `<Name> – Staffel N`,
     `Miniserie`, `Limitierte Serie`, `Limited Series`) trennt Serienname (alles davor, inkl.
     Doppelpunkten) und Folgentitel (alles danach).
   - Ohne Marker: Serienkandidat = alles vor dem letzten `": "`; Titel ohne Doppelpunkt sind
     Filmkandidaten. Gibt es zum selben Kandidaten nur eine einzige Zeile, wird zusätzlich der
     volle Titel als Film geprüft (Filme mit Doppelpunkt im Namen).
3. **Serien/Filme zuordnen (Hintergrund):** Pro unbekanntem Kandidaten **eine** TMDB-Suche
   (`de-DE`). Automatisch übernommen wird nur ein **eindeutiger** Treffer: genau ein Ergebnis,
   dessen normalisierter Name oder Originalname dem Kandidaten entspricht. Alles andere geht nach
   „Zu prüfen“ (mit gespeicherten Top-5-Kandidaten). Die Zuordnung *Netflix-Name → TMDB-Titel*
   wird gespeichert und bei allen künftigen Importen wiederverwendet.
4. **Folgen zuordnen:** Für zugeordnete Serien alle Staffeln von TMDB laden (Cache), dann je
   Zeile: Staffel + normalisierter Folgentitel exakt → sonst unscharf innerhalb der Staffel →
   sonst über alle Staffeln (für Zeilen ohne Staffel). Normalisierung: Kleinschreibung,
   Satzzeichen/Gedankenstriche vereinheitlichen, Suffixe wie `(8)` entfernen. Doppelfolgen
   (`Teil 1 und 2`) dürfen beide Folgen markieren. Schwellwert und Algorithmus **[Builder]** –
   aber: im Zweifel nicht zuordnen (Anti-Ziel).
5. **Ergebnis:** Treffer → Sichtung mit Quelle „Netflix“ und Datum aus der CSV. Kein Treffer →
   „Nicht zugeordnet“. Rohzeilen bleiben immer erhalten.
   **Zusammenführen statt verdoppeln [Vorschlag]:** Gibt es für dieselbe Folge (bzw. denselben
   Film) schon eine manuelle Sichtung mit Dienst „Netflix“ oder „unbekannt“ im Abstand von
   ±1 Tag, wird die Netflix-Zeile mit dieser
   Sichtung verknüpft statt eine neue anzulegen (typischer Ablauf: auf Netflix geschaut, auf der
   Karte abgehakt, später importiert). Eine Sichtung **ohne Datum** übernimmt das Datum der
   ersten passenden Netflix-Zeile. Erst wenn keine passende Sichtung existiert, entsteht eine
   neue – so bleiben echte Wiederholungen (andere Tage) erhalten.
6. Nach „Übernehmen“ in „Zu prüfen“ läuft Schritt 4 für die Zeilen dieses Kandidaten sofort nach.

Erwartete Last beim Erstimport: ~250 Kandidaten-Suchen + Staffelabrufe (grob 1.000–1.500
TMDB-Requests). TMDB erlaubt laut Doku ca. 40 Requests/s; der Import drosselt sich selbst
(z. B. ≤ 20/s) und reagiert auf HTTP 429 mit Warten. **[Vorschlag]**

### 6.3 Hintergrundarbeit **[Vorschlag]**
- Kein Queue-System. Der Zuordnungslauf ist ein Swift-`Task` im Prozess; Status und Fortschritt
  stehen in der Import-Tabelle, die Import-Seite fragt per htmx alle 2 s ab.
- Bricht der Prozess ab (Neustart), werden beim Start alle Zeilen mit Status „ausstehend“
  erneut verarbeitet.
- Höchstens ein Lauf gleichzeitig – über alle Benutzer hinweg, damit das TMDB-Limit sicher
  eingehalten wird. Ein neuer Upload (auch eines anderen Benutzers) während eines Laufs wird
  eingelesen und vom laufenden bzw. nächsten Lauf mit verarbeitet.

## 7. TMDB-Daten aktuell halten **[Vorschlag]**
- Serien-/Staffeldaten werden lokal gecacht (Titel, Folgen, Ausstrahlungsdaten, Posterpfad).
- Ein täglicher Hintergrundlauf (Lifecycle-Handler mit Timer, kein Queue-System) aktualisiert
  Serien, die bei mindestens einem Benutzer in der Bibliothek und nicht ausgeblendet sind und
  deren Status bei TMDB nicht „Ended“/„Canceled“ ist – damit neue Folgen in Weiterschauen
  auftauchen.
- Detailseiten aktualisieren beim Öffnen, wenn der Cache älter als 7 Tage ist.
- Poster werden direkt von `image.tmdb.org` geladen, nicht lokal gespeichert.

## 8. Datenmodell **[Vorschlag – Namen und Details: Builder]**

| Tabelle | Zweck | Wichtige Felder |
|---|---|---|
| `users` | Benutzerkonto | Benutzername (eindeutig), Passwort-Hash (Bcrypt), `is_admin`, angelegt am |
| `titles` | **gemeinsamer** TMDB-Cache: Serie oder Film | `tmdb_id`, `kind` (tv/movie), Name, Jahr, Posterpfad, TMDB-Status, `tmdb_refreshed_at`; eindeutig: (`kind`, `tmdb_id`) |
| `episodes` | **gemeinsamer** TMDB-Folgen-Cache | `title_id`, Staffel, Folge, Name, Ausstrahlungsdatum, TMDB-Folgen-ID; eindeutig: (`title_id`, Staffel, Folge) |
| `user_titles` | Titel in der Bibliothek eines Benutzers | `user_id`, `title_id`, `rating` (1–10, optional), `hidden`; eindeutig: (`user_id`, `title_id`) |
| `watches` | eine Sichtung | `user_id`, `title_id`, `episode_id` (leer bei Filmen), `watched_on` (Datum, optional), `service` (Netflix/Prime Video/Disney+/Apple TV+/Kino/Sonstiges, optional), `origin` (import/manual) |
| `imports` | ein Upload | `user_id`, Zeitpunkt, Dateiname, Zeilen gesamt/neu/übersprungen, Status, Fortschritt |
| `netflix_rows` | Rohzeile aus der CSV | `user_id`, Rohtitel, Datum, Fingerabdruck (eindeutig je Benutzer), zerlegte Teile, Status (ausstehend / zugeordnet / nicht zugeordnet / ignoriert / verworfen), Verweis auf `watches` (mehrere Zeilen dürfen auf dieselbe Sichtung zeigen, s. 6.2 Schritt 5) |
| `netflix_mappings` | Netflix-Name → TMDB-Titel | `user_id`, Netflix-Name (eindeutig je Benutzer), `title_id` (optional), Status (automatisch / bestätigt / zu prüfen / ignoriert), gespeicherte Kandidaten |
| `_fluent_sessions` | Login-Sessions | Vapor-Standard |

Alle benutzerbezogenen Tabellen werden beim Löschen eines Kontos mitgelöscht. Jeder Zugriff
auf benutzerbezogene Daten filtert über den eingeloggten Benutzer – am besten zentral (z. B.
Repository/Query-Helper mit Pflicht-`user_id`), nicht in jedem Handler einzeln. **[Builder]**

Ein Titel ist dieselbe Karte, egal ob die Sichtungen aus Netflix oder manuell kommen –
zusammengeführt über die TMDB-ID. **[Vorschlag]**

## 9. Konfiguration (nur Env-Variablen) **[Vorschlag]**

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | nur beim ersten Start | Legen den ersten Admin an, solange kein Benutzer existiert; danach ignoriert |
| `TMDB_TOKEN` | ja | TMDB Read Access Token (Bearer) |
| `TMDB_LANGUAGE` | nein | Standard `de-DE` |
| `DATABASE_PATH` | nein | Standard `/data/watchswifty.sqlite` im Container |
| `PORT` / `HOST` | nein | Standard `8080` / `0.0.0.0` |

Fehlt eine Pflichtvariable, startet die App nicht und sagt klar, was fehlt.

## 10. Sicherheit **[Vorschlag]**
- Passwörter als Bcrypt-Hash (Vapor eingebaut); Fehlermeldung beim Login verrät nicht, ob der
  Benutzername existiert; nach Fehlversuch kurze Verzögerung.
- Admin-Seiten per Middleware nur für Admins; benutzerbezogene Datensätze werden immer über
  den eingeloggten Benutzer geladen – fremde IDs in URLs führen zu 404.
- Zustandsändernde Requests nur per POST/DELETE und nur mit passendem `Origin`-Header bzw.
  `HX-Request` (CSRF-Schutz zusätzlich zu `SameSite=Lax`).
- Kein TLS in der App; für Zugriff außerhalb des Heimnetzes einen Reverse-Proxy davorsetzen
  (in der README dokumentieren).
- Upload-Größe begrenzen (z. B. 10 MB; der echte Export hat ~250 KB).

## 11. Qualität & Tests
- **Parser-Tests** mit einer Fixture aus repräsentativen Zeilen des echten Exports (alle Muster
  aus 6.1, inkl. Randfälle). Die vollständige Datei des Nutzers wird **nicht** ins Repo gelegt.
  **[Vorschlag]**
- Tests für Zuordnungslogik (exakt, unscharf, mehrdeutig → „zu prüfen“), Idempotenz des
  Re-Imports, „nächste Folge“-Regel, Haken entfernen + Re-Import.
- **Isolation:** Benutzer B kann Sichtungen, Bewertungen, Importe und Zuordnungen von A weder
  sehen noch ändern (auch nicht über direkte IDs); Nicht-Admins erreichen keine Admin-Seiten;
  letzter Admin ist geschützt; Konto löschen entfernt alle zugehörigen Daten.
- TMDB im Test über ein austauschbares Client-Protokoll mit Fake.
- Abnahmetest: Den echten Export importieren; Erwartung: keine Duplikate bei zweitem Import,
  Großteil der Staffel-Zeilen automatisch zugeordnet, Rest landet sichtbar in „Zu prüfen“ /
  „Nicht zugeordnet“.

## 12. Betrieb
- Multi-Stage-Dockerfile (Swift-Build-Image → schlankes Runtime-Image), `docker-compose.yml`
  mit einem Volume für `/data`. **[Vorschlag]**
- Das Image baut eine **GitHub Action** **[entschieden]** und schiebt es in die GitHub
  Container Registry (`ghcr.io`), getaggt mit `latest` und Git-SHA bzw. Versions-Tag.
  Zielarchitektur `linux/amd64`; `linux/arm64` nur bei Bedarf über einen nativen ARM-Runner
  (Swift unter QEMU-Emulation ist zu langsam). Tests laufen in derselben Action vor dem Build.
  **[Vorschlag]**
- Aufruf über eigene Adresse/Port, nicht unter einem Unterpfad. **[Vorschlag]**
- README: Start, Env-Variablen, Netflix-Export herunterladen, Backup = SQLite-Datei sichern.

## 13. Dem Builder überlassen
- Projektstruktur, Controller-Aufteilung, Schnitt der Elementary-Komponenten
- Gestaltung/CSS (dunkles Theme; die Farbtokens aus `tv-tracker-main/tokens.css` – MIT – dürfen
  als Ausgangspunkt dienen, Netflix-Branding/-Rot nicht kopieren); sichtbarer Fokus und
  `prefers-reduced-motion` beachten
- Exakte Parse-Regeln und Fuzzy-Matching-Algorithmus (innerhalb der Leitplanken aus §6)
- Paginierung, Fehlermeldungen, Logging
- Aktuelle Vapor-4-/Fluent-Versionen (Elementary/ElementaryHTMX: exakt pinnen)

## 14. Später (nicht v1)
- Import für Amazon Prime („Request your data“) und Disney+ (DSGVO-Auskunft – Inhalt noch
  unbekannt), sobald echte Dateien vorliegen
- Watchlist, kommende Premieren
- Umstieg auf Vapor 5, wenn stabil und die Fluent-Integration nachgezogen hat

---

## Änderung 2026-11-07: TMDB-Token pro Benutzer **[entschieden]**

Jeder Benutzer hinterlegt seinen eigenen TMDB-Token; es gibt keinen serverweiten `TMDB_TOKEN` mehr.
Ersetzt die betreffenden Aussagen in §3, §5, §6, §7, §9 und §10.

- **Konto-Seite:** Abschnitt „TMDB-Token“ mit Status (hinterlegt, nur die letzten 4 Zeichen sichtbar /
  nicht hinterlegt), Eingabefeld, „Speichern“, „Entfernen“. Beim Speichern wird der Token bei TMDB
  geprüft (`GET /3/authentication`); abgelehnt → nicht gespeichert, Meldung „TMDB hat den Token
  abgelehnt.“ **[Vorschlag]**
- **Speicherung:** Klartext in `users.tmdb_token` (wird für die Aufrufe gebraucht). Nur der Besitzer
  kann ihn setzen/entfernen; er erscheint nirgends im Klartext, auch nicht für Admins, und wird nie
  geloggt. Die SQLite-Datei ist entsprechend zu schützen (README). **[Vorschlag]**
- **Ohne Token:** Suche zeigt einen Hinweis mit Link zur Konto-Seite; bereits zwischengespeicherte
  Titel, Weiterschauen, Verlauf und Bibliothek funktionieren weiter. **[Vorschlag]**
- **Import:** Der Zuordnungslauf nutzt pro Benutzer dessen Token. Fehlt er oder lehnt TMDB ihn ab,
  bleiben nur die Zeilen dieses Benutzers ausstehend, und seine Import-Seite zeigt die Meldung;
  andere Benutzer werden weiter verarbeitet. **[Vorschlag]**
- **Täglicher Abgleich:** Für jede fällige Serie wird der Token eines Benutzers verwendet, der die
  Serie sichtbar in seiner Bibliothek hat; ohne solchen Token wird die Serie übersprungen. **[Vorschlag]**
- **Gemeinsamer Cache bleibt:** `titles`/`episodes` werden weiterhin geteilt, egal mit wessen Token
  sie geladen wurden.
- **Konfiguration:** `TMDB_TOKEN` entfällt; `TMDB_LANGUAGE` bleibt global. Ein Rate-Limiter (≤ 20/s)
  gilt für alle Benutzer gemeinsam.
