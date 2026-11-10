# WatchSwifty – E-Mail für „Passwort vergessen“ und Einladungen (Design)

Stand: 2026-11-09 · Status: zur Freigabe (Fragen des Gutachters eingearbeitet) · Ergänzt `2026-11-07-watchswifty-design.md` (Login, Benutzerverwaltung)

**Warum:** Heute muss der Admin bei jedem neuen Konto ein Startpasswort ausdenken und weitergeben, und wer sein
Passwort vergisst, braucht den Admin (Benutzer-Seite) oder Shell-Zugriff (`reset-password`). Mit Mail-Versand
setzt jeder sein Passwort selbst – beim ersten Mal über eine Einladung, später über „Passwort vergessen“. Der Nutzer
betreibt bereits **SwiftyRelay** (eigenes Mail-Gateway, https://github.com/PaddXy95/SwiftyRelay) und will es per
SMTP anbinden; die App selbst bleibt aber an jeden SMTP-Server anschließbar.

## Entschieden (vom Nutzer)

1. **SMTP-Einstellungen im UI** (Admin), nicht in der `.env`.
2. **Verschlüsselt in der Datenbank** gespeichert.
3. **Mail ist optional:** ohne Einrichtung läuft alles wie heute.
4. **Admins sehen fremde Mail-Adressen nicht vollständig.**
5. **Client:** eigenes Paket **SwiftySMTPClient** (https://github.com/PaddXy95/SwiftySMTPClient), Release `0.1.0`.
6. **Einladung:** Der Admin wählt Benutzername und Mail-Adresse; das Konto existiert sofort, der Eingeladene setzt
   über den Link nur sein Passwort.
7. **CA von SwiftyRelay:** über das eingebundene Volume `swifty-relay-certs` (read-only), nicht als eingefügtes PEM.
8. **Versand direkt** (kein eigener Postausgang): Einladung und Testmail während der Anfrage, „Passwort vergessen“
   im Hintergrund.

## Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**
- Wer sein Passwort vergessen hat und eine Mail-Adresse hinterlegt hat, setzt es selbst über einen Link neu.
- Der Admin lädt neue Personen per Mail ein, ohne ein Passwort zu kennen oder weiterzugeben.
- Einrichtung komplett unter **System → E-Mail**, inklusive „Testmail senden“ mit verständlicher Fehlermeldung.
- Funktioniert mit SwiftyRelay (STARTTLS mit eigener CA, Port 2525) und mit normalen Anbietern (587/465).
- Web und App-API können dasselbe (gleiche Services), wie bei allen bisherigen Funktionen.

**Nicht-Ziele**
- Eigene Warteschlange oder Wiederholungen (SwiftyRelay hat eine eigene; Fehler landen im Log).
- HTML-Mails, Anhänge, DKIM, MX-Auflösung, Mail-Adressen mit Nicht-ASCII-Zeichen (SMTPUTF8).
- Bestätigung einer neu eingetragenen Mail-Adresse per Bestätigungsmail; Benachrichtigung der alten Adresse.
- Andere Mails (neue Folgen, Import fertig, Update verfügbar …).
- Beim Zurücksetzen andere Sitzungen oder Geräte-Tokens beenden (das tun die bestehenden Wege auch nicht).
- „Passwort vergessen“ in der App-API: die App meldet sich im Browser an, dort gibt es den Link.
- Anmeldung per Mail-Adresse statt Benutzername.

**Anti-Ziele** (wäre ein Fehlschlag, auch wenn es technisch funktioniert)
- „Passwort vergessen“ verrät, ob es einen Benutzernamen gibt oder ob eine Adresse hinterlegt ist
  (Text oder Antwortzeit).
- Jemand übernimmt ein Konto mit einem fremden, abgelaufenen oder schon benutzten Link – oder weil ein Mail-Scanner
  den Link vorab aufruft.
- Ein Angreifer bringt WatchSwifty dazu, Links auf eine fremde Adresse zu verschicken (Host-Header).
- SMTP-Passwort oder Mail-Adressen stehen im Klartext in der Datenbank, im Log oder in API-Antworten an Admins.
- Eine gekaperte Sitzung kann über „Adresse ändern + Passwort vergessen“ das Konto übernehmen, obwohl für
  „Passwort ändern“ das aktuelle Passwort nötig ist.
- Ohne Mail-Einrichtung ändert sich etwas am bisherigen Verhalten oder es erscheinen tote Links.
- WatchSwifty startet nicht oder hängt, weil der Mailserver nicht erreichbar ist.

## Ansätze

| Ansatz | Vorteil | Nachteil |
|---|---|---|
| **A – direkt senden** (gewählt) | wenig Code; Admin sieht Fehler bei Einladung/Testmail sofort | kein Wiederholen bei Ausfall |
| B – eigener Postausgang mit Wiederholung | robust bei kurzem Relay-Ausfall | viel mehr Code; gültige Reset-Links lägen in der DB; Fehler erst später sichtbar; doppelt zu SwiftyRelays Warteschlange |
| C – alles in der Anfrage, auch „Passwort vergessen“ | am einfachsten | Antwortzeit verrät Konten mit Adresse; Seite hängt am Mailserver |

**Gewählt: A**, weil SwiftyRelay angenommene Mails selbst dauerhaft speichert und wiederholt
(1, 5, 15, 60, 120 Minuten). „Passwort vergessen“ läuft trotzdem im Hintergrund, um das erste Anti-Ziel zu erfüllen.

Zur CA: eingefügtes PEM im UI wurde verworfen zugunsten des Volumes, damit eine neu erzeugte Relay-CA ohne Zutun
übernommen wird.

## Lösung

### 1. Abhängigkeit

`Package.swift`: `.package(url: "https://github.com/PaddXy95/SwiftySMTPClient.git", .upToNextMinor(from: "0.1.0"))`,
Produkt `SwiftySMTPClient` im Target `App`. Für `NIOSSLTrustRoots` zusätzlich `NIOSSL` aus `swift-nio-ssl`
(kommt transitiv schon über Vapor).

### 2. Mail-Einstellungen (System → E-Mail)

Neuer Abschnitt auf der Seite **System** (nur Admins), Felder:

| Feld | Bedeutung | Beispiel SwiftyRelay |
|---|---|---|
| Server | Host-Name; auch für die Zertifikatsprüfung | `swifty-relay` |
| Port | leer = Standard je Verschlüsselung (587/465/25) | `2525` |
| Verschlüsselung | STARTTLS / SSL/TLS / keine | STARTTLS |
| Benutzer, Passwort | optional; Passwort-Feld leer = bisheriges behalten | `watchswifty`, `SMTP_IN_PASSWORD` |
| Absender-Adresse, Absender-Name | `From:`; Name Standard „WatchSwifty“ | beliebig (SwiftyRelay schreibt um) |
| CA-Datei | optional: Pfad im Container zu PEM-Datei mit vertrauten CAs; leer = System-CAs | `/certs/swifty-relay/ca/ca-bundle.pem` |
| Adresse von WatchSwifty | Basis für Links in Mails, z. B. `https://watch.example.lan` | – |

- **Verschlüsselt gespeichert:** die gesamte Einstellung als **ein** JSON-Block, mit `TokenCipher` (derselbe
  `TOKEN_KEY` wie für die TMDB-Tokens) versiegelt, in einer neuen Spalte von `app_settings` (z. B. `mail_config`).
  Ist der Block nicht lesbar (Schlüssel geändert), zeigt die Seite „Mail-Einstellungen nicht lesbar – bitte neu
  eintragen“, und Mail gilt als nicht eingerichtet.
- Das **Passwort** wird nie wieder angezeigt (nur „gespeichert“), weder im Web noch in der API.
- **Passwort neu eingeben, wenn sich die Verbindung ändert** *(Entscheidung Claude)*: Ändern sich Server, Port,
  Verschlüsselung oder Benutzer, wird das gespeicherte Passwort verworfen; ist ein Benutzer gesetzt, muss das
  Passwort dann neu eingegeben werden (sonst 422 mit Hinweis). Sonst könnte jemand mit Admin-Sitzung den Server
  auf einen eigenen umstellen, „keine“ Verschlüsselung wählen und sich das gespeicherte Passwort per Testmail im
  Klartext schicken lassen – bei SwiftyRelay ist das `SMTP_IN_PASSWORD`, das alle Apps am Relay teilen.
  Gilt für Web und API gleich.
- **„Adresse von WatchSwifty“** ist Pflicht, sobald Mail eingerichtet wird. Beim ersten Öffnen ist sie mit dem Origin
  der aktuellen Anfrage vorbelegt; gespeichert wird nur, was der Admin abschickt. Links werden **ausschließlich**
  aus diesem gespeicherten Wert gebaut, nie aus `Host`/`X-Forwarded-*` der Anfrage. Erlaubt: `http(s)://host[:port]`
  ohne Pfad, Query oder Fragment.
- **„Mail ist eingerichtet“** = lesbarer Block mit Server, Absender-Adresse und Adresse von WatchSwifty.
- **Testmail senden:** Empfänger-Feld, vorbelegt mit der eigenen Adresse des Admins (falls hinterlegt). Sendet mit
  den **gespeicherten** Einstellungen und zeigt Erfolg oder die Fehlermeldung.
- **Mail ausschalten:** Knopf „E-Mail-Einstellungen löschen“ entfernt den Block. Offene Einladungslinks bleiben
  gültig (Passwort setzen braucht keinen Versand).
- Kurzer Hinweis auf der Seite, was nötig ist, mit Verweis auf den README-Abschnitt (SwiftyRelay-Beispiel).

### 3. Versand

- Ein Protokoll `MailSender` (`send(_ mail: OutgoingMail) async throws`) im Application-Storage, wie `TMDBProvider`
  und `ReleaseFetcher`; live über SwiftySMTPClient, in Tests ein Fake, der Mails sammelt.
- Pro Versand werden die Einstellungen frisch aus der DB gelesen und entschlüsselt, die CA-Datei frisch gelesen
  (eine erneuerte Relay-CA greift sofort). Nicht lesbare CA-Datei → eigene, klare Fehlermeldung mit Pfad.
- SwiftySMTPClient: `connectTimeout` 10 s, `replyTimeout` 30 s; zusätzlich eine Gesamtfrist von 30 s für Versand in
  der Anfrage (Task-Abbruch, siehe Client-README).
- **Fehlermeldungen** für Admins auf Deutsch, je Fall von `SMTPClientError` (Verbindung, Zertifikat, Anmeldung
  abgelehnt, Empfänger abgelehnt, Zeitüberschreitung, STARTTLS nicht angeboten …). Logs nutzen nur die
  `description` des Clients (laut Client ohne Zugangsdaten); Empfänger-Adressen werden im Log maskiert.
- **Nachricht** (WatchSwifty baut sie selbst, der Client verschickt nur fertige Nachrichten):
  `From` (Name als RFC-2047-Encoded-Word), `To`, `Subject` (RFC 2047, UTF-8), `Date` (RFC 5322), `Message-ID`
  (`<uuid@domain-der-absender-adresse>`), `MIME-Version`, `Content-Type: text/plain; charset=utf-8`,
  7-Bit-sichere Übertragungskodierung (quoted-printable bevorzugt), CRLF-Zeilenenden. Nur Text, keine HTML-Mail.
- **Header-Injection ausgeschlossen:** Adressen werden streng geprüft (siehe 4.), Benutzernamen sind ohnehin auf
  `a–z 0–9 . _ -` beschränkt.
- **Adressen in Fehlertexten maskieren:** Antworten des Mailservers (z. B. `550 … <alice@example.org>`) können
  Adressen enthalten; in Log und in Meldungen an Admins werden sie mit derselben Maske wie in 4. ersetzt.
- Hinweis: SwiftyRelay ersetzt den Absender durch seine eigene Adresse und den App-Namen; das Feld
  „Absender-Name“ wirkt dort nicht (steht so im README-Beispiel).

### 4. Mail-Adresse der Benutzer

- Neue Spalte `users.email` (optional), **verschlüsselt** mit `TokenCipher`. Kein Index, keine Suche danach nötig:
  „Passwort vergessen“ fragt nach dem Benutzernamen.
- **Prüfung:** getrimmt, ≤ 254 Zeichen, genau ein `@`, nicht leerer lokaler Teil und Domain mit Punkt, nur
  druckbares ASCII ohne Leerzeichen, `<>`, `,`, `;`, CR/LF. Gespeichert wird sie wie eingegeben (Domain klein).
- **Konto:** neuer Abschnitt „E-Mail-Adresse“ – eigene Adresse vollständig sichtbar; Ändern oder Entfernen nur mit
  **aktuellem Passwort** (Anti-Ziel „gekaperte Sitzung“). Hinweistext: wofür sie genutzt wird; ohne eingerichtete
  Mail der Zusatz, dass der Admin den Versand noch nicht eingerichtet hat.
- **Admin sieht nur eine Maske:** erster Buchstabe des lokalen Teils, dann `•••`, dann `@` und die Domain, z. B.
  `p•••@idesia.de`. Die Maske wird auf dem Server gebildet; die volle Adresse eines anderen Benutzers geht nie an
  Admin-Seiten oder Admin-API-Antworten.
- **Nicht lesbare Adresse** (Schlüssel geändert): gilt als „keine Adresse“; Konto zeigt „Adresse nicht lesbar – bitte
  neu eintragen“ (wie beim TMDB-Token), die Admin-Liste zeigt „–“.
- Ändern oder Entfernen der Adresse löscht offene **Reset**-Tokens des Benutzers.
- Admins setzen eine Adresse nur beim **Einladen**; ändern können sie sie danach nicht (Tippfehler bei offener
  Einladung: Konto löschen und neu einladen – es hat noch keine Daten).

### 5. Einmal-Links (Reset und Einladung)

- Neue Tabelle `password_tokens`: `id`, `user_id` (FK, `onDelete: .cascade`), `purpose` (`reset` | `invite`),
  `token_hash` (SHA-256, hex), `expires_at`, `created_at`.
- Token: 32 Byte Zufall, Base64URL, nur im Link; gespeichert wird nur der Hash.
- Gültigkeit: **Reset 1 Stunde, Einladung 7 Tage.** Ein neuer Token derselben Art für denselben Benutzer ersetzt
  den alten (löscht ihn). Nach Benutzung wird der Token gelöscht; ein erfolgreiches Setzen löscht **alle** Tokens
  des Benutzers. Abgelaufene **Reset**-Tokens räumt der vorhandene tägliche Job auf; abgelaufene Einladungen bleiben
  (höchstens eine pro Konto), damit ihr Link weiter auf den Admin verweisen kann.
- Link: `<Adresse von WatchSwifty>/reset-password?token=…` (für beide Arten dieselbe Seite).
- **Seite `GET /reset-password`:** prüft den Token nur lesend und zeigt das Formular (neues Passwort zweimal);
  ungültig/abgelaufen → freundliche Meldung mit Link zu „Passwort vergessen“; der Text nennt für Einladungen den
  Admin, eine erkennbar abgelaufene Einladung bekommt „wende dich an deinen Admin“. Ein GET verbraucht den Token nie (Mail-Scanner rufen Links vorab auf).
  `Referrer-Policy: strict-origin` und `Cache-Control: no-store` auf dieser Seite. *(Korrektur nach Review:
  ursprünglich `no-referrer` – damit senden Browser beim Formular-POST `Origin: null`, und der Origin-Check lehnt
  jedes Passwort-Setzen mit 403 ab. `strict-origin` schickt als Referer nur die Origin, der Token bleibt draußen.)*
- **`POST /reset-password`** (Token im Formular): Passwort-Regeln wie überall (`AccountValidation`), beide Felder
  gleich; setzt den Hash, löscht die Tokens, meldet den Benutzer an (Sitzung) und leitet weiter: Reset → `/`,
  Einladung → `/account` mit Hinweis „Willkommen – trag hier deinen TMDB-Token ein“.
- Die Seiten sind ohne Anmeldung erreichbar; der bestehende Origin-Check für POST gilt weiter.

### 6. „Passwort vergessen“

- Link **„Passwort vergessen?“** auf der Login-Seite – nur wenn Mail eingerichtet ist.
- `GET /forgot-password`: Formular mit Benutzername. Ohne eingerichtete Mail: Hinweis, sich an den Admin zu wenden
  (kein Formular).
- `POST /forgot-password`: antwortet **immer** mit derselben Seite und demselben Text („Falls es das Konto gibt und
  eine Mail-Adresse hinterlegt ist, ist eine Mail unterwegs. Der Link gilt eine Stunde.“) und ohne messbaren
  Zeitunterschied: Suche, Token und Versand laufen in einer losgelösten Task; die Anfrage wartet nicht darauf.
- **Drosselung:** höchstens ein Reset-Mail pro Benutzer alle 5 Minuten (existiert ein Reset-Token, der jünger ist,
  passiert nichts).
- **Konten ohne Passwort bekommen nie eine Reset-Mail** *(Entscheidung Claude)* – egal ob die Einladung offen oder
  abgelaufen ist. Sonst könnte ein Eingeladener das Konto nach Ablauf der 7 Tage ohne den Admin aktivieren; bei
  abgelaufener Einladung entscheidet der Admin per „Einladung erneut senden“.
- Fehler beim Versand: nur Log (Warnung mit Benutzername, ohne Adresse und Link).

### 6a. Login verrät keine Benutzernamen mehr *(Entscheidung Claude)*

Heute prüft der Login bcrypt nur, wenn der Benutzername existiert; die Antwortzeit verrät also schon jetzt, welche
Namen es gibt – das Anti-Ziel für „Passwort vergessen“ wäre damit wertlos. Der Login führt deshalb auch für
unbekannte Benutzer und für Konten ohne Passwort einen bcrypt-Vergleich gegen einen festen Platzhalter-Hash aus
(gleiche Kosten), danach wie bisher die Verzögerung und dieselbe Meldung. Mit Test, dass beide Wege bcrypt
ausführen.

### 7. Einladung

- Formular **„Konto anlegen“** auf der Benutzer-Seite bekommt das Feld **„E-Mail-Adresse“** und zwei Wege:
  - Adresse angegeben, Passwort leer → **Einladung**: Konto ohne nutzbares Passwort anlegen, Einladungstoken,
    Mail senden. Nur möglich, wenn Mail eingerichtet ist (sonst 422 mit Hinweis).
  - Passwort angegeben → wie heute (Startpasswort); eine angegebene Adresse wird nur gespeichert.
  - Ohne eingerichtete Mail sieht das Formular aus wie heute plus optionales Adressfeld; der Hinweis erklärt, dass
    Einladungen erst nach der Einrichtung unter **System** gehen.
- **Konto ohne Passwort:** `password_hash` bekommt einen Wert, der nie zu einem Passwort passt; der Login prüft das
  vor dem Hash-Vergleich und verhält sich wie bei falschem Passwort (gleiche Meldung, gleiche Verzögerung) – kein
  Fehler 500 durch einen ungültigen bcrypt-Hash.
- **Mail schlägt fehl:** Das Konto bleibt angelegt; die Seite zeigt die Fehlermeldung und den Knopf
  „Einladung erneut senden“.
- **Benutzerliste:** Spalte „E-Mail“ mit Maske; Status „Einladung offen (bis TT.MM.JJJJ)“ bzw. „Einladung
  abgelaufen“; Knopf **„Einladung erneut senden“** (neuer Token, alter ungültig), solange das Konto kein Passwort hat.
  „Passwort setzen“ durch den Admin bleibt möglich und beendet die Einladung.
- Text der Einladung: wer eingeladen hat (Admin-Benutzername), der eigene Benutzername, Link, Ablaufdatum, ein Satz
  zum TMDB-Token.

### 8. App-API (`openapi.yaml`)

- `UserSummary`: + `emailHint` (Maske, nullable), + `invitePending` (bool), + `inviteExpiresAt` (nullable).
- `POST /v1/admin/users` (`NewUser`): `password` optional, + `email` optional; Regeln wie im Web (7.).
  Schlägt nur der Versand der Einladung fehl, bleibt es bei **201** mit `UserSummary` und zusätzlichem Feld
  `inviteMailError` (deutsche Meldung, sonst fehlend) *(Entscheidung Claude)* – das Konto existiert ja, und ein
  automatischer Neuversuch würde sonst an „Benutzername ist vergeben“ scheitern. Neu senden über den nächsten Punkt.
- `POST /v1/admin/users/{id}/invite`: Einladung erneut senden (422, wenn das Konto schon ein Passwort hat oder Mail
  nicht eingerichtet ist).
- `GET /v1/me`: + `email` (eigene, vollständig, nullable).
- `PUT /v1/me/email`: `{ email, currentPassword }`; leere Adresse entfernt sie.
- `GET/PUT/DELETE /v1/admin/mail` und `POST /v1/admin/mail/test` (`{ to }`): wie die System-Seite; Antworten
  enthalten nie das Passwort (`hasPassword: bool`).
- Fehlercodes *(Entscheidung Claude)*: Mail nicht eingerichtet → **422** `mailNotConfigured`; Versand
  fehlgeschlagen (Testmail, Einladung erneut senden) → **503** `mailFailed` mit der deutschen Meldung in
  `{"code","message"}` (anfangs 502; Cloudflare ersetzt 502-Antworten durch eine eigene Seite).

### 9. Docker und Doku

- `docker-compose.yml`: auskommentierter, optionaler Block für SwiftyRelay – Netzwerk `swifty-relay` (external) und
  Volume `swifty-relay-certs` (external) unter `/certs/swifty-relay:ro`. Ohne Relay ändert sich nichts.
- README: neuer Abschnitt **„E-Mail (optional)“** – Einrichtung unter System, Beispiel SwiftyRelay
  (Host `swifty-relay`, Port 2525, STARTTLS, Benutzer `watchswifty`, Passwort = `SMTP_IN_PASSWORD`,
  CA-Datei `/certs/swifty-relay/ca/ca-bundle.pem`; SwiftyRelay muss vorher einmal gestartet sein), Beispiel für einen
  normalen Anbieter, Hinweis „Adresse von WatchSwifty“ und Reverse-Proxy, Absatz zu „Passwort vergessen“ ergänzen
  (Mail-Weg vor `reset-password`). Konfigurationstabelle bleibt unverändert (keine neuen Umgebungsvariablen).
- CHANGELOG-Abschnitt, `VERSION` → `0.3.0`.

## Dem Umsetzer überlassen

- Genaue Texte der Mails und Seiten (Deutsch, Ton wie die bestehenden Seiten).
- Ob die Mail-Einstellungen in `app_settings` oder einer eigenen Tabelle liegen (verschlüsselt als ein Block ist fest).
- Aufteilung in Services/Controller nach dem Muster `UserAdminService`/`AccountService`; Tests mit Fake-`MailSender`.
- Wert für „kein Passwort“ und wie der Login ihn erkennt (Anforderung: kein 500, gleiches Verhalten wie falsches
  Passwort).
- Quoted-printable vs. Base64 für den Text (7-Bit-sicher ist fest).
