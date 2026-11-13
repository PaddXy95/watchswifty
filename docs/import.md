# Import

## Netflix viewing history

1. On netflix.com in a browser (not in the Netflix app): **Konto** (account) → **Einstellungen** (settings) →
   **Titelverlauf** (viewing history) → at the very bottom **Alle herunterladen** (download all).
2. In WatchSwifty, upload the file `NetflixViewingHistory.csv` under **Import**.
3. Unambiguous series and movies are matched to TMDB automatically. Unclear names appear under **Zu prüfen** (to
   review) with the days Netflix lists for them; the rows themselves fold out under „Zeilen anzeigen“ (show rows).
   Each candidate links to its TMDB page, and clicking its poster shows it larger. Episodes that could not be found
   appear under **Nicht zugeordnet** (not matched). Wrong matches can be changed or reset under **Zuordnungen**
   (matches).

Matching needs your [TMDB token](tmdb.md).

## Your own film list

A film list exported from Numbers or Excel as CSV, with the columns Filmname (title), Erscheinungsjahr (release year),
Datum (date), „Mit …“ (with …), Streamingdienst (streaming service), Übeltäter (culprit), Bewertung (rating), Detail
and Bemerkung (remark), can be imported under **Import → Filmliste importieren** (import film list):

- „Mit …“, Übeltäter and Bemerkung go into the comment,
- Detail (0–100) becomes the rating 1–10,
- every row becomes one viewing.

Unclear movies can be picked from suggestions there.

## Importing again

Importing the same (or a newer) export again does not create duplicates. A file saved again in (German) Excel, with
`;` as separator and dates as `DD.MM.YYYY`, is recognised as well.
