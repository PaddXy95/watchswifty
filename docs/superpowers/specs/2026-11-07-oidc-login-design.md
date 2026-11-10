# WatchSwifty – Login über OpenID Connect (SSO)

Stand: 2026-11-10 · Status: Entwurf, überarbeitet · Ergänzt `2026-11-07-watchswifty-design.md` (Abschnitt 5.1 Login)

**Warum:** Wer schon einen Identity-Provider betreibt (Authentik, Keycloak, Authelia, Pocket ID, Zitadel, Kanidm,
Google …), soll sich darüber bei WatchSwifty anmelden, statt für die App eigene Passwörter zu pflegen.

**Überarbeitung 2026-11-10:** Abgeglichen mit dem Code nach App-API (0.2.x) und Mail (0.3.0): Konten ohne Passwort
(`User.noPasswordHash`), Einladungen, „Passwort vergessen“, E-Mail-Adresse je Konto, App-API, `reset-password`.
Von „nur Authentik“ auf jeden OIDC-Provider verallgemeinert; Authentik bleibt das Beispiel in der Doku. Zweite
Prüfung mit Schwerpunkt Migration (Umstieg, Providerwechsel, Rückweg, Downgrade).

## Entschieden (vom Nutzer)

1. **OpenID Connect direkt in der App** (Authorization Code Flow + PKCE), kein Forward-Auth über den Reverse-Proxy.
2. **Ein Provider, frei wählbar** per Umgebungsvariablen; ein Button „Mit {OIDC_NAME} anmelden“.
3. **Beide Logins:** Passwort-Login bleibt, ist aber per `PASSWORD_LOGIN=false` abschaltbar.
4. **Signatur des ID-Tokens prüfen** über die öffentlichen Schlüssel des Providers (JWKS) mit `jwt-kit` direkt –
   **keine** OIDC-Bibliothek wie `oauth-kit` (Begründung unter „Technische Entscheidungen“).
5. **Eine Adresse für den Provider:** WatchSwifty erreicht ihn unter derselben https-Adresse wie der Browser, mit
   öffentlich vertrauenswürdigem Zertifikat. `OIDC_ISSUER` reicht; die Endpunkte aus der Discovery gelten unverändert.
6. **Verknüpfung = Paar (Issuer, sub)**, nicht nur `sub`.
7. **Erster Login wird immer bestätigt:** Eine unbekannte Identität landet auf der Seite „Neues Konto anlegen“
   (Name vorbelegt, Hinweis aufs Verknüpfen) – nie stillschweigend ein neues Konto.
8. **E-Mail-Adresse vom Provider** für verknüpfte Konten ohne Passwort; Konten mit Passwort behalten die manuelle
   Adresse.
9. **App verbinden** (`/api/auth/authorize`): verknüpfte Konten gehen vorher einmal durch den Provider, damit ein
   dort gesperrter Benutzer kein neues Geräte-Token bekommt. (Eingeschränkt auf „SSO-Konten“, s. „Meine
   Entscheidungen“.)
10. **Verknüpfungslinks:** Admin-Knopf „Verknüpfungslink“ auf der Benutzer-Seite (per Mail oder einmal angezeigt)
    und Shell-Notausgang `link-oidc <benutzer>`. Einladungslinks bieten bei aktivem OIDC zusätzlich „Mit {name}
    verknüpfen“, bei abgeschaltetem Passwort-Login nur das.
11. **Issuer-Umzug:** Befehl `oidc-move-issuer <alt> <neu>` schreibt die Verknüpfungen auf eine neue Issuer-URL um.
12. **Korrekturen aus der zweiten Prüfung** (Migration, Sessions, API) übernommen; sie stehen in den jeweiligen
    Abschnitten.
13. **Einstellungen im UI (2026-11-10):** Provider-Daten und der Passwort-Login-Schalter werden unter **System →
    Anmeldung (SSO)** gepflegt (verschlüsselt in der DB, wie die Mail) – **keine `OIDC_*`-Umgebungsvariablen**.
    Abschalten des Passwort-Logins nur mit Schutz (OIDC eingerichtet, handelnder Admin verknüpft); Notschalter
    `PASSWORD_LOGIN=true` erzwingt ihn beim Start. Auch über die App-API (Admin). Speichern prüft die Discovery und
    speichert bei Fehlern trotzdem (mit Warnung); dazu „Verbindung testen“.

## Begriffe

- **Verknüpftes Konto:** OIDC ist konfiguriert **und** `oidc_issuer` passt zum konfigurierten Issuer (Vergleich ohne
  abschließenden Schrägstrich) **und** `oidc_subject` ist gesetzt. Eine Verknüpfung mit einem anderen (alten) Issuer
  zählt als **nicht** verknüpft; neu verknüpfen ersetzt sie. Ist OIDC nicht konfiguriert, ist kein Konto verknüpft
  (die Spalten bleiben aber erhalten).
- **SSO-Konto:** verknüpft **und** ohne nutzbaren Passwort-Login (kein Passwort **oder** `PASSWORD_LOGIN=false`).
  Nur für SSO-Konten gilt der Umweg über den Provider beim App-Verbinden.
- **Kanonische Adresse:** Origin der Rücksprung-URL (`OIDC_REDIRECT_URL`, sonst erster Eintrag von `PUBLIC_ORIGIN`).

## Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**
- Anmelden mit einem Klick über den Provider; wer WatchSwifty nutzen darf, regelt der Provider (Freigabe der
  Application für Benutzer/Gruppen).
- Bestehende Konten samt Daten bleiben erhalten und lassen sich verknüpfen; der Umstieg ist auf der Benutzer-Seite
  sichtbar und ohne Shell machbar.
- Neue Personen brauchen kein vom Admin angelegtes Konto: der erste Login legt es nach Bestätigung an.
- Funktioniert mit jedem standardkonformen OIDC-Provider, auch ohne `preferred_username`.
- Es gibt einen Rückweg (OIDC wieder abschalten, älteres Image) ohne Datenbank-Handarbeit.

**Nicht-Ziele**
- Mehrere Provider gleichzeitig.
- Abmelden beim Provider (Single Logout): „Abmelden“ beendet nur die WatchSwifty-Sitzung.
- Admin-Rechte aus Provider-Gruppen: bleiben in der App unter **Benutzer**.
- Benutzernamen aus dem Provider nachziehen (nur als Vorschlag beim Anlegen genutzt).
- Verknüpfung über die Oberfläche lösen (neu verknüpfen ersetzt sie; Admin-Verknüpfungslink bzw. `link-oidc`).
- Getrennte interne Adresse für den Provider oder Zertifikate einer eigenen CA.
- Sitzung sofort beenden, wenn ein Benutzer beim Provider gesperrt wird: die Web-Sitzung läuft wie heute bis zu
  30 Tage weiter, bestehende Geräte-Tokens bis zu 90 Tage. (Neue Geräte-Tokens bekommt ein SSO-Konto nicht mehr.)
- Öffentliche Clients ohne Secret.
- Aufräumen alter Sessions allgemein (betrifft auch heute schon abgemeldete Browser; eigenes Thema).

**Anti-Ziele** (wäre ein Fehlschlag, auch wenn es technisch funktioniert)
- Jemand übernimmt ein bestehendes Konto, nur weil sein Provider-Benutzername gleich heißt.
- Nach einem Providerwechsel öffnet eine zufällig gleiche `sub` des neuen Providers ein fremdes Konto.
- Beim Umstieg entstehen unbemerkt leere Zweitkonten.
- WatchSwifty startet nicht oder hängt, weil der Provider gerade nicht erreichbar ist.
- Man sperrt sich aus (Passwort-Login aus, aber OIDC nicht eingerichtet oder kein Admin verknüpft).
- Eine vom Provider gelieferte, ungeprüfte Adresse bekommt „Passwort vergessen“-Links für ein Konto mit Passwort.
- Anonyme Aufrufe füllen die Datenbank (Session-Zeilen pro Login-Versuch).

## Technische Entscheidungen

| Entscheidung | Optionen | Wahl | Begründung |
|---|---|---|---|
| Anbindung | Forward-Auth (Header vom Proxy); OIDC in der App | OIDC in der App | Header müsste blind vertraut werden, hängt am Proxy-Setup |
| Token-Prüfung | ohne Signatur (TLS zum Token-Endpunkt); JWKS mit `jwt-kit` | JWKS mit `jwt-kit` | Standardweg, unabhängig vom Transportweg |
| OIDC-Bibliothek | `oauth-kit` 1.1.0; Imperial; eigene ~200 Zeilen auf `jwt-kit` | eigene auf `jwt-kit` | `oauth-kit` prüft `iss` und `nonce` nicht, lädt JWKS nur per Hintergrunddienst (Login scheitert, bis er lief; kein Nachladen bei unbekannter `kid`), Discovery beim Erzeugen, ~14 000 Zeilen mit 15 Providern, zwei Zusatzpakete, macOS 15; Imperial ohne generisches OIDC |
| `jwt-kit`-Version | 5.8.0 (2026-10-28), 5.9.0 (2026-11-10) | `from: "5.8.0"` | verträglich mit `swift-crypto` 5 im Projekt (`jwt-kit` erlaubt 4.1–<6) |
| Algorithmen | alles aus JWKS; nur asymmetrisch | RS256/384/512, PS256/384/512, ES256/384/512, EdDSA | HS* bräuchte das Client-Secret als Schlüssel, `none` ist unsigniert |
| Client-Anmeldung am Token-Endpunkt | Basic; Post | nach Discovery: `client_secret_basic`, wenn angeboten oder Feld fehlt, sonst `client_secret_post` | deckt alle gängigen Provider ab |
| Konto-Schlüssel | `sub`; (Issuer, `sub`) | (Issuer, `sub`) | `sub` ist nur je Issuer eindeutig |
| Zustand zwischen Start und Rücksprung | Fluent-Session; verschlüsseltes Kurzzeit-Cookie | Cookie `watchswifty_oidc`, AES-GCM über `TokenCipher` | Session-Zeilen entstehen sonst schon bei jedem anonymen Start und werden nie aufgeräumt |
| Verknüpfungslinks | Zweck in `password_tokens`; eigene Tabelle | eigene Tabelle `oidc_link_tokens` | ältere Images lesen unbekannte Zwecke als `.reset` (`PasswordToken.tokenPurpose`) – ein Verknüpfungslink würde nach einem Downgrade ein Passwort setzen |
| Sperre | keine; `AsyncMutex` | `app.oidcIdentityLock` für Anlegen **und** Verknüpfen | sonst bei leerer DB zwei Admins bzw. 500 durch den Unique-Index bei gleichzeitigem Verknüpfen |

## Ablauf

### Login-Seite
- OIDC konfiguriert → Button „Mit {OIDC_NAME} anmelden“ (Link auf `GET /auth/oidc/start`, mit `returnTo`, falls
  vorhanden). Passwortformular und „Passwort vergessen?“ nur, wenn der Passwort-Login an ist.

### `GET /auth/oidc/start?returnTo=…&link=…&invite=…`
1. Anfrage nicht über die kanonische Adresse (Host/`X-Forwarded-Host` wie in `OriginCheckMiddleware`) → 302 auf
   denselben Pfad samt Query unter der kanonischen Adresse (sonst fehlen beim Rücksprung die Cookies).
2. Absicht (`OIDCIntent`) bestimmen:
   - `link=<token>` → `linkToken` (Admin-Verknüpfungslink oder `link-oidc`);
   - `invite=<token>` → `invite` (Einladungslink);
   - sonst, nur bei bestehender Sitzung: die per `POST /account/oidc/link` (`link`) bzw. vom App-Verbinden
     (`reauth`) in der Session hinterlegte Absicht – wird dabei aus der Session gelöscht;
   - sonst `login`.
   Die Absichten `link` und `reauth` entstehen nur serverseitig (POST bzw. angemeldete Sitzung), nie aus einem
   Query-Parameter – sonst könnte eine fremde Seite per Link ein Verknüpfen auslösen.
3. `state`, `nonce` (je 32 Zufallsbytes Base64URL), PKCE-`code_verifier` (S256 über vorhandenes `pkceChallenge`),
   Startzeit, Absicht, `returnTo` (nur wenn `isSafeReturnTo`) und ggf. Link-/Einladungstoken in das Cookie
   `watchswifty_oidc` (`OIDCFlowCookie`, verschlüsselt mit `TokenCipher`, `HttpOnly`, `SameSite=Lax`,
   `Path=/auth/oidc`, `Max-Age=600`, `Secure` wenn die kanonische Adresse https ist). Ein neuer Start ersetzt das
   Cookie. **Die Fluent-Session wird dabei nicht angelegt.**
4. 302 zum `authorization_endpoint`: `response_type=code`, `scope=openid profile email`, `client_id`,
   `redirect_uri`, `state`, `nonce`, `code_challenge`, `code_challenge_method=S256`. Kein `prompt`.

### `GET /auth/oidc/callback`
1. Cookie fehlt, lässt sich nicht entschlüsseln, ist älter als 10 Minuten oder `state` passt nicht → „Anmeldung
   abgelaufen – bitte erneut versuchen.“ Das Cookie wird in jedem Fall gelöscht (einmalig).
2. `error`-Parameter → Meldung (Fehlerfälle).
3. Code am `token_endpoint` tauschen (Client-Secret, `code_verifier`, `redirect_uri`).
4. ID-Token prüfen (`OIDCTokenValidator`): Algorithmus aus der Liste, Signatur über JWKS (`kid`), `iss` = `issuer`
   der Discovery (exakt), `aud` enthält die Client-ID, bei mehreren `aud` muss `azp` = Client-ID sein, `exp` nicht
   abgelaufen und `iat` nicht in der Zukunft (je 60 s Toleranz), `nonce` = Cookie-Wert.
5. Verwendet werden nur `iss`, `sub`, `preferred_username`, `email`, `name`. Access-/Refresh-Tokens werden verworfen;
   nichts davon wird gespeichert oder geloggt.
6. Weiter je nach Absicht (Verknüpfen und Anlegen unter `app.oidcIdentityLock`; gehört die Identität schon einem
   anderen Konto → Fehler, nichts geändert; Unique-Index-Verletzung → dieselbe Meldung statt 500):
   - **`reauth`** (App verbinden): (Issuer, `sub`) muss zum angemeldeten Konto gehören → Session-Merker
     `oidc.verifiedAt = jetzt`, Weiterleitung auf `returnTo`. Sonst „Bei {name} ist ein anderes Konto angemeldet.“
   - **`link`** (Konto-Seite, Benutzer noch angemeldet): Issuer + `sub` am angemeldeten Konto speichern (ersetzt eine
     Verknüpfung mit altem Issuer), Hinweis „Mit {name} verknüpft.“ Inzwischen abgemeldet → weiter wie `login`.
   - **`linkToken`:** Token in `oidc_link_tokens` prüfen (nicht abgelaufen); verknüpfen, Token löschen, als dieses
     Konto anmelden.
   - **`invite`:** Einladungstoken prüfen (`PasswordTokenService.check`, Zweck `invite`); verknüpfen, alle
     Passwort-Tokens des Kontos löschen, anmelden, Weiterleitung `/account?welcome=1`.
   - **`login`:** Konto mit diesem (Issuer, `sub`) vorhanden → E-Mail abgleichen (s. u.), anmelden. Sonst Identität
     und Zeitpunkt ins Cookie `watchswifty_oidc` legen (neu verschlüsselt, 10 Minuten) und auf
     `GET /auth/oidc/new-account` weiterleiten.
7. **Anmelden** genau wie beim Passwort-Login (`req.auth.login` + `req.session.authenticate`); erst hier entsteht
   die Session. Weiterleitung auf `returnTo` oder `/`.

### Neues Konto anlegen (`GET`/`POST /auth/oidc/new-account`)
- Nur mit geparkter, höchstens 10 Minuten alter Identität im Cookie, sonst „Anmeldung abgelaufen – bitte erneut
  versuchen.“
- Seite: „Mit {name} ist noch kein WatchSwifty-Konto verknüpft.“ Feld „Benutzername“, vorbelegt mit dem Vorschlag:
  `preferred_username` → Teil vor `@` von `preferred_username` bzw. `email` → `name`; jeweils normalisiert, unerlaubte
  Zeichen entfernt, auf 32 Zeichen gekürzt; nur wenn danach gültig, sonst leer. Ist der Vorschlag schon vergeben,
  bleibt das Feld leer und die Seite sagt es.
- Hinweis (deutlich, über dem Knopf):
  - Passwort-Login an: „Hast du schon ein Konto? Dann hier **kein** neues anlegen: mit Passwort anmelden und unter
    **Konto** mit {name} verknüpfen. Eingeladen? Den Link aus der Einladungs-Mail benutzen.“
  - Passwort-Login aus: „Hast du schon ein Konto? Dann hier **kein** neues anlegen, sondern den Admin um einen
    Verknüpfungslink bitten. Eingeladen? Den Link aus der Einladungs-Mail benutzen.“
- Knöpfe „Konto anlegen“ und „Abbrechen“ (löscht das Cookie, zurück zur Login-Seite).
- `POST` (Origin-Prüfung): Name ungültig → `AccountValidation.usernameMessage`; vergeben →
  `AccountValidation.duplicateMessage`; Identität inzwischen verknüpft → einfach anmelden; sonst unter
  `app.oidcIdentityLock` Konto ohne Passwort (`User.noPasswordHash`) mit Issuer + `sub` und Provider-E-Mail anlegen.
  Admin wird es nur, wenn es noch gar keinen Benutzer gibt. Cookie löschen, anmelden, Weiterleitung auf `returnTo`
  bzw. `/account?welcome=1`.

### E-Mail-Adresse vom Provider
- Gilt nur für **verknüpfte Konten ohne Passwort** (inkl. neu angelegter Konten).
- Bei jedem Login über den Provider: liefert er `email` und `EmailAddress.normalize` akzeptiert sie → verschlüsselt
  speichern (ersetzt die alte); fehlt sie oder ist sie ungültig → bisherige Adresse bleibt. `email_verified` wird nicht
  ausgewertet (Authentik schickt seit 2025.10 standardmäßig `false`); vertretbar, weil Konten ohne Passwort nie
  „Passwort vergessen“-Mails bekommen.
- Konto-Seite: Adresse nur lesbar, Hinweis „kommt von {name} – dort ändern“. Web `POST /account/email` und API
  `PUT /v1/me/email` → `409` mit Code `emailFromProvider`, Meldung „Die Adresse kommt von {name} – bitte dort ändern.“
- Konten mit Passwort (auch bei `PASSWORD_LOGIN=false`): unverändert manuell mit Passwort-Bestätigung; ihre Adresse
  wird nie vom Provider überschrieben – auch nicht beim Ein- und Ausschalten des Passwort-Logins.
- Bekanntes Restrisiko: Setzt ein Admin einem Konto ohne Passwort später ein Passwort, behält es die vom Provider
  übernommene Adresse, und „Passwort vergessen“ ginge an sie. Hinweis im README beim Umstieg.

## Bestehende Konten verknüpfen
- **Konto-Seite**, neuer Abschnitt „{name}“ (nur wenn OIDC konfiguriert):
  - nicht verknüpft (auch: mit altem Issuer) → Button „Mit {name} verknüpfen“ (`POST /account/oidc/link`, durch die
    Origin-Prüfung): legt Absicht `link` in der (bestehenden) Session ab und leitet auf `/auth/oidc/start`. Läuft die
    Seite nicht über die kanonische Adresse → Weiterleitung auf `<kanonisch>/account` mit Hinweis „Verknüpfen geht
    nur über <Adresse> – dort erneut anmelden und klicken.“;
  - verknüpft → Hinweis „Mit {name} verknüpft“.
- **Benutzer-Seite (Admin)**, nur wenn OIDC konfiguriert:
  - Badge „{name}“ je verknüpftem Konto;
  - Statuskasten „{x} von {y} Konten mit {name} verknüpft · Admin verknüpft: ja/nein“; bei eingeschaltetem
    Passwort-Login zusätzlich „Erst wenn alle verknüpft sind (mindestens ein Admin), `PASSWORD_LOGIN=false` setzen.“;
  - Knopf **„Verknüpfungslink“** je nicht verknüpftem Konto (nicht für das eigene – dafür die Konto-Seite):
    `POST /admin/users/:id/sso-link`. Mail eingerichtet und Adresse lesbar → Link per Mail
    (`MailTexts.ssoLink`), Hinweis „Verknüpfungslink an p•••@… gesendet.“; sonst wird der Link **einmal** auf der Seite
    angezeigt („nur jetzt sichtbar, weitergeben“). Gültig 7 Tage, einmalig, ein neuer ersetzt den alten. Schlägt die
    Mail fehl, wird der Link stattdessen angezeigt (mit der Fehlerursache).
  - Gleiche Macht wie heute „Passwort setzen“: wer den Link öffnet und sich beim Provider anmeldet, übernimmt das Konto.

## Einladungen
- Einladungen bleiben wie im Mail-Entwurf (Konto ohne Passwort + Einmal-Link, 7 Tage).
- Einladungsseite (`GET /reset-password?token=…`, Zweck `invite`) bei konfiguriertem OIDC: zusätzlich Knopf „Mit
  {name} verknüpfen“ → `/auth/oidc/start?invite=<token>`. Bei abgeschaltetem Passwort-Login zeigt sie **nur** diesen
  Knopf.
- Einladungs-Mail (`MailTexts.invite`) nennt bei konfiguriertem OIDC beide Wege, bei abgeschaltetem Passwort-Login nur
  „über {name} anmelden“.
- Admin legt bei abgeschaltetem Passwort-Login Konten nur noch als Einladung an (Feld „Startpasswort“ fehlt).

## Konten ohne Passwort
- Über OIDC angelegte Konten haben `password_hash = User.noPasswordHash` (`"!"`), wie Einladungen. Der Passwort-Login
  prüft solche Konten bereits gegen `dummyPasswordHash` (gleiche Antwortzeit, gleiche Meldung) – keine Änderung nötig.
- `UserAdminService.row(for:)`: Konto ohne Passwort **und verknüpft** → `InviteState.none` (nicht „Einladung
  abgelaufen“); „Einladung erneut senden“ nur für nicht verknüpfte Konten ohne Passwort; `resendInvite` für verknüpfte
  Konten → `422` „Das Konto ist mit {name} verknüpft – keine Einladung nötig.“ Ist OIDC nicht (mehr) konfiguriert,
  gelten diese Konten wieder als Einladung (Rückweg, s. Migration).
- Konto-Seite: „Passwort ändern“ nur für Konten mit Passwort und nur bei eingeschaltetem Passwort-Login.
- Der Admin kann (bei eingeschaltetem Passwort-Login) wie bisher ein Passwort setzen.

## App verbinden (`/api/auth/authorize`)
- OIDC konfiguriert, Anfrage nicht über die kanonische Adresse **und** (nicht angemeldet **oder** SSO-Konto) → 302
  auf dieselbe URL unter der kanonischen Adresse (alle Parameter stehen in der URL; der Rücksprung zur App ist
  adressunabhängig). Angemeldete Konten mit Passwort-Login bleiben auf ihrer Adresse.
- Angemeldetes **SSO-Konto** und `oidc.verifiedAt` fehlt oder ist älter als 5 Minuten → Absicht `reauth` in der
  Session, Weiterleitung auf `/auth/oidc/start?returnTo=<diese URL>`. Erst danach erscheint die Seite mit „Verbinden“.
  Bei bestehender Provider-Sitzung meist ohne Eingabe. Ein gesperrter Benutzer kommt nicht zurück (manche Provider
  zeigen dann ihre eigene Fehlerseite statt mit `error` zurückzuleiten) – es entsteht kein Code.
- `POST /api/auth/authorize` prüft dieselbe Bedingung; ohne frische Bestätigung kein Code, sondern dieselbe
  Weiterleitung.
- Provider nicht erreichbar → Meldung „{name} ist gerade nicht erreichbar.“, kein Code.

## Passwort-Login abgeschaltet (Schalter unter System)

| Bereich | Web | App-API |
|---|---|---|
| Login | Seite zeigt nur den OIDC-Button; `POST /login` → 404 | – |
| Passwort vergessen | Link weg; `GET`/`POST /forgot-password` → 404 | – |
| Einmal-Links | `GET /reset-password`: Einladung → nur „Mit {name} verknüpfen“, Reset-Link → „ungültig“; `POST /reset-password` → 404 | – |
| Eigenes Passwort | „Passwort ändern“ weg; `POST /account/password` → 404 | `PUT /v1/me/password` → `409 passwordLoginDisabled` |
| Konto anlegen | nur als Einladung (Mail nötig); mit Passwort → `409` „Der Passwort-Login ist abgeschaltet – nur Einladungen.“ | `POST /v1/admin/users` mit `password` → `409 passwordLoginDisabled` |
| Einladung erneut senden | bleibt (Link führt zu SSO) | bleibt |
| Passwort setzen (Admin) | Formular weg; Route → 404 | `POST /v1/admin/users/{id}/password` → `409 passwordLoginDisabled` |
| Verknüpfungslink, Admin-Rechte, Löschen | bleiben | bleiben |

- `ADMIN_USERNAME`/`ADMIN_PASSWORD` werden ignoriert (Hinweis im Log); der erste OIDC-Login wird Admin, solange es
  keinen Benutzer gibt.
- Abschalten nur, wenn OIDC eingerichtet ist und der handelnde Admin selbst verknüpft ist (s. „Einstellungen“).
- Start mit abgeschaltetem Passwort-Login, Benutzer vorhanden, aber **kein Admin verknüpft** → Log-Warnung „Kein Admin ist
  mit {name} verknüpft – mit `link-oidc <admin>` einen Verknüpfungslink erzeugen.“; dazu Anzahl nicht verknüpfter
  Konten. Kein Startfehler (sonst ginge auch `docker exec … link-oidc` nicht).
- Start-Warnung ohne Benutzer: mit OIDC „Kein Benutzer vorhanden – der erste Login über {name} wird Admin.“, sonst wie
  heute.

## App-API (`openapi.yaml`)
- `Me`: neue Pflichtfelder `ssoLinked: boolean` (Konto ist verknüpft) und `passwordLogin: boolean` (Server erlaubt den
  Passwort-Login; die App blendet „Passwort ändern“ nur bei `hasPassword && passwordLogin` ein). Beschreibung von
  `hasPassword` korrigieren („Konto hat ein Passwort; über SSO angelegte Konten haben keins.“).
- `UserSummary`: neues Pflichtfeld `ssoLinked: boolean`; `invitePending` für verknüpfte Konten immer `false`.
- Neuer Fehler `APIError.passwordLoginDisabled` (`409`, Code `passwordLoginDisabled`, „Der Passwort-Login ist
  abgeschaltet.“) für die Fälle der Tabelle oben.
- `PUT /v1/me/email`: zusätzliche Antwort `409 emailFromProvider`.
- Neu: `POST /v1/admin/users/{id}/sso-link` → `200 { mailed: boolean, emailHint?: string, url?: string,
  mailError?: string }` (`url` nur, wenn nicht gemailt); eigenes Konto → `422 selfAction`; OIDC nicht konfiguriert →
  `404`; schon verknüpft → `422 validation`.
- Kein API-Endpunkt zum Verknüpfen des eigenen Kontos (nur Browser).
- Abwärtskompatibel: nur neue Felder und Fehlercodes; ältere App-Versionen ignorieren sie.

## Einstellungen (System → Anmeldung (SSO))

Ersetzt die früheren `OIDC_*`-Variablen. Gespeichert als ein verschlüsselter JSON-Block (`app_settings.oidc_config`,
`TokenCipher`), wie die Mail-Einstellungen. Nur Admins.

| Feld | Pflicht | Bedeutung |
|---|---|---|
| Anzeigename | nein | Name in Buttons und Meldungen, Standard `SSO`, höchstens 40 Zeichen |
| Issuer | ja | z. B. Authentik `https://auth.example.de/application/o/watchswifty/`, Keycloak `https://kc.example.de/realms/home`, Pocket ID `https://id.example.de` |
| Client-ID | ja | |
| Client-Secret | ja | wird nie wieder angezeigt („gespeichert – leer lassen zum Behalten“) |
| Adresse von WatchSwifty | ja | `https://host[:port]` ohne Pfad (Regeln wie bei der Mail); vorbelegt mit der Mail-Adresse bzw. der Adresse der Anfrage. Rücksprung-URL = Adresse + `/auth/oidc/callback` (wird zum Kopieren angezeigt) – das ist die **kanonische Adresse** |

- **Secret neu eingeben, wenn sich Issuer oder Client-ID ändern** (sonst könnte eine gekaperte Admin-Sitzung das
  gespeicherte Secret an einen eigenen „Provider“ schicken lassen) – Meldung „Bitte das Client-Secret neu eingeben –
  Issuer oder Client-ID wurden geändert.“
- **Speichern** prüft danach die Discovery (wie „Verbindung testen“); schlägt das fehl, ist trotzdem gespeichert und
  die Seite meldet „Gespeichert, aber die Prüfung schlug fehl: {Grund}“.
- **Verbindung testen:** Discovery + Schlüssel laden → „Verbindung in Ordnung: Issuer {issuer}, {n} Schlüssel.“ bzw.
  der Fehler (nicht erreichbar, Issuer passt nicht, nur symmetrische Signatur …).
- **Einstellungen löschen:** nur bei eingeschaltetem Passwort-Login, sonst „Erst den Passwort-Login einschalten.“
  Danach ist OIDC aus (Rückweg wie unter „Migration“).
- **Passwort-Login** (Schalter im selben Abschnitt):
  - Abschalten nur, wenn OIDC eingerichtet ist („Erst OIDC einrichten.“) und das eigene Konto mit dem Provider
    verknüpft ist („Verknüpfe zuerst dein eigenes Konto mit {name} (unter Konto) – sonst sperrst du dich aus.“).
  - Einschalten geht immer.
  - **Notschalter:** Umgebungsvariable `PASSWORD_LOGIN=true` erzwingt beim Start den Passwort-Login; die Seite zeigt
    „Per PASSWORD_LOGIN=true erzwungen“ und der Schalter ist gesperrt. Andere Werte werden ignoriert (Hinweis im Log).
- **Laufzeit:** Die Einstellungen werden beim Start und nach jeder Änderung in einen Zwischenspeicher geladen
  (`LoginSettingsStore`); Änderungen wirken sofort, ohne Neustart. Der Provider-Client wird pro Einstellungsstand
  erzeugt (Discovery/JWKS-Cache neu bei geänderten Daten). Unlesbare Einstellungen (Server-Schlüssel geändert) → OIDC
  aus, Passwort-Login an, Hinweis auf der System-Seite und im Log.
- Die kanonische Adresse gilt zur Laufzeit zusätzlich als erlaubte Origin der CSRF-Prüfung (`OriginCheckMiddleware`).
- **App-API (Admin):** `GET/PUT/DELETE /v1/admin/oidc`, `POST /v1/admin/oidc/test`, `PUT /v1/admin/oidc/password-login`
  – gleiche Regeln und Texte; das Secret erscheint nie in Antworten (`hasClientSecret`).
- **Discovery** über `<Issuer>/.well-known/openid-configuration` (Issuer mit oder ohne Schrägstrich am Ende), beim
  ersten Login bzw. Test geladen, 24 Stunden zwischengespeichert; verworfen, sobald Token- oder JWKS-Endpunkt mit 404
  oder Verbindungsfehler antworten. Der `issuer` der Discovery muss bis auf einen abschließenden Schrägstrich zum
  eingetragenen Issuer passen; gespeichert und im Token verglichen wird der `issuer`-Wert der Discovery.
- **JWKS** beim ersten Bedarf geladen; bei unbekannter `kid` höchstens einmal pro Minute neu geladen.
- Die App startet auch, wenn der Provider nicht erreichbar ist.
- Nur asymmetrische Signaturen; Hinweis bei HS*: „{name} signiert ID-Tokens symmetrisch – beim Provider einen
  asymmetrischen Signaturschlüssel einstellen (Authentik: beim Provider einen Signing Key wählen).“

## Fehlerfälle (Meldung auf der Login-Seite, Details nur im Log)

| Fall | Meldung |
|---|---|
| Provider nicht erreichbar (Discovery, Token, JWKS) | „{name} ist gerade nicht erreichbar.“ |
| Cookie fehlt/manipuliert/älter als 10 Minuten oder `state` passt nicht (z. B. alter Tab) | „Anmeldung abgelaufen – bitte erneut versuchen.“ |
| `error=access_denied` (Benutzer beim Provider nicht freigegeben) | „{name} hat die Anmeldung abgelehnt.“ |
| Provider verweigert den Zugriff mit eigener Fehlerseite statt Rücksprung (z. B. Pocket ID mit Gruppenbeschränkung) | keine – der Benutzer bleibt beim Provider; README-Hinweis |
| anderer `error` | „Anmeldung über {name} fehlgeschlagen.“ |
| Token ungültig (Algorithmus, Signatur, `iss`, `aud`/`azp`, `exp`/`iat`, `nonce`) oder Discovery-Issuer passt nicht | „Anmeldung über {name} fehlgeschlagen.“ |
| Geparkte Identität für „Neues Konto“ abgelaufen | „Anmeldung abgelaufen – bitte erneut versuchen.“ |
| Identität beim Verknüpfen gehört schon einem anderen Konto (auch gleichzeitig) | „Dieses {name}-Konto ist schon mit einem anderen WatchSwifty-Konto verknüpft.“ |
| Verknüpfungslink ungültig/abgelaufen/benutzt | „Der Verknüpfungslink ist ungültig oder abgelaufen – bitte den Admin um einen neuen bitten.“ |
| Einladung ungültig/abgelaufen | Texte aus `PasswordLinkProblem` |
| `reauth` mit anderer Identität | „Bei {name} ist ein anderes Konto angemeldet.“ |
| Discovery liefert keinen `token_endpoint`/`jwks_uri` | „Anmeldung über {name} fehlgeschlagen.“ + Log |

## Migration

### Datenbank
- `AddUserOIDC` (am Ende der Migrationsliste): je Feld ein `update()` (SQLite ergänzt pro `ALTER TABLE` nur eine
  Spalte, wie `AddFollowFields`): `oidc_issuer` (string, optional), `oidc_subject` (string, optional); danach per
  `SQLDatabase` `CREATE UNIQUE INDEX users_oidc_identity ON users (oidc_issuer, oidc_subject)` (`NULL`-Werte
  kollidieren nicht). `revert`: erst `DROP INDEX`, dann die Felder.
- `CreateOIDCLinkToken`: Tabelle `oidc_link_tokens` (`id`, `user_id` → `users` mit `onDelete: .cascade`,
  `token_hash` unique, `created_at`, `expires_at`).
- Bestehende Daten werden nicht verändert; bestehende Sessions und Geräte-Tokens bleiben gültig.

### Umstieg einer bestehenden Installation (README, Schritt für Schritt)
1. Provider einrichten, OIDC-Variablen setzen, **Passwort-Login an lassen**, neu starten.
2. Jeder meldet sich wie gewohnt an und verknüpft unter **Konto**. Wer sein Passwort nicht mehr weiß: „Passwort
   vergessen“ oder Admin-**Verknüpfungslink**. Offene Einladungen können direkt über {name} angenommen werden.
3. Benutzer-Seite prüfen: Statuskasten „alle verknüpft, Admin verknüpft: ja“.
4. `PASSWORD_LOGIN=false` setzen, neu starten. Noch nicht verknüpfte Konten: Verknüpfungslink vom Admin. Wer noch
   eine Web-Sitzung hat, kann auch selbst unter **Konto** verknüpfen.
5. Bestehende Geräte-Tokens laufen weiter (bis 90 Tage); beim nächsten Verbinden geht es über {name}.

Schutz vor typischen Fehlern: Erster SSO-Login legt nie stillschweigend ein Konto an (Seite mit Hinweis);
Statuskasten vor dem Abschalten; Log-Warnung ohne verknüpften Admin; `link-oidc` als letzter Ausweg.

### Providerwechsel (z. B. Authentik → Keycloak)
- Neue Issuer-URL, neue `sub`-Werte: alle Konten gelten als nicht verknüpft (alter Issuer bleibt gespeichert, aber
  ohne Wirkung). Am einfachsten mit eingeschaltetem Passwort-Login wie beim Umstieg neu verknüpfen; sonst
  Verknüpfungslinks vom Admin (für den Admin selbst: `link-oidc`).
- Eine gleiche `sub` beim neuen Provider öffnet kein altes Konto (Issuer gehört zum Schlüssel).

### Issuer-Umzug desselben Providers (neue Domain, umbenannter Slug)
- `docker exec -it watchswifty /app/docker-entrypoint.sh oidc-move-issuer <alt> <neu>`: schreibt `oidc_issuer` aller
  Konten mit `<alt>` (Vergleich ohne abschließenden Schrägstrich) auf `<neu>` um, in einer Transaktion; gibt die
  Anzahl aus. Gäbe es dadurch doppelte Paare (Issuer, `sub`) → Abbruch ohne Änderung mit Meldung.
- Vorher `OIDC_ISSUER` auf die neue Adresse setzen; `<neu>` muss genau der `issuer` der neuen Discovery sein (der
  Befehl lädt sie zur Prüfung, wenn erreichbar, und warnt bei Abweichung).
- Nur für denselben Provider – bei einem echten Wechsel ändern sich die `sub`-Werte, dann neu verknüpfen.

### Rückweg: OIDC wieder abschalten
- OIDC-Variablen entfernen (und `PASSWORD_LOGIN` an). Kein Konto gilt dann als verknüpft; Spalten bleiben erhalten.
- Konten mit Passwort: normaler Passwort-Login.
- Konten ohne Passwort (über SSO angelegt): gelten wieder als Einladung („Einladung abgelaufen“) → Admin „Einladung
  erneut senden“ (mit Mail) oder „Passwort setzen“; ohne Admin-Zugang `reset-password`.
- Schaltet man OIDC später wieder ein (gleicher Issuer), greifen die alten Verknüpfungen wieder.

### Downgrade auf ein älteres Image
- Fluent ignoriert die zusätzlichen Spalten und die Tabelle `oidc_link_tokens`; die Migrationen bleiben in
  `_fluent_migrations` stehen und greifen nach einem erneuten Update wieder.
- Konten ohne Passwort gelten im alten Image als Einladung (Rückweg wie oben).
- Verknüpfungslinks sind im alten Image wirkungslos (eigene Tabelle); Einladungslinks behalten ihre alte Bedeutung.

### App
- Nur neue Felder/Fehlercodes in der API (abwärtskompatibel). Neue App-Versionen nutzen `Me.passwordLogin` und
  `ssoLinked`; ältere zeigen bei `PASSWORD_LOGIN=false` ggf. „Passwort ändern“ und bekommen `409
  passwordLoginDisabled` mit verständlicher Meldung.

## Notausgang bei Aussperrung
- `docker exec -it watchswifty /app/docker-entrypoint.sh link-oidc <benutzername>` – löst eine bestehende Verknüpfung
  und gibt einen Verknüpfungslink aus (`<kanonisch>/auth/oidc/start?link=<token>`, 1 Stunde gültig, ersetzt ältere).
  Wer ihn öffnet und sich beim Provider anmeldet, wird mit diesem Konto verknüpft und angemeldet. Kein Neustart nötig.
  Gedacht vor allem für den Admin selbst (der Admin-Knopf gilt nicht fürs eigene Konto).
- `reset-password <benutzername>` (gibt es schon) setzt weiterhin ein Passwort; nutzbar nur bei eingeschaltetem
  Passwort-Login.
- Ohne OIDC-Konfiguration brechen `link-oidc` und `oidc-move-issuer` mit Meldung ab. README beschreibt alle drei
  Befehle.

## Datenmodell
- `users.oidc_issuer` (Text, optional) und `users.oidc_subject` (Text, optional), eindeutig als Paar
  (`users_oidc_identity`).
- `password_hash` bleibt Pflichtfeld; „kein Passwort“ = `User.noPasswordHash`.
- `oidc_link_tokens`: nur SHA-256-Hash des Tokens (`APITokenService.hash`), höchstens ein Token je Konto; abgelaufene
  räumt die tägliche Pflege mit auf (`DailyRefresh`).
- Cookie `watchswifty_oidc` (`OIDCFlowCookie`, verschlüsselt): `state`, `nonce`, `verifier`, `startedAt`, `intent`,
  `returnTo`, `linkToken`, `inviteToken`, `pending` (geparkte Identität), `pendingAt`.
- Session (nur bei angemeldeten Benutzern): `oidc.intent` (`link`/`reauth`), `oidc.verifiedAt`.

## Klassen & Funktionen

### Einstellungen im UI (Nachtrag)
- `OIDCSettings` (Codable: `displayName`, `issuer`, `clientID`, `clientSecret`, `baseURL`, `passwordLogin`) →
  `var config: OIDCConfig`.
- `OIDCSettingsService` (`req.oidcSettings`): `state() -> OIDCSettingsState`, `save(_ input: OIDCSettingsInput) ->
  OIDCSettings`, `setPasswordLogin(_ enabled: Bool, actingUser: User)`, `delete()`; jede Änderung lädt den
  `LoginSettingsStore` neu.
- `LoginSettings` (`oidc: OIDCConfig?`, `passwordLogin: Bool`, `passwordLoginForced: Bool`) in `LoginSettingsStore`
  (`app.loginSettings`, synchron lesbar); `AppConfig.passwordLoginForced` aus `PASSWORD_LOGIN=true`.
- `OIDCProviderStore` (`app.oidcProviders.provider(for: OIDCConfig)`): ein Client je Einstellungsstand; Tests
  übergeben einen festen Fake.
- `OIDCProvider.check() async throws -> OIDCCheck` (`issuer`, `keyCount`).
- `AppConfig.oidc`/`passwordLogin` bleiben nur als Vorbelegung für Tests (werden beim Start in die DB geschrieben,
  nie aus der Umgebung gelesen).

### `OIDCConfig` (`Sources/App/Auth/OIDC/OIDCConfig.swift`)
Konfiguration aus der Umgebung; Teil von `AppConfig` (`var oidc: OIDCConfig?`, `var passwordLogin: Bool = true`).
- `static func fromEnvironment(_ env: [String: String], publicOrigins: [String]) throws -> OIDCConfig?` – `nil`, wenn
  keine OIDC-Variable gesetzt ist; `ConfigError` bei Teilkonfiguration, fehlender Rücksprung-URL, unlesbarer
  Secret-Datei.
- Felder: `issuer: String`, `clientID: String`, `clientSecret: String`, `redirectURL: URL`, `displayName: String`.
- `var canonicalOrigin: String` – `scheme://host[:port]` der Rücksprung-URL, normalisiert wie
  `OriginCheckMiddleware.normalizeOrigin`.
- `func matchesIssuer(_ stored: String?) -> Bool` – Vergleich ohne abschließenden Schrägstrich.
- `AppConfig.fromEnvironment` prüft zusätzlich: `PASSWORD_LOGIN=false` ohne `oidc` → `ConfigError`.

### `OIDCIdentity`
`struct OIDCIdentity: Codable, Sendable, Equatable` – `issuer`, `subject`, `preferredUsername: String?`,
`email: String?`, `name: String?`.

### `OIDCError`
`enum OIDCError: Error, Equatable` – `unreachable`, `denied`, `failed(logReason: String)`, `symmetricSigning`,
`misconfigured(logReason: String)`; `func message(name: String) -> String` liefert die Texte der Fehlertabelle.
`logReason` enthält nie Code oder Token.

### `OIDCProvider` (Protokoll, in Tests ersetzbar)
```swift
protocol OIDCProvider: Sendable {
    /// URL des authorization_endpoint mit allen Parametern; lädt bei Bedarf die Discovery.
    func authorizationURL(state: String, nonce: String, codeChallenge: String) async throws -> URL
    /// Tauscht den Code und gibt die geprüfte Identität zurück.
    func exchange(code: String, codeVerifier: String, nonce: String) async throws -> OIDCIdentity
    /// `issuer` der aktuellen Discovery (für `oidc-move-issuer`).
    func discoveredIssuer() async throws -> String
}
```
Alle werfen nur `OIDCError`.

### `LiveOIDCProvider` (actor)
Init `(config: OIDCConfig, transport: any OIDCTransport, logger: Logger, now: @Sendable () -> Date = { .now })`.
Hält Discovery (24 h) und `JWTKeyCollection` im Speicher.
- `private func discovery() async throws -> OIDCDiscovery` – lädt/cacht; prüft Issuer-Übereinstimmung, Pflichtfelder
  (`authorization_endpoint`, `token_endpoint`, `jwks_uri`).
- `private func dropDiscovery()` – nach 404/Verbindungsfehler am Token- oder JWKS-Endpunkt.
- `private func keys(for kid: String?) async throws -> JWTKeyCollection` – lädt beim ersten Mal; fehlt `kid`,
  höchstens einmal pro Minute neu.
- `private func tokenRequest(code:codeVerifier:) async throws -> String` – POST `application/x-www-form-urlencoded`,
  Client-Anmeldung laut `token_endpoint_auth_methods_supported` (Basic: ID und Secret vorher form-urlencoded, RFC 6749
  §2.3.1); liefert nur `id_token`. HTTP-Fehler → `OIDCError.failed` mit Status und `error`-Code (ohne Body-Rest).

### `OIDCTransport` (Protokoll)
`func get(_ url: URL) async throws -> (status: UInt, body: Data)` und
`func postForm(_ url: URL, fields: [String: String], basicAuth: (String, String)?) async throws -> (status: UInt, body: Data)`.
Live-Umsetzung über Vapors `app.client`; Netzwerkfehler → `OIDCError.unreachable`.

### `OIDCDiscovery`
`struct OIDCDiscovery: Decodable` – `issuer`, `authorizationEndpoint`, `tokenEndpoint`, `jwksURI`,
`tokenEndpointAuthMethodsSupported: [String]?`, `idTokenSigningAlgValuesSupported: [String]?`.

### `OIDCTokenValidator`
Reine Prüflogik, ohne Netzwerk.
- `static let allowedAlgorithms: Set<String>` – RS256/384/512, PS256/384/512, ES256/384/512, EdDSA.
- `func validate(_ idToken: String, keys: JWTKeyCollection, issuer: String, clientID: String, nonce: String, now: Date) async throws -> OIDCIdentity`
  – Header-`alg` gegen die Liste (sonst `symmetricSigning` bzw. `failed`), dann Signatur, `iss`, `aud`/`azp`,
  `exp`/`iat` (60 s Toleranz), `nonce`. Fehlende `kid` im Schlüsselsatz → eigener Fehlerfall, damit
  `LiveOIDCProvider` neu laden kann.

### `OIDCFlowCookie`
`struct OIDCFlowCookie: Codable, Sendable` mit den Feldern aus „Datenmodell“ und
`enum OIDCIntent: String, Codable { case login, link, reauth, linkToken, invite }`.
- `func seal(_ cipher: TokenCipher) throws -> String`
- `static func open(_ value: String?, cipher: TokenCipher, now: Date) -> OIDCFlowCookie?` – `nil` bei fehlendem,
  manipuliertem oder über 10 Minuten altem Inhalt (Start bzw. `pendingAt`).
- `func cookie(secure: Bool) -> HTTPCookies.Value` / `static var expired: HTTPCookies.Value` (Name
  `watchswifty_oidc`, `Path=/auth/oidc`).

### `OIDCLoginService` (`req.oidcLogin`)
Kontologik ohne HTTP, gemeinsam für Web, API und Befehle.
- `func resolve(_ identity: OIDCIdentity, flow: OIDCFlowCookie, sessionUser: User?) async throws -> OIDCOutcome`
- `enum OIDCOutcome { case signIn(User, redirect: String), linked(User), reauthenticated, confirmNewAccount(suggestion: String?), failure(String) }`
- `func createAccount(_ identity: OIDCIdentity, username: String) async throws -> User` – unter
  `app.oidcIdentityLock`; wirft `APIError.validation` bei ungültigem/vergebenem Namen.
- `func link(_ user: User, to identity: OIDCIdentity) async throws` – unter `app.oidcIdentityLock`; Identität fremd
  bzw. Unique-Index-Verletzung → `APIError.validation` mit dem Text der Fehlertabelle.
- `func syncEmail(_ user: User, from identity: OIDCIdentity) async throws` – nur verknüpfte Konten ohne Passwort.
- `static func suggestUsername(_ identity: OIDCIdentity) -> String?`
- `func readiness() async throws -> OIDCReadiness` – `linked`, `total`, `adminLinked` (Statuskasten, Start-Warnung).

### `OIDCLinkTokenService`
Über `oidc_link_tokens`.
- `func issue(userID: UUID, lifetime: TimeInterval, now: Date = .now) async throws -> String` – ersetzt ältere.
- `func check(_ token: String, now: Date = .now) async throws -> OIDCLinkToken?`
- `func consume(_ token: String, now: Date = .now) async throws -> UUID?` – liefert die User-ID und löscht den Token.
- `func deleteExpired(now: Date = .now) async throws -> Int`
- Laufzeiten: `static let commandLifetime: TimeInterval = 3600`, `static let adminLifetime: TimeInterval = 7 * 86_400`.

### `OIDCController`
Registriert (mit `User.sessionAuthenticator()`): `GET /auth/oidc/start`, `GET /auth/oidc/callback`,
`GET /auth/oidc/new-account`, `POST /auth/oidc/new-account`. Nur registriert, wenn `config.oidc != nil` (sonst 404).

### Befehle
- `LinkOIDCCommand: AsyncCommand` als `link-oidc` (Argument `benutzer`): löst Verknüpfung, `issue(…, commandLifetime)`,
  gibt den Link aus.
- `MoveOIDCIssuerCommand: AsyncCommand` als `oidc-move-issuer` (Argumente `alt`, `neu`): Transaktion, Konfliktprüfung,
  Anzahl ausgeben; Abweichung von `discoveredIssuer()` als Warnung.
- Fehler über `CommandFailure`.

### Änderungen an bestehenden Typen
- `User`: `@OptionalField oidcIssuer`, `@OptionalField oidcSubject`,
  `func isLinked(_ oidc: OIDCConfig?) -> Bool`, `func isSSOAccount(_ oidc: OIDCConfig?, passwordLogin: Bool) -> Bool`
  (= verknüpft && !(hasPassword && passwordLogin)), `func emailFromProvider(_ oidc: OIDCConfig?) -> Bool`
  (= verknüpft && !hasPassword).
- `AddUserOIDC`, `CreateOIDCLinkToken` (Migrationen, am Ende der Liste).
- `AuthController`: Login-Seite mit OIDC-Button/ohne Formular; `POST /login` → 404 bei abgeschaltetem Passwort-Login.
- `PasswordResetController`: Einladungsseite mit SSO-Knopf; bei abgeschaltetem Passwort-Login Regeln laut Tabelle.
- `MailTexts`: `invite` mit SSO-Hinweis, neu `ssoLink(to:username:inviter:link:expires:)`.
- `AccountController`/`AccountService`: `POST /account/oidc/link`; `changePassword` → 404 (Web) bzw.
  `passwordLoginDisabled` (API); `setEmail` → `409 emailFromProvider`.
- `AdminUsersController`/`UserAdminService`: Badge, Statuskasten, `InviteState`-Regel, `resendInvite`-Sperre,
  `createSSOLink(id:actingUserID:) async throws -> SSOLinkResult` (`mailed`, `emailHint`, `url`, `mailError`),
  Anlegen nur als Einladung bei abgeschaltetem Passwort-Login.
- `APIError.passwordLoginDisabled`, `APIError.emailFromProvider`.
- `APIAuthorizeController`: kanonische Adresse (nur wenn nötig), `reauth` für SSO-Konten in `show` und `decide`.
- `APIHandler+Auth`/`+Account`/`+Admin`: `ssoLinked`, `passwordLogin`, neue Fehler, `sso-link`-Endpunkt.
- `bootstrapAdmin`: ignoriert `ADMIN_*` bei abgeschaltetem Passwort-Login; neue Warnungen (ohne Benutzer, ohne
  verknüpften Admin).
- `DailyRefresh`: zusätzlich `OIDCLinkTokenService.deleteExpired`.
- `configure(...)`: neuer Parameter `oidcProvider: (any OIDCProvider)? = nil`; mit `config.oidc` →
  `app.oidcProvider = oidcProvider ?? LiveOIDCProvider(...)`; `app.oidcIdentityLock = AsyncMutex()`; kanonische
  Adresse in `OriginCheckMiddleware(allowedOrigins:)`; Befehle `link-oidc`, `oidc-move-issuer`.
- `Package.swift`: `.package(url: "https://github.com/vapor/jwt-kit.git", from: "5.8.0")`, Produkt `JWTKit` im
  Target `App`.

## Tests
Swift Testing; Web-/API-Abläufe mit `withTestApp` (neuer Parameter `oidc: FakeOIDCProvider`). `FakeOIDCProvider`
liefert eine einstellbare Identität oder einen `OIDCError`, merkt sich Aufrufe (`state`, `nonce`, Challenge).
Validator- und Provider-Tests erzeugen Schlüssel im Test (ES256 und RSA über `jwt-kit`) und nutzen einen
`FakeOIDCTransport` mit festen Antworten.

**`OIDCConfigTests`**
- `completeConfigEnablesOIDC` – alle drei Variablen → `oidc` gesetzt, Name Standard `SSO`.
- `partialConfigFails` – nur Issuer → `ConfigError`.
- `redirectDefaultsToFirstPublicOrigin` / `missingRedirectAndOriginFails`.
- `secretFromFile` / `unreadableSecretFileFails`.
- `passwordLoginOffWithoutOIDCFails`.
- `issuerMatchIgnoresTrailingSlash`.

**`OIDCTokenValidatorTests`**
- `validES256TokenYieldsIdentity`, `validRS256TokenYieldsIdentity`.
- `wrongIssuerRejected`, `foreignAudienceRejected`, `multipleAudiencesNeedAzp`.
- `expiredTokenRejected` (61 s nach `exp`), `expiryWithinLeewayAccepted` (59 s).
- `nonceMismatchRejected`, `hs256Rejected`, `algNoneRejected`, `unknownKidReported`.
- `optionalClaimsMayBeMissing` – nur `sub` → Identität ohne Name/E-Mail.

**`LiveOIDCProviderTests`**
- `discoveryWithAndWithoutTrailingSlash`, `discoveryIssuerMismatchFails`.
- `usesBasicAuthWhenOffered`, `usesPostWhenOnlyPostOffered`.
- `unknownKidReloadsOnceThenFails` – zweite unbekannte `kid` innerhalb einer Minute lädt nicht erneut.
- `discoveryDroppedAfterTokenEndpoint404` – nächster Aufruf lädt die Discovery neu.
- `unreachableProviderMapsToUnreachable`, `tokenErrorDoesNotLeakCode`.
- `appStartsWithoutProvider` – `configure` ruft den Transport nicht auf.

**`OIDCFlowCookieTests`**
- `roundTrip`, `tamperedCookieRejected`, `oldCookieRejected` (> 10 Minuten), `otherKeyRejected`.

**`OIDCLoginTests`**
- `startRedirectsWithPKCEAndNonce` – `code_challenge_method=S256`, `scope=openid profile email`, kein `prompt`.
- `anonymousStartCreatesNoSession` – keine Zeile in `_fluent_sessions`, nur Cookie `watchswifty_oidc`.
- `startOnOtherHostRedirectsToCanonical` – inkl. `returnTo`.
- `linkIntentNotFromQuery` – `?intent=link` o. Ä. wird ignoriert.
- `callbackWithoutCookieFails`, `cookieIsSingleUse`, `staleCookieFails`, `stateMismatchFails`.
- `accessDeniedShowsMessage`.
- `knownIdentitySignsIn` – Weiterleitung auf `/` bzw. sicheren `returnTo`; unsicherer `returnTo` wird verworfen.
- `unknownIdentityAlwaysConfirms` – auch mit freiem, gültigem `preferred_username` kein Konto ohne Bestätigung.
- `newAccountPrefilledFromPreferredUsername`, `newAccountSuggestionFromEmail` (Google ohne `preferred_username`),
  `invalidSuggestionLeavesFieldEmpty` (Kanidm `a@b.c`), `takenSuggestionLeavesFieldEmpty`.
- `confirmCreatesAccountWithoutPassword` – Identität und E-Mail (verschlüsselt) gespeichert.
- `confirmTakenNameFails`, `cancelClearsCookie`, `pendingIdentityExpires`.
- `firstAccountBecomesAdminOnlyOnEmptyDatabase`, `concurrentFirstLoginsCreateOneAdmin`.
- `sameSubjectOtherIssuerIsUnknown` – kein Login ins alte Konto.
- `accountWithoutPasswordEmailFollowsProvider` – neue Adresse ersetzt; ohne `email` bleibt sie.
- `accountWithPasswordEmailNeverOverwritten` – auch bei `PASSWORD_LOGIN=false`.
- `passwordLoginForAccountWithoutPasswordStillFails` – gleiche Meldung, bcrypt gegen Platzhalter.

**`OIDCLinkTests`**
- `linkFromAccountPage`, `linkReplacesOldIssuer`, `oldIssuerShowsLinkButton`.
- `linkToIdentityOfOtherAccountFails`, `concurrentLinkSameIdentityOneWins` – zweiter bekommt Meldung, kein 500.
- `linkOnOtherHostRedirectsToCanonicalAccount`.
- `linkCommandUnlinksAndPrintsURL`, `linkCommandWithoutOIDCFails`, `linkCommandUnknownUserFails`.
- `linkTokenLinksAndSignsIn`, `linkTokenIsSingleUse`, `expiredLinkTokenFails`.
- `linkTokenNotUsableAtResetPassword`.
- `adminSSOLinkMailsWhenPossible`, `adminSSOLinkShownWithoutMail`, `adminSSOLinkShownWhenMailFails`,
  `adminSSOLinkNotForSelf`, `adminSSOLinkViaAPI`.

**`OIDCInviteTests`**
- `invitePageOffersSSO`, `inviteViaSSOLinksAndWelcomes` – Passwort-Tokens gelöscht, `/account?welcome=1`.
- `inviteViaSSOWithPasswordLoginOff` – Seite nur mit SSO-Knopf, `POST /reset-password` → 404.
- `expiredInviteViaSSOFails`, `inviteMailMentionsSSO`.

**`PasswordLoginDisabledTests`**
- `loginPageShowsOnlyOIDC`, `passwordLoginReturns404`, `forgotReturns404`, `resetLinkInvalid`.
- `accountPasswordReturns404AndAPIConflict` – Web 404, API `409 passwordLoginDisabled`.
- `adminCreateOnlyAsInvitation` – mit Passwort Web/API `409`; ohne Passwort mit Adresse → Einladung.
- `adminSetPasswordDisabled` – Web 404, API `409`.
- `adminEnvIgnored` – kein Admin aus `ADMIN_*`, erster OIDC-Login (nach Bestätigung) wird Admin.
- `meReportsPasswordLoginFalse`.

**`OIDCAdminTests`**
- `linkedAccountWithoutPasswordIsNoInvitation` – Seite ohne „Einladung abgelaufen“/„erneut senden“; API
  `invitePending == false`, `ssoLinked == true`.
- `resendInviteForLinkedAccountFails` – 422.
- `readinessCountsCurrentIssuerOnly` – Statuskasten, alter Issuer zählt nicht.
- `meReportsSSOLinked`, `setEmailForAccountWithoutPasswordConflicts` – Web und API `409 emailFromProvider`.

**`OIDCMigrationTests`**
- `migrationAddsColumnsAndIndex` / `migrationReverts` – Index zuerst gelöscht.
- `duplicateIdentityRejectedByIndex`.
- `moveIssuerRewritesAll`, `moveIssuerConflictChangesNothing`, `moveIssuerUnknownOldIsNoop`.
- `oidcDisabledTreatsLinkedAsInvitation` – ohne OIDC-Konfiguration: „Einladung erneut senden“ möglich, Konto-Seite
  ohne OIDC-Abschnitt, Passwort-Login für Konten mit Passwort unverändert.
- `reenablingOIDCRestoresLinks`.
- `startupWarnsWithoutLinkedAdmin` – `readiness()` bei `PASSWORD_LOGIN=false` liefert die Warnung.
- `expiredLinkTokensCleanedDaily`.

**`APIAuthorizeOIDCTests`**
- `ssoAccountMustReauthenticate` – `GET` leitet auf `/auth/oidc/start` mit `returnTo`.
- `reauthWithSameIdentityShowsConnect`, `reauthWithOtherIdentityFails` – kein Code.
- `decideWithoutFreshReauthIssuesNoCode` – direkter `POST` → Weiterleitung statt Code.
- `reauthExpiresAfterFiveMinutes`.
- `passwordAccountNeedsNoReauth`, `passwordAccountNotRedirectedToCanonical`.
- `anonymousOnOtherHostRedirectsToCanonical`.

## Sicherheit
- `state` + `nonce` + PKCE (S256); Werte einmalig, verschlüsselt im Kurzzeit-Cookie, höchstens 10 Minuten gültig.
- Callback ist ein `GET` aus einer Top-Level-Weiterleitung: Cookies mit `SameSite=Lax` kommen mit, die Origin-Prüfung
  greift bei `GET` nicht. Verknüpfen-Start (`POST /account/oidc/link`), Konto anlegen und Admin-Verknüpfungslink sind
  `POST` und werden geprüft. Die Absichten `link`/`reauth` kommen nie aus der URL.
- Kein automatisches Verknüpfen über gleiche Benutzernamen; Verknüpfen nur angemeldet, per Einladung oder per
  Verknüpfungslink vom Admin.
- Schlüssel ist (Issuer, `sub`) – Providerwechsel öffnet keine fremden Konten.
- Nur asymmetrische Signaturen; `iss` exakt gegen die Discovery.
- Codes, Tokens, Einladungs- und Verknüpfungslinks erscheinen nie im Log oder in Fehlermeldungen (`link-oidc` gibt den
  Link nur auf der Konsole aus, der Admin-Knopf nur einmal auf der Seite bzw. per Mail).
- Verknüpfungslinks in eigener Tabelle – auch nach einem Downgrade nicht als Passwort-Link nutzbar.
- `FrameDenyMiddleware` setzt nur `frame-ancestors`; kommt später `form-action` dazu, muss der Provider erlaubt sein
  (Weiterleitung nach dem Verknüpfen-`POST`).

## Doku
- README, neuer Abschnitt „Anmeldung über OIDC (SSO)“:
  - allgemein: Client-Typ *confidential*, Redirect-URI `https://<watchswifty>/auth/oidc/callback`, Scopes
    `openid profile email`, asymmetrische Signatur; Freigabe der Benutzer/Gruppen regelt der Provider;
  - Beispiel Authentik: Provider „OAuth2/OpenID“, Signing Key wählen, Subject-Modus auf dem Standard lassen,
    Application anlegen und freigeben; kurze Hinweise zu Issuer-Formaten (Keycloak, Authelia);
  - Beispiel Pocket ID (geprüft am Quellcode v2.19.2): OIDC-Client anlegen (nicht „public“), Callback-URL
    `https://<watchswifty>/auth/oidc/callback`; `OIDC_ISSUER` = `APP_URL` von Pocket ID (ohne Pfad, z. B.
    `https://id.example.de`). Hinweise:
    - Callback muss https sein – Pocket ID lehnt http-Callbacks ab, außer mit `ALLOW_INSECURE_CALLBACK_URLS=true`;
    - ist in Pocket ID `INTERNAL_APP_URL` gesetzt, zeigen Token- und JWKS-Endpunkt in der Discovery auf diese
      interne Adresse – WatchSwifty muss sie erreichen (z. B. gleiches Docker-Netz), sonst „{name} ist gerade nicht
      erreichbar.“;
    - Benutzernamen dürfen dort Großbuchstaben, `@` und 1–50 Zeichen haben; die Seite „Neues Konto anlegen“ schlägt
      dann einen passenden Namen vor oder lässt das Feld leer;
    - Konten ohne E-Mail in Pocket ID liefern keinen `email`-Claim (Adresse bleibt leer bzw. unverändert);
    - mit Gruppenbeschränkung am Client zeigt Pocket ID Nicht-Mitgliedern eine eigene Fehlerseite, statt zu
      WatchSwifty zurückzuleiten;
    - Signatur standardmäßig RS256, nach Schlüsselwechsel ggf. ES256/EdDSA – beides unterstützt;
  - Variablen in `docker-compose.yml` (auskommentiert), `.env.example` und der Konfigurationstabelle;
  - Umstieg Schritt für Schritt, Providerwechsel, Issuer-Umzug, Rückweg (aus „Migration“); Hinweis zum
    E-Mail-Restrisiko;
  - Befehle `link-oidc`, `oidc-move-issuer`, `reset-password`.
- CHANGELOG-Eintrag.
- `2026-11-08-app-api-design.md`: Verweis auf diese Datei; Satz zum Neu-Prüfen beim Verbinden präzisiert.
- `2026-11-09-mail-design.md`: Nachtrag zu Einladungen über SSO und zur Mail „Verknüpfungslink“.

## Meine Entscheidungen (vom Nutzer nicht ausdrücklich bestätigt)
- Konten entstehen beim ersten OIDC-Login (nach Bestätigung); Admin-Rechte bleiben in der App.
- Abmelden nur lokal (kein Single Logout).
- Erster OIDC-Login wird Admin, wenn es noch keinen Benutzer gibt.
- Login über eine andere Adresse als die Rücksprung-URL: erst auf die kanonische Adresse umleiten.
- Der Umweg über den Provider beim App-Verbinden gilt nur für SSO-Konten: Wer einen nutzbaren Passwort-Login hat,
  käme auch bei Sperre beim Provider per Passwort an ein Token – der Umweg brächte dort keine Sicherheit, nur einen
  Ausfallpunkt – Ableitung aus Entscheidung 9.
- `OIDC_NAME` Standard `SSO`; Zeitfenster: Start/Cookie 10 Minuten, Reauth 5 Minuten, Verknüpfungslink per
  `link-oidc` 1 Stunde, per Admin-Knopf 7 Tage (wie Einladungen, ebenfalls per Mail), Discovery-Cache 24 Stunden,
  JWKS-Neuladen höchstens 1×/Minute.
- API-Status für `passwordLoginDisabled` ist `409` (Web-Seiten, die es nicht mehr gibt, antworten `404`).
- Bei abgeschaltetem Passwort-Login bleiben Einladungen möglich (dann SSO-Einladungen), statt 404.
- Start ohne verknüpften Admin bei `PASSWORD_LOGIN=false`: nur Warnung, kein Startfehler (sonst wäre `docker exec …
  link-oidc` unmöglich).
- Admin-Verknüpfungslink nicht fürs eigene Konto (wie „Passwort setzen“).

## Offen / dem Builder überlassen
- Session-ID beim Login erneuern (dann für alle Login-Wege, auch Passwort und Einmal-Links) – eigenes Thema.
- Aufräumen alter Sessions allgemein – eigenes Thema.
- Genaue Texte und Gestaltung.

## Nachtrag (2026-11-08): Rücksprung für die App-Anmeldung
Eingearbeitet in „Ablauf“ und „App verbinden“: Der OIDC-Button gibt `returnTo` an `/auth/oidc/start` weiter, der
Start legt ihn (nur wenn `isSafeReturnTo`) im Cookie ab und nimmt ihn beim Wechsel auf die kanonische Adresse als
Query-Parameter mit; der Callback leitet danach dorthin statt auf `/`.
