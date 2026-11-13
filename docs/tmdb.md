# TMDB

Movie and series data come from [TMDB](https://www.themoviedb.org). This product uses the TMDB API but is not endorsed
or certified by TMDB.

## Getting a token

Every user stores their own free TMDB *Read Access Token* under **Konto** (account):

1. Create a free account at https://www.themoviedb.org/signup and confirm your e-mail address.
2. Signed in, go to **Settings → API**: https://www.themoviedb.org/settings/api
3. Request an API key (personal, non-commercial use), accept the terms and fill in the form.
4. Copy the long **API Read Access Token** (starts with `eyJ`), **not** the short "API Key".
5. Paste it in WatchSwifty under **Konto** and save.

Without a token, search and Netflix matching do not work; titles already known, „Weiterschauen“ (continue watching),
history and library still do. WatchSwifty checks the token with TMDB when you save it, stores it encrypted (see
[Encryption key](configuration.md#encryption-key)) and afterwards only shows its last four characters. Admins cannot
see it either.

All users share one rate limit towards TMDB.

## Cached data

WatchSwifty keeps a local copy of the titles and episodes its users track. Following the TMDB terms:

- cached titles are fetched again after 60 days at the latest, with the token of a user who uses the title;
- titles nobody uses any more are deleted;
- TMDB texts (synopsis, runtimes, genres) are removed after 180 days without a refresh.

The language of the TMDB data is set with `TMDB_LANGUAGE` (default `de-DE`), see [Configuration](configuration.md).
