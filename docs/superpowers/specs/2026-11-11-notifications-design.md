# WatchSwifty – Benachrichtigungen zu neuen Folgen, per Mail oder Webhook (Design)

Stand: 2026-11-11 · Status: zur Freigabe (Fragen des Gutachters eingearbeitet) · Ergänzt `2026-11-09-mail-design.md` (Mail-Versand, „Neues Gerät“) und
`2026-11-07-ui-round-design.md` („Beobachten“, Kasten „Neue Folgen“)

**Warum:** Wer eine Serie beobachtet, sieht neue Folgen heute nur, wenn er WatchSwifty öffnet (Kasten „Neue Folgen“,
„Demnächst“). Der Nutzer will zeitnah und ohne nachzusehen erfahren, wenn eine Folge angekündigt wird und wann sie
kommt. Außerdem betreibt er **KNot** (https://github.com/nexus421/KNot), eine kleine Brücke, die Webhooks als Mail
weiterleitet; WatchSwifty soll Benachrichtigungen wahlweise darüber statt per SMTP verschicken können.

## Entschieden (vom Nutzer)

1. **Täglich einmal** werden die beobachteten Serien bei TMDB abgefragt.
2. **Drei Meldungen pro Folge:** sobald die Folge erkannt wurde, **3 Tage** vor der Ausstrahlung und **am Tag** der
   Ausstrahlung – jede für sich **pro Nutzer** einstellbar. Inhalt: Serie, Folge, wann.
3. Die Vorschläge zu Punkt 2 sind übernommen: nur beobachtete Serien und reguläre Folgen, Standard aus, eine
   Sammel-Mail pro Nutzer und Tag, „erkannt“ nur für Folgen, die nach dem Beobachten-Klick auftauchen, Folgen ohne
   Datum, verschobene Termine (Details in 4.).
4. **Webhook = KNot.** Der **Admin** trägt die Webhook-Adresse unter **System** ein (mit Hinweis und Link auf das
   KNot-Repository); jeder Nutzer trägt unter **Konto** nur seinen eigenen API-Schlüssel ein.
5. **Je nachdem, was eingerichtet ist,** wählt der Nutzer, wie er Benachrichtigungen bekommt (E-Mail oder Webhook).
6. **Ansatz A:** Tabelle der verschickten Meldungen statt Warteschlange (siehe Ansätze).
7. **Der Admin wählt die Uhrzeit** des täglichen Durchgangs (Standard 7:00).

## Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**
- Wer eine Serie beobachtet und Benachrichtigungen einschaltet, erfährt ohne nachzusehen von angekündigten Folgen,
  drei Tage vorher und am Tag selbst.
- Benachrichtigungen gehen per Mail (SMTP wie heute) oder per Webhook an KNot – je Nutzer wählbar.
- „Neues Gerät verbunden“ geht über denselben gewählten Weg.
- Der tägliche TMDB-Abgleich läuft zu einer vom Admin gewählten Uhrzeit und erfasst wirklich alle beobachteten
  Serien (Fehler beim Token für ausgeblendete Serien behoben, siehe 1.).
- Web und App-API können dasselbe (gleiche Services).

**Nicht-Ziele**
- Push-Benachrichtigungen an die iOS-App; Einstellungen in der iOS-App (die API-Endpunkte gibt es, die App nutzt sie
  vorerst nicht).
- Andere Webhook-Empfänger mit eigenem Format (Discord, ntfy, Slack …), frei gestaltbare Vorlagen, HTML-Mails.
- Meldungen zu Filmen, Specials (Staffel 0), verschobenen Terminen („Termin geändert“) oder abgesagten Serien.
- Veraltete Folgenzeilen (siehe `last_seen_at`) aus „Demnächst“, „Neue Folgen“ oder der Serienseite ausblenden – das
  bleibt, wie es ist.
- Benachrichtigungen für Admins (Import fertig, Update verfügbar, Fehler im Abgleich).
- Mehrere Webhook-Adressen oder ein Webhook pro Nutzer mit eigener Adresse.
- Uhrzeit pro Nutzer.

**Anti-Ziele** (wäre ein Fehlschlag, auch wenn es technisch funktioniert)
- Dieselbe Meldung kommt doppelt, oder es kommt eine Flut – beim Beobachten einer Serie, beim Update auf diese
  Version, bei einer neu angekündigten Staffel oder wenn TMDB Folgen umnummeriert.
- Reset-, Einladungs- oder Verknüpfungslinks gehen über einen Webhook.
- API-Schlüssel stehen im Klartext in der Datenbank, im Log oder in API-Antworten.
- Ein normaler Nutzer kann WatchSwifty Anfragen an eine Adresse seiner Wahl schicken lassen.
- Ohne Einrichtung ändert sich etwas: „Neues Gerät“ geht wie bisher per Mail, niemand bekommt ungefragt neue Mails.
- Ein hängender KNot- oder Mailserver hält den TMDB-Abgleich oder den Server auf.
- Ein Nutzer bekommt Meldungen über Serien, die nur ein anderer beobachtet.

## Ansätze

| Ansatz | Vorteil | Nachteil |
|---|---|---|
| **A – Tabelle der verschickten Meldungen** (gewählt) | ein Mechanismus für alle drei Meldungen; prüft den aktuellen Stand, daher egal, wie eine Folge in den Cache kam; Neustarts, ausgefallene Tage und Fehlversand heilen sich von selbst | Folgen, die beim Update schon im Cache sind, gelten nie als „erkannt“ (ihr Zeitpunkt ist unbekannt) |
| B – Warteschlange, gefüllt beim TMDB-Abgleich | „erkannt“ zeitlich genauer | zwei Mechanismen (Warteschlange + Datumsprüfung); Warteschlange muss gepflegt werden; wer erst nach dem Abgleich beobachtet, geht leer aus |
| C – bekannte Folgenliste je Nutzer speichern und vergleichen | – | viel doppelter Speicher neben dem Folgen-Cache, kein Vorteil gegenüber A (verworfen) |

**Gewählt: A.**

Zur Webhook-Einrichtung:

| Variante | Vorteil | Nachteil |
|---|---|---|
| Nutzer trägt Adresse und Schlüssel selbst ein | kein Admin nötig | jeder Nutzer kann den Server an beliebige Adressen (auch im Heimnetz) senden lassen |
| **Admin trägt die Adresse ein, Nutzer nur den Schlüssel** (gewählt) | nur der Admin bestimmt, wohin der Server sendet; KNot-Ziele legt ohnehin der Betreiber von KNot an | Admin muss einmal einrichten |

## Lösung

### 1. Täglicher Durchgang zur gewählten Uhrzeit

Heute (`DailyRefreshLifecycle`): 60 s nach dem Start, dann alle 24 h – Uhrzeit also zufällig je nach Neustart.

**Neu:**
- **Uhrzeit** in `app_settings` (z. B. Spalte `daily_run_time`, `"HH:MM"`, Standard `07:00`), eingestellt unter
  System (3.). Gilt in der **Zeitzone des Servers** (`TimeZone.current`, im Container über `TZ`).
- **Zeitplan:** Der Durchgang läuft täglich zur eingestellten Uhrzeit. Die nächste Ausführung wird jedes Mal neu aus
  Uhrzeit und Kalender berechnet (Sommer-/Winterzeit: bei einer Uhrzeit, die es an dem Tag nicht gibt oder doppelt
  gibt, genau einmal am nächstmöglichen Zeitpunkt).
- **Änderung greift sofort,** ohne Neustart: Speichern unter System weckt den wartenden Durchgang auf, er berechnet
  die nächste Ausführung neu.
- **Nach dem Start** läuft der Durchgang nur dann nach 60 s, wenn die eingestellte Uhrzeit seit dem letzten
  vollständigen Durchgang verstrichen ist (oder er nie lief) – sonst wartet er auf die eingestellte Uhrzeit.
  *(Nach Abschlussprüfung: ursprünglich „mehr als 24 h her“ – damit lief ein Server, der nachts aus ist, nur jeden
  zweiten Tag. Gemerkt wird der Beginn eines Durchgangs erst, wenn er vollständig war.)* Dafür speichert `app_settings` den Beginn des
  letzten Durchgangs (z. B. `daily_run_at`). *(Entscheidung Claude: Updates und Neustarts lösen so nicht jedes Mal
  einen kompletten TMDB-Abgleich und Meldungen zu ungewohnter Zeit aus; ein verpasster Tag wird nachgeholt.)*
- **Reihenfolge im Durchgang:** wie heute (Laufzeiten, abgelaufene Tokens, Cache-Pflege, TMDB-Abgleich der Serien),
  danach **neu: Benachrichtigungen** (4.). Die Benachrichtigungen laufen auch, wenn einzelne Serien beim Abgleich
  scheitern.
- **Fehler behoben:** `refreshToken(for:)` nimmt heute nur Tokens von Nutzern, die die Serie *nicht* ausgeblendet
  haben. Eine beobachtete, aber ausgeblendete Serie wird deshalb nie aktualisiert, obwohl `seriesDueForRefresh` sie
  auswählt. Künftig zählen dieselben Nutzer wie in `seriesDueForRefresh`: sichtbar **oder** beobachtet.

### 2. Webhook über KNot

KNot (laut seiner Doku): `POST <Adresse>` mit Header `X-API-Key: <Schlüssel>` und JSON-Body
`{"subject": "…", "body": "…"}`. Der Schlüssel bestimmt allein das Ziel und damit den Empfänger der Mail – der
Absender kann den Empfänger nicht wählen. Antworten: `200` zugestellt, `400` Body ungültig, `401` Schlüssel unbekannt,
`413` zu groß (> 256 KiB), `429` Ratenlimit des Ziels (Standard 10/min), `502` SMTP-Zustellung gescheitert. KNot
stellt synchron zu und braucht bei Ausfall des Mailservers bis etwa 50 s.

- **Ein Protokoll `WebhookSender`** im Application-Storage, wie `MailSender`: live über den HTTP-Client von Vapor,
  in Tests ein Fake, der Aufrufe sammelt (und Fehler einspielen kann).
- **Nachricht:** genau `subject` und `body` – dieselben Texte wie die Mail (`OutgoingMail` ohne `to`). Keine
  zusätzlichen Felder.
- **Frist 60 s** je Aufruf (länger als KNots ~50 s, damit eine verspätete Zustellung nicht als Fehler gilt und doppelt
  kommt). Kein Wiederholen innerhalb des Durchgangs; was scheitert, kommt am nächsten Tag erneut dran (4.).
- **Fehlermeldungen** auf Deutsch je Fall: Verbindung fehlgeschlagen, Zeitüberschreitung, `401` „KNot kennt den
  Schlüssel nicht“, `429` „zu viele Nachrichten an dieses Ziel“, `502` „KNot konnte die Mail nicht zustellen“, andere
  Statuscodes allgemein mit Code. Der Schlüssel erscheint nie in Log oder Meldung; die Adresse darf im Log stehen.
- **Keine Weiterleitungen folgen** (Redirects sind Fehler) *(Entscheidung Claude: der Schlüssel im Header soll nicht an
  ein Ziel gehen, das der Admin nicht eingetragen hat).*

### 3. System → Benachrichtigungen (nur Admins)

Neuer Abschnitt auf der Seite **System**:

- **„Täglicher Abgleich um“**: Uhrzeitfeld (`HH:MM`), Standard 07:00. Darunter: „Zeitzone des Servers: Europe/Berlin“
  (Name von `TimeZone.current`); ist sie UTC, zusätzlich der Hinweis, im Container `TZ` zu setzen (README).
  Außerdem „Letzter Durchgang: …“ und „Nächster: …“.
- **„Webhook-Adresse (KNot)“**: z. B. `https://knot.example.lan/hook`. Erlaubt: `http(s)://host[:port]/pfad`, ohne
  Benutzerinfo, Query oder Fragment *(Query ausgeschlossen, damit niemand den Schlüssel per `?apiKey=` in die Adresse
  legt – er gehört in den Header).* Leer speichern bzw. „Webhook entfernen“ schaltet den Weg ab.
- **Hinweistext** mit Link auf https://github.com/nexus421/KNot: KNot leitet Webhooks als Mail weiter; für jede Person
  in KNot ein eigenes Ziel mit ihrer Mail-Adresse anlegen, den Schlüssel mit `java -jar knot.jar key` erzeugen und der
  Person geben; sie trägt ihn unter **Konto → Benachrichtigungen** ein.
- Gespeichert in `app_settings` (Adresse und Uhrzeit sind keine Geheimnisse und werden nicht versiegelt).
- **„Webhook eingerichtet“** = gespeicherte, gültige Adresse.

### 4. Benachrichtigungen zu neuen Folgen

**Was zählt:** nur Serien, die der Nutzer **beobachtet** (`user_titles.followed`), auch wenn ausgeblendet; nur
reguläre Folgen (`season >= 1`), wie beim Kasten „Neue Folgen“.

**Neue Daten:**
- `episodes.first_seen_at` (Zeitpunkt, optional): gesetzt, wenn `CatalogService.upsertEpisodes` eine Folge **neu
  anlegt**. Bestehende Folgen bleiben `nil` und gelten nie als „erkannt“ (Anti-Ziel „Flut beim Update“).
- `user_titles.followed_at` (Zeitpunkt, optional): gesetzt beim Beobachten (gleiche Stelle wie `followed_on`),
  gelöscht beim Entfolgen. Bestehende Beobachtungen bleiben `nil` = „seit jeher“ (dann zählen alle Folgen mit
  `first_seen_at`, also nur nach dem Update neu aufgetauchte).
- `episodes.last_seen_at` (Zeitpunkt, optional): der Refresh setzt sie für **jede** Folge, die TMDB geliefert hat, auf
  den Zeitpunkt des Refresh (auch wenn sich sonst nichts geändert hat; gern als ein SQL-Update pro Serie). Die
  Migration setzt sie für bestehende Folgen auf `titles.refreshed_at`. **Aktuell** ist eine Folge, wenn
  `last_seen_at >= title.refreshedAt` – also beim letzten Refresh noch dabei war.
  *(Nach Review, Entscheidung Claude: `upsertEpisodes` gleicht nur über Staffel/Nummer ab und löscht nie. Verschiebt
  TMDB noch nicht gelaufene Folgen (S02E06–E10 werden S03E01–E05) oder streicht Platzhalter, blieben die alten Zeilen
  mit ihrem Datum stehen und lösten „in 3 Tagen“/„heute“ für Folgen aus, die es so nicht mehr gibt.)*
- Neue Tabelle **`episode_notices`**: `id`, `user_id` (FK, `onDelete: .cascade`), `episode_id` (FK, `onDelete:
  .cascade`), `kind` (`announced` | `soon` | `today`), `air_date` (Datum der Folge zum Zeitpunkt der Meldung,
  optional), `sent_at`. Eindeutig über (`user_id`, `episode_id`, `kind`).
  Sie zählt **nicht** als Nutzung in `titleUsers(on:)` – Meldungen halten keinen Titel im Cache.

**Wann eine Meldung fällig ist** (`today` = `AppConfig.today`; nur für **aktuelle** Folgen, siehe `last_seen_at`):
- **erkannt** (`announced`): `first_seen_at` vorhanden und später als `followed_at` (bzw. `followed_at` leer), und das
  Datum der Folge ist leer oder höchstens 7 Tage vor `today`, und es gibt noch keine `announced`-Meldung.
  *(Die 7-Tage-Grenze ist Entscheidung Claude: Wenn TMDB Staffeln umnummeriert oder alte Folgen nachträgt, entstehen
  neue Zeilen für längst gelaufene Folgen – die sollen keine Meldung auslösen. Eine Folge, die TMDB erst kurz nach
  der Ausstrahlung einträgt, wird noch gemeldet.)*
- **in 3 Tagen** (`soon`): Datum der Folge liegt 1 bis 3 Tage nach `today`, und es gibt keine `soon`-Meldung mit
  **demselben** Datum. Die Spanne statt genau 3 Tagen sorgt dafür, dass ein fehlgeschlagener oder verpasster Tag
  nachgeholt wird; der Text nennt das echte Datum („Sa., 14.11.2026 – in 2 Tagen“).
- **heute** (`today`): Datum der Folge = `today`, und es gibt keine `today`-Meldung mit demselben Datum. Verpasst ist
  verpasst – es gibt kein „gestern“.
- **Verschobene Termine:** Weil `soon` und `today` am Datum hängen, kommen sie für ein neues Datum erneut. `announced`
  kommt pro Folge nur einmal.
- **Umnummerierte Folgen:** Eine Meldung gilt auch dann als schon verschickt, wenn sie für eine andere Zeile derselben
  Serie mit derselben `tmdb_episode_id` eingetragen ist (gleiche Art, bei `soon`/`today` gleiches Datum). So kommt
  eine verschobene Folge nicht noch einmal als „erkannt“ – soweit TMDB beim Verschieben die ID behält; vergibt TMDB
  eine neue, ist eine zweite „erkannt“-Meldung hinnehmbar. Für „erkannt“ zählt außerdem der **früheste**
  `first_seen_at` aller Zeilen mit dieser ID (leer = schon immer bekannt) *(nach Abschlussprüfung: sonst würde eine
  Folge, die der Nutzer schon kannte, nach dem Umnummerieren als „neu angekündigt“ gemeldet)*.
- **Eine Meldung deckt spätere ab:** Wird eine Folge als „erkannt“ verschickt und liegt ihr Datum schon im Fenster
  für „in 3 Tagen“ oder ist heute, werden diese Arten mit eingetragen (sofern der Nutzer sie eingeschaltet hat) – die
  Folge steht dann nur einmal in der Nachricht. Ebenso deckt „heute“ ein noch offenes „in 3 Tagen“ ab.
- Nur Arten, die der Nutzer eingeschaltet hat, sind fällig. Wer eine Art später einschaltet, bekommt sie ab dann –
  für „erkannt“ nur für Folgen, die danach auftauchen *(Entscheidung Claude: maßgeblich ist der spätere der beiden
  Zeitpunkte Beobachten / Einschalten, gespeichert als Zeitpunkt der Einstellung; sonst käme beim Einschalten eine
  Flut zu allem, was seit dem Beobachten aufgetaucht ist).*

**Sammelnachricht:** pro Nutzer und Durchgang **eine** Nachricht mit allem Fälligen, gruppiert nach Serie, innerhalb
in den Abschnitten „Heute“, „In den nächsten Tagen“, „Neu angekündigt“. Pro Folge eine Zeile: Code, Name, Datum
(„S02E03 „Titel“ – Mi., 18.11.2026“; ohne Datum „Termin noch offen“). Betreff mit Zusammenfassung, z. B.
„WatchSwifty: 2 Folgen heute, 5 neu angekündigt“. Ist eine Adresse von WatchSwifty bekannt (aus den Mail- oder
OIDC-Einstellungen), steht pro Serie ein Link auf ihre Seite dabei; sonst keiner. Am Ende: wo man das abschaltet
(„Konto → Benachrichtigungen“). Hinweis im Text, dass das Datum das von TMDB ist (bei US-Serien oft einen Tag vor
der Verfügbarkeit hier) – einmal in der Nachricht, nicht pro Zeile.

**Versand und Eintragen:** Erst nach erfolgreichem Versand werden alle enthaltenen Meldungen eingetragen. Scheitert
der Versand, wird nichts eingetragen; der nächste Durchgang versucht es mit dem dann Fälligen erneut. Fehler nur ins
Log (Benutzername, Weg, Meldung – ohne Adresse und Schlüssel). Ein Nutzer, dessen Versand scheitert, hält die anderen
nicht auf.

**Aufräumen:** Im täglichen Durchgang werden Meldungen gelöscht, deren Folge nach ihrem **aktuellen** Datum (aus
`episodes`, nicht dem gespeicherten `air_date`) mehr als 30 Tage zurückliegt. Meldungen zu Folgen ohne Datum bleiben
stehen. *(Nach Review: Mit dem gespeicherten Datum oder einer Altersgrenze käme eine verschobene oder lange
datumslose Folge nach dem Löschen erneut als „erkannt“.)* Ab 30 Tagen nach der Ausstrahlung ist nichts mehr fällig
(„erkannt“ endet nach 7 Tagen), also kommt nach dem Löschen nichts doppelt. Beim Entfolgen bleiben Meldungen stehen –
Wiederbeobachten erzeugt über `followed_at` ohnehin kein neues „erkannt“ für alte Folgen.

### 5. Wege und Konto → Benachrichtigungen

**Verfügbare Wege** für einen Nutzer:
- **E-Mail:** Mail ist eingerichtet und der Nutzer hat eine lesbare Adresse (auch vom Provider bei SSO-Konten).
- **Webhook:** Webhook-Adresse unter System eingerichtet und der Nutzer hat einen lesbaren Schlüssel hinterlegt.

**Gewählter Weg** (`users.notify_channel`: `mail` | `webhook`, Standard `mail`). **Tatsächlich genutzt:** der
gewählte, wenn verfügbar, sonst der andere, wenn verfügbar, sonst keiner *(Entscheidung Claude: so geht auch
„Neues Gerät“ nicht verloren, wenn der Admin den Webhook entfernt).* Ohne Änderung des Nutzers bleibt also alles wie
heute: „Neues Gerät“ per Mail, sofern Adresse und Mail eingerichtet sind.

**Neuer Abschnitt „Benachrichtigungen“ auf der Konto-Seite:**
- **„Neue Folgen beobachteter Serien“**: drei Schalter – „sobald eine neue Folge bekannt wird“, „3 Tage vor der
  Ausstrahlung“, „am Tag der Ausstrahlung“. Standard: alle aus. Hinweis mit der Uhrzeit des täglichen Abgleichs.
- **„Senden per“**: Auswahl nur zwischen verfügbaren Wegen; mit nur einem Weg steht er als Text da, ohne Auswahl. Mit
  keinem: Hinweis, was fehlt („Hinterlege eine Mail-Adresse“ / „Der Admin hat noch keinen Versand eingerichtet“).
- **„Webhook-Schlüssel (KNot)“**: nur sichtbar, wenn der Admin einen Webhook eingerichtet hat. Passwortfeld, wird nach
  dem Speichern nie wieder angezeigt („gespeichert“), Knopf „Schlüssel entfernen“. Kurzer Hinweis: den Schlüssel gibt
  der Admin bzw. Betreiber von KNot.
- **Setzen, Ändern oder Entfernen des Schlüssels braucht das aktuelle Passwort**, wie bei der Mail-Adresse – sonst
  könnte eine gekaperte Sitzung „Neues Gerät“ auf ein eigenes Ziel umleiten und unbemerkt eine App verbinden. Konten
  ohne Passwort (nur SSO) setzen ihn ohne *(Entscheidung Claude: sie haben keinen anderen Nachweis; das Risiko
  beschränkt sich auf den Geräte-Hinweis).*
- **Schlüssel verschlüsselt** mit `TokenCipher` in `users.webhook_key`; nicht lesbar (Schlüssel des Servers geändert)
  → „Schlüssel nicht lesbar – bitte neu eintragen“, Weg gilt als nicht verfügbar. Gespeichert wird nur, was nicht leer
  ist; geprüft wird nur die Form (≥ 16 Zeichen, druckbares ASCII ohne Leerzeichen, wie KNot es verlangt), kein
  Probeversand.
- **„Testnachricht senden“**: schickt über den tatsächlich genutzten Weg eine kurze Testnachricht und zeigt Erfolg
  oder die Fehlermeldung.
- Schalter und Weg werden ohne Passwort gespeichert.

**„Neues Gerät verbunden“** (`DeviceNoticeService`) nutzt künftig denselben Versanddienst und damit den tatsächlich
genutzten Weg. Es ist immer an (kein Schalter).

**Reset, Einladung, Verknüpfungslink und Testmail unter System** bleiben reine Mails – sie gehen nie über den Webhook.

### 6. Versanddienst

Ein Service (z. B. `NotificationService`), den Konto-Seite, API, `DeviceNoticeService` und der tägliche Durchgang
nutzen: ermittelt den Weg für einen Nutzer und verschickt eine Nachricht (Betreff + Text) per `MailService` oder
`WebhookSender`. Fehler als eigener Typ mit deutscher Meldung (wie `MailError`).

### 7. App-API (`openapi.yaml`)

- `GET /v1/me/notifications` → `{ announced, soon, today: bool, channel: "mail"|"webhook", activeChannel:
  "mail"|"webhook"|null, availableChannels: [...], webhookConfigured: bool, hasWebhookKey: bool, dailyRunTime }`.
- `PUT /v1/me/notifications` → Schalter und gewählter Weg (422, wenn der Weg nicht verfügbar ist).
- `PUT /v1/me/notifications/webhook-key` `{ key, currentPassword }`, `DELETE …/webhook-key` `{ currentPassword }`.
- `POST /v1/me/notifications/test` → 204; Fehler 422 `notificationsNotConfigured` (kein Weg) bzw. 503 `notifyFailed`
  mit der deutschen Meldung *(wie `mailFailed`, 503 statt 502 wegen Cloudflare).*
- `GET/PUT /v1/admin/notifications` → `{ dailyRunTime, timeZone, webhookURL, lastRunAt, nextRunAt }`.
- Isolation: alles nur für den angemeldeten Nutzer; der Schlüssel geht nie in eine Antwort.

### 8. Doku und Release

- README: neuer Abschnitt **„Benachrichtigungen (optional)“** – was gemeldet wird, Uhrzeit und `TZ`, KNot einrichten
  (Link, ein Ziel pro Person, `java -jar knot.jar key`, Adresse unter System, Schlüssel unter Konto), Hinweis zu
  US-Serien und Datum.
- CHANGELOG-Abschnitt unter „Unveröffentlicht“ (`### Neu`, `### Behoben` für den Token-Fehler).

## Dem Umsetzer überlassen

- Genaue Texte (Deutsch, Ton wie die bestehenden Mails und Seiten), Aufbau der Sammelnachricht im Detail.
- Spaltennamen und Aufteilung in Services/Controller nach bestehendem Muster; Migrationen am Ende der Liste.
- Wie der wartende Durchgang bei einer neuen Uhrzeit aufgeweckt wird.
- Ob die Benachrichtigungen pro Nutzer nacheinander oder begrenzt parallel verschickt werden.
- Tests mit Fake-`WebhookSender`, `FakeMailSender`, festem `today` und injizierter Zeit für den Zeitplan.
