# Changelog

Alle nennenswerten Änderungen an WatchSwifty. Versionen folgen [SemVer](https://semver.org/lang/de/).

## [0.1.0] – 2026-11-07

Erste Version.

### Neu
- **Weiterschauen:** eine Karte pro Serie mit der nächsten Folge, „✓ gesehen“, Ausblenden, Link „Auf Netflix suchen“;
  nur Serien der letzten 3 Monate (ältere per „N ältere Serien anzeigen“).
- **Beobachten:** Serien auf der Serienseite beobachten; Kasten „Neue Folgen“ (mit „Erledigt“) und „Demnächst“
  (Folgen der nächsten 14 Tage) auf der Startseite; Liste der beobachteten Serien unter Konto.
- **Manuelles Tracking:** Folgen/Filme abhaken mit Datum und Dienst (Netflix, Prime Video, Disney+, Apple TV+, HBO Max,
  Paramount+, WOW, Kino, Gekauft, Sonstiges), erneut gesehen, „Ganze Staffel“, „bis hier“ und „Gesamte Serie gesehen“,
  Bewertung 1–10, private Kommentare zu Serie, Staffel und Film.
- **Detailseiten:** Klappentext zu Serie, Film und jeder Folge; Links zu TMDB, IMDb, Rotten Tomatoes und SeriesGraph.
- **Netflix-Import:** Wiedergabeaktivität als CSV (auch Excel-Varianten), automatische TMDB-Zuordnung, „Zu prüfen“,
  „Nicht zugeordnet“, „Zuordnungen“, „Erneut versuchen“ und automatische Wiederholung.
- **Verlauf** und **Bibliothek** mit Filter und Sortierung.
- **Update-Hinweis:** Admin-Seite „System“ mit optionaler Prüfung auf neue Releases bei GitHub
  (alle 12 Stunden, standardmäßig aus) und „Jetzt prüfen“.
- **Statistik:** Filme, Serien, Folgen und verbrachte Zeit (TMDB-Laufzeiten) – insgesamt, pro Jahr und Monat
  sowie nach Bewertung.
- **Benutzer:** mehrere Konten mit getrennten Daten, Admin-Verwaltung, eigener TMDB-Token pro Benutzer
  (in der Datenbank mit AES-GCM verschlüsselt, Schlüssel über `TOKEN_KEY`).
- **Oberfläche:** WatchSwifty-Branding, Smartphone-Layout mit Burger-Menü, Ladebalken und Lade-Animation auf Kacheln,
  deutsche Fehlerseiten.
- **Betrieb:** Docker-Image über GitHub Actions (`ghcr.io/paddxy95/watchswifty`), Compose-Datei, SQLite-Datenbank im
  Volume, Version im Footer und unter `/version`.
