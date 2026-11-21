# Import

## Netflix viewing history

1. On netflix.com in a browser (not in the Netflix app): **Konto** (account) → **Einstellungen** (settings) →
   **Titelverlauf** (viewing history) → at the very bottom **Alle herunterladen** (download all).
2. In WatchSwifty, upload the file `NetflixViewingHistory.csv` under **Konto → Import** (account → import).
3. Unambiguous series and movies are matched to TMDB automatically. Unclear names appear under **Zu prüfen** (to
   review) with the days Netflix lists for them; the rows themselves fold out under „Zeilen anzeigen“ (show rows).
   Each candidate links to its TMDB page, and clicking its poster shows it larger. Episodes that could not be found
   appear under **Nicht zugeordnet** (not matched). Wrong matches can be changed or reset under **Zuordnungen**
   (matches).

Matching needs your [TMDB token](tmdb.md). Each account keeps up to 200,000 Netflix rows; an upload that would go
beyond that is refused. Titles longer than 500 characters are cut.

## Other trackers (standard CSV)

History from another tracker (Letterboxd, IMDb, Trakt, TV Time, Simkl, …) or a list of your own can be imported
under **Konto → Import → Aus anderen Trackern importieren** (account → import → import from other trackers) as a CSV in the WatchSwifty standard
format. The page offers an [example file](../Public/import/watchswifty-import-example.csv) to download.

```
type,title,year,tmdb_id,imdb_id,season,episode,watched_on,service,rating,comment
movie,Dune,2021,438631,,,,2024-03-02,netflix,8,Im Kino besser
episode,Severance,2022,,tt11280740,1,3,2024-05-10,apple_tv,,
series,Severance,2022,,tt11280740,,,,,9,
```

| Column | Required | Meaning |
|---|---|---|
| `type` | yes | `movie`, `episode` or `series` |
| `title` | yes | Movie or **series** title (for `episode` the series title, not the episode name) |
| `year` | no | Release year of the movie, first air year of the series |
| `tmdb_id` | no | TMDB id of the movie or series (not of the episode) |
| `imdb_id` | no | IMDb id `tt…` of the movie or series; an episode's own IMDb id is resolved to its series |
| `season`, `episode` | for `episode` | Season and episode number (season 0 = specials) |
| `watched_on` | no | `YYYY-MM-DD` (a time after it is ignored), `DD.MM.YYYY`, `M/D/YY` |
| `service` | no | `netflix`, `prime_video`, `disney_plus`, `apple_tv`, `hbo_max`, `paramount_plus`, `wow`, `cinema`, `purchased`, `other`; names like „Amazon Prime“ are recognised too, anything unknown becomes `other` |
| `rating` | no | 1–10; decimals are rounded |
| `comment` | no | Free text |

- Column names are case-insensitive, their order does not matter, and other columns are ignored. Lines above the
  header row are skipped. `,` and `;` both work as separators (German Excel), and so do UTF-8 and Windows-1252.
- Every `movie` and `episode` row is **one viewing**: a movie watched twice gets two rows. A row without a date (or
  with a future date) gives a viewing without a date. A `series` row adds the series to the library with its rating
  and comment, without a viewing.
- Rating and comment belong to the title, whichever row they are in.
- Rows with an unknown type, without a title, or (`episode`) without season and episode number are skipped. The upload
  message says how many. Files can be up to 5 MB.
- Matching: with `tmdb_id` or `imdb_id` the title is taken directly, as long as its title or year (±1) matches the
  file; otherwise it goes to **Zu prüfen** (to review). Without an id, title and year are searched as for Netflix.
  Unclear titles can be picked from suggestions there, searched with other words or skipped. Episodes TMDB does not
  list are counted per series („… Episoden nicht gefunden“, episodes not found).
- Importing the same file again does not create duplicate viewings (same movie or episode within ±1 day, or any viewing
  for an undated row). A new upload replaces the list on the page, but viewings already created stay.

### Converting exports

- **Letterboxd** (`diary.csv`): rename `Name` → `title`, `Year` → `year`, `Watched Date` → `watched_on`,
  multiply `Rating` by 2 → `rating`, and add a column `type` with `movie` in every row.
- **IMDb** (ratings export): rename `Const` → `imdb_id`, `Your Rating` → `rating`, `Title` → `title`, `Year` → `year`,
  and set `type` from `Title Type` (`Movie` → `movie`, `TV Series`/`TV Mini Series` → `series`). For movies,
  `Date Rated` → `watched_on` if the rating date should count as the viewing date.
- **Trakt, TV Time, Simkl**: these usually export ids. Fill in `tmdb_id` (or `imdb_id`), `season`, `episode` and the
  date, and put one row per watched episode.

Matching needs your [TMDB token](tmdb.md).

## Importing again

Importing the same (or a newer) export again does not create duplicates. A file saved again in (German) Excel, with
`;` as separator and dates as `DD.MM.YYYY`, is recognised as well.
