# Datenschutzerklärung – WatchSwifty für iOS

Stand: 11.11.2026

WatchSwifty für iOS ist die App zu einem **selbst gehosteten** WatchSwifty-Server. Sie hat keinen eigenen Dienst im
Hintergrund und keinen Betreiber, der Daten sammelt.

## Welche Daten die App verarbeitet
- **Dein eigener Server:** Die App spricht ausschließlich mit der Server-Adresse, die du beim ersten Start eingibst.
  Dorthin gehen alle Inhalte (Sichtungen, Bewertungen, Kommentare, Importe, Kontoeinstellungen). Wer den Server
  betreibt, ist für diese Daten verantwortlich.
- **TMDB-Bilder:** Poster werden direkt von `image.tmdb.org` (The Movie Database) geladen. Dabei sieht TMDB wie bei
  jedem Bildabruf deine IP-Adresse; es werden keine Konto- oder Nutzungsdaten übermittelt.
- **Auf dem Gerät:** Die Server-Adresse und der Gerätename liegen in den App-Einstellungen, das Anmelde-Token
  (Geräte-Token) im Schlüsselbund dieses Geräts (nicht in iCloud). Eine Kopie der Startseite liegt im Cache, damit sie
  beim Öffnen sofort erscheint. Abmelden oder Löschen der App entfernt diese Daten.
- **Anmeldung:** Sie läuft im Browser-Fenster deines Servers. Die App sieht dein Passwort nicht.

## Was die App nicht tut
Keine Werbung, kein Tracking, keine Analyse- oder Absturzdienste von Dritten, keine Weitergabe von Daten.

## Kontakt
Fragen zur App: über die Issues des Projekts auf GitHub (`PaddXy95/watchswifty`). Fragen zu den Daten auf einem
Server: an die Person, die diesen Server betreibt.
