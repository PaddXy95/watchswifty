# WatchSwifty – Login über Authentik (OpenID Connect)

Stand: 2026-11-07 · Status: Entwurf · Ergänzt `2026-11-07-watchswifty-design.md` (Abschnitt 5.1 Login)

**Warum:** Der Nutzer betreibt bereits Authentik und möchte sich darüber bei WatchSwifty anmelden,
statt für die App eigene Passwörter zu pflegen.

## Entschieden (vom Nutzer)

1. **OpenID Connect direkt in der App** (Authorization Code Flow), kein Forward-Auth über den Reverse-Proxy.
2. **Beide Logins:** Passwort-Login bleibt, ist aber per `PASSWORD_LOGIN=false` abschaltbar.
3. **Signatur des ID-Tokens prüfen** über Authentiks öffentliche Schlüssel (JWKS) mit `jwt-kit` (Vapor).

## Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**
- Anmelden mit einem Klick über Authentik; wer WatchSwifty nutzen darf, regelt Authentik
  (Freigabe der Application für Benutzer/Gruppen).
- Bestehende Konten samt Daten bleiben erhalten und lassen sich mit Authentik verknüpfen.
- Neue Personen brauchen kein vom Admin angelegtes Konto mehr: erster Authentik-Login legt es an.

**Nicht-Ziele**
- Abmelden bei Authentik (Single Logout): „Abmelden“ beendet nur die WatchSwifty-Sitzung.
- Admin-Rechte aus Authentik-Gruppen: bleiben in der App unter **Benutzer**.
- Mehrere Login-Anbieter gleichzeitig; Abgleich von Name/E-Mail aus Authentik.
- Verknüpfung wieder lösen.
- Sitzung sofort beenden, wenn ein Benutzer in Authentik gesperrt wird: die WatchSwifty-Sitzung
  läuft wie heute bis zu 30 Tage weiter.

**Anti-Ziele** (wäre ein Fehlschlag, auch wenn es technisch funktioniert)
- Jemand übernimmt ein bestehendes Konto, nur weil sein Authentik-Benutzername gleich heißt.
- WatchSwifty startet nicht oder hängt, weil Authentik gerade nicht erreichbar ist.
- Man sperrt sich aus (Passwort-Login aus, aber Authentik nicht eingerichtet).

## Ansätze

| Ansatz | Abwägung | Ergebnis |
|---|---|---|
| Forward-Auth über den Reverse-Proxy (Header `X-authentik-username`) | Kaum App-Code, aber die App muss dem Header blind vertrauen; hängt am Proxy-Setup | verworfen |
| **OIDC in der App, Signatur via JWKS mit `jwt-kit`** | Standardweg, sicher auch wenn Authentik intern nur per `http://` erreichbar ist; eine neue Abhängigkeit | **gewählt** |
| OIDC ohne Signaturprüfung (Vertrauen per TLS zum Token-Endpunkt) | Kein Zusatzpaket, laut Spezifikation erlaubt – aber nur bei HTTPS zu Authentik sicher | verworfen |
| Fertige Bibliothek (z. B. Imperial) | Kein generisches OIDC für Authentik, kaum gepflegt | verworfen |

## Ablauf

1. **Login-Seite:** Ist OIDC konfiguriert, Button „Mit {OIDC_NAME} anmelden“ (Standard „Mit Authentik
   anmelden“). Das Passwortformular erscheint nur, wenn der Passwort-Login an ist.
2. **`GET /auth/oidc/start`:** erzeugt `state`, `nonce` und einen PKCE-`code_verifier` (S256), legt sie in
   der Session ab und leitet zum `authorization_endpoint` weiter (`response_type=code`,
   `scope=openid profile`, `redirect_uri`, `code_challenge`).
3. **`GET /auth/oidc/callback`:**
   - `error`-Parameter von Authentik → Meldung (s. Fehlerfälle).
   - `state` muss zum Wert in der Session passen; Werte nach einmaliger Verwendung aus der Session löschen.
   - Code am `token_endpoint` gegen Tokens tauschen (mit Client-Secret und `code_verifier`).
   - ID-Token prüfen: Signatur über JWKS (`kid`), `iss` = Issuer, `aud` enthält die Client-ID, `exp`, `nonce`.
   - Aus dem Token werden nur `sub` und `preferred_username` verwendet. Access-/Refresh-Tokens werden
     verworfen, nichts davon wird gespeichert oder geloggt.
4. **Konto bestimmen:**
   1. Konto mit `oidc_subject == sub` vorhanden → anmelden.
   2. Sonst, wenn der Ablauf von „Mit Authentik verknüpfen“ (Konto-Seite) kam und der Benutzer noch
      angemeldet ist → `sub` an dieses Konto hängen (s. Verknüpfen).
   3. Sonst Benutzername = `User.normalize(preferred_username)`:
      - verstößt gegen `AccountValidation.usernameError` → Meldung, kein Konto;
      - Name schon vergeben → Meldung „Es gibt schon ein Konto „x“. Mit Passwort anmelden und unter
        **Konto** mit Authentik verknüpfen.“ (**kein** automatisches Verknüpfen über den Namen);
      - sonst neues Konto anlegen und anmelden. Admin wird es nur, wenn es noch gar keinen Benutzer gibt.
5. **Anmelden** genau wie beim Passwort-Login (`req.auth.login` + `req.session.authenticate`), Weiterleitung auf `/`.

## Bestehende Konten verknüpfen

- Konto-Seite, neuer Abschnitt „Authentik“ (nur wenn OIDC konfiguriert):
  - nicht verknüpft → Button „Mit Authentik verknüpfen“ (`POST`, also durch die CSRF-Prüfung): merkt sich in
    der Session, dass verknüpft werden soll, und startet den Ablauf aus Schritt 2;
  - verknüpft → Hinweis „Mit Authentik verknüpft“.
- Gehört die `sub` schon einem anderen Konto → Fehlermeldung, nichts ändern.
- Benutzer-Seite (Admin): pro Konto sichtbar, ob es mit Authentik verknüpft ist – damit vor dem Abschalten
  des Passwort-Logins erkennbar ist, wer noch fehlt.

## Konten ohne Passwort

- Über Authentik angelegte Konten haben kein Passwort: `password_hash` bleibt leer. Der Passwort-Login lehnt
  einen leeren Hash ab, ohne bcrypt aufzurufen – mit derselben Meldung und Verzögerung wie bei einem
  falschen Passwort.
- Konto-Seite: „Passwort ändern“ nur für Konten mit Passwort.
- Der Admin kann wie bisher unter **Benutzer** ein Passwort setzen; danach geht für dieses Konto auch der
  Passwort-Login.

## Passwort-Login abgeschaltet (`PASSWORD_LOGIN=false`)

- Login-Seite zeigt nur den Authentik-Button; `POST /login` antwortet 404.
- Konto: „Passwort ändern“ ausgeblendet, Route antwortet 404.
- Benutzer (Admin): „Benutzer anlegen“ und „Passwort zurücksetzen“ ausgeblendet, Routen antworten 404.
  Admin-Rechte ändern und Konten löschen bleiben.
- `ADMIN_USERNAME`/`ADMIN_PASSWORD` werden ignoriert (Hinweis im Log); der erste Authentik-Login wird Admin,
  solange es keinen Benutzer gibt.
- `PASSWORD_LOGIN=false` ohne vollständige OIDC-Konfiguration → Startfehler mit klarer Meldung.

## Konfiguration

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `OIDC_ISSUER` | für OIDC | Issuer aus Authentik, z. B. `https://auth.example.de/application/o/watchswifty/` |
| `OIDC_CLIENT_ID` | für OIDC | Client-ID des Authentik-Providers |
| `OIDC_CLIENT_SECRET` / `OIDC_CLIENT_SECRET_FILE` | für OIDC | Client-Secret bzw. Datei damit (Docker-Secret), analog `TOKEN_KEY_FILE` |
| `OIDC_REDIRECT_URL` | nein | Rücksprungadresse; Standard: erster Eintrag aus `PUBLIC_ORIGIN` + `/auth/oidc/callback` |
| `OIDC_NAME` | nein | Anzeigename im Button, Standard `Authentik` |
| `PASSWORD_LOGIN` | nein | `false` schaltet den Passwort-Login ab; Standard an |

- OIDC ist aktiv, wenn Issuer, Client-ID und Secret gesetzt sind. Nur ein Teil davon gesetzt → Startfehler.
  OIDC aktiv, aber weder `OIDC_REDIRECT_URL` noch `PUBLIC_ORIGIN` → Startfehler.
- **Discovery** über `<Issuer>/.well-known/openid-configuration` (mit und ohne Schrägstrich am Ende des Issuers
  funktionierend), erst beim ersten Login geladen und zwischengespeichert. JWKS ebenso, bei unbekannter `kid`
  einmal neu laden. Die App startet auch, wenn Authentik nicht erreichbar ist.
- Unterstützt werden asymmetrisch signierte Tokens (RS256/ES256 über JWKS). In Authentik muss beim Provider
  ein **Signing Key** gewählt sein; ohne Key signiert Authentik mit HS256 – das wird abgelehnt mit einem
  Log-Hinweis, was in Authentik einzustellen ist.

## Fehlerfälle (Meldung auf der Login-Seite, Details nur im Log)

| Fall | Meldung |
|---|---|
| Authentik nicht erreichbar (Discovery, Token, JWKS) | „Authentik ist gerade nicht erreichbar.“ |
| `state` fehlt/passt nicht (z. B. alter Tab) | „Anmeldung abgelaufen – bitte erneut versuchen.“ |
| `error=access_denied` (Benutzer in Authentik nicht freigegeben) | „Authentik hat die Anmeldung abgelehnt.“ |
| Token ungültig (Signatur, `iss`, `aud`, `exp`, `nonce`) | „Anmeldung über Authentik fehlgeschlagen.“ |
| Benutzername ungültig | „Der Authentik-Benutzername „x“ passt nicht: 3–32 Zeichen, nur a–z, 0–9, . _ -“ |
| Benutzername vergeben, Konto nicht verknüpft | s. Ablauf 4.3 |
| `sub` gehört beim Verknüpfen schon einem anderen Konto | „Dieses Authentik-Konto ist schon mit einem anderen WatchSwifty-Konto verknüpft.“ (auf der Konto-Seite) |

## Datenmodell

- `users.oidc_subject` (Text, optional, eindeutig). Neue Migration; in SQLite die Eindeutigkeit als
  separaten Unique-Index anlegen.
- `password_hash` bleibt Pflichtfeld; „kein Passwort“ = leerer String.

## Sicherheit

- `state` + `nonce` + PKCE (S256); Werte einmalig, in der serverseitigen Session.
- Callback ist ein `GET` aus einer Top-Level-Weiterleitung: das Session-Cookie (`SameSite=Lax`) kommt mit,
  die Origin-Prüfung greift bei `GET` nicht. Der Start der Verknüpfung ist ein `POST` und wird geprüft.
- Kein automatisches Verknüpfen über gleiche Benutzernamen (Anti-Ziel Kontoübernahme): Benutzer können ihren
  Namen in Authentik je nach Einstellung selbst ändern.
- Codes und Tokens erscheinen nie im Log oder in Fehlermeldungen.

## Doku

- README, neuer Abschnitt „Anmeldung über Authentik“:
  - in Authentik: Provider „OAuth2/OpenID“, Client-Typ *Confidential*, Redirect-URI
    `https://<watchswifty>/auth/oidc/callback`, Signing Key wählen, Subject-Modus auf dem Standard (gehashte
    Benutzer-ID) lassen, Application anlegen und für die gewünschten Benutzer/Gruppen freigeben;
  - Variablen in `docker-compose.yml` (auskommentiert) und in der Konfigurationstabelle;
  - Umstieg: bestehende Konten unter **Konto** verknüpfen, auf der Benutzer-Seite prüfen, dann
    `PASSWORD_LOGIN=false`.
- CHANGELOG-Eintrag.

## Meine Entscheidungen (vom Nutzer nicht ausdrücklich bestätigt)

- Bestehende Konten werden **nicht** über den Benutzernamen automatisch verknüpft, sondern bewusst über die
  Konto-Seite – ändert meinen ersten Vorschlag, weil sonst ein Authentik-Benutzer, der sich umbenennt, ein
  fremdes Konto übernehmen könnte.
- Konten entstehen beim ersten Authentik-Login automatisch; Admin-Rechte bleiben in der App.
- Abmelden nur lokal (kein Single Logout).
- Ungültiger Authentik-Benutzername → Meldung statt automatischer Umwandlung.
- Nur RS256/ES256, kein HS256.
- Erster Authentik-Login wird Admin, wenn es noch keinen Benutzer gibt.

## Dem Builder überlassen

Aufteilung in Typen (z. B. `OIDCConfig`, `OIDCClient`, `OIDCController`), `jwt-kit`-Version, Client-
Authentifizierung am Token-Endpunkt (Basic oder Post – Authentik kann beides), Caching im Detail,
Session-ID beim Login erneuern (dann für beide Login-Wege), Test-Aufbau (Fake-Provider wie
`FakeTMDBClient`, Schlüssel im Test erzeugen), genaue Texte und Gestaltung.
