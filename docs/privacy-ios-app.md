# Privacy policy – WatchSwifty for iOS

Last updated: 11 November 2026 · [Deutsche Fassung](datenschutz-ios-app.md)

WatchSwifty for iOS is the app for a **self-hosted** WatchSwifty server. It has no service of its own in the background
and no operator who collects data.

## What data the app processes
- **Your own server:** The app talks only to the server address you enter on the first start. All content goes there
  (viewings, ratings, comments, imports, account settings). Whoever runs the server is responsible for this data.
- **TMDB images:** Posters are loaded directly from `image.tmdb.org` (The Movie Database). As with any image request,
  TMDB sees your IP address; no account or usage data is transmitted.
- **On the device:** The server address and the device name are kept in the app settings, the sign-in token (device
  token) in this device's keychain (not in iCloud). A copy of the start page is kept in the cache so it appears
  immediately when the app opens.
  - **Signing out** revokes the token on the server and deletes it together with the copy of the start page; the server
    address stays until you tap „Anderen Server wählen“ (choose another server).
  - **Deleting the app** removes settings and cache. The token stays in the keychain until the app is installed again
    (it is then deleted on the first start); on the server it expires after 90 days and can be signed out at any time
    under **Konto → Geräte** (account → devices).
- **Sign-in:** It runs in your server's browser window. The app does not see your password.

## What the app does not do
No advertising, no tracking, no third-party analytics or crash reporting services, no sharing of data.

## Contact
Questions about the app: through the project's issues on GitHub (`PaddXy95/watchswifty`). Questions about the data on
a server: to the person who runs that server.
