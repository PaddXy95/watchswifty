# App API

WatchSwifty has a JSON API for apps under `/api/v1`, used for example by
[WatchSwifty for iOS](https://github.com/PaddXy95/watchswifty-ios). The full OpenAPI description is at
`http://<server>:8080/api/openapi.yaml` (source: [`openapi.yaml`](../Sources/WatchSwiftyAPI/openapi.yaml)), a page to
read and try it out at `http://<server>:8080/api`.

## Connecting an app

Apps sign in with the Authorization Code flow and PKCE; the app never sees the password.

1. The app opens in the system browser window
   `/api/auth/authorize?redirect_uri=dev.patmei.watchswifty:/auth&state=…&code_challenge=…&code_challenge_method=S256&device_name=…`.
2. After signing in and „Verbinden“ (connect), the browser jumps to `dev.patmei.watchswifty:/auth?code=…&state=…`.
3. The app exchanges the code for a device token with `POST /api/v1/auth/token`.

Calls then send the header `Authorization: Bearer ws_…`. Tokens are valid for 90 days; after that the app connects
again. The API does not accept session cookies. Errors come as `{"code": …, "message": …}`.

## Managing devices

Under **Konto → Geräte** (account → devices) users sign out apps or create a token for scripts or the API page (it is
shown only once). The API page does not remember a pasted token, so paste it again after reloading.

Every newly connected app triggers a notice with the device name, the time and a link to sign it out. It goes out
through the user's [notification](notifications.md) channel: by [mail](email.md) when mail is set up and the user has an
address under **Konto**, or through the KNot webhook when they chose it.

## Scope

Everything the web UI can do: continue watching and notices, search, series and movies (mark as watched, rate,
comment, follow, hide; with their genres), history, library (filterable by `genre`), statistics (including genres and the longest and most watched titles), account and devices, Netflix import and film list, and for admins
user management and system settings. Details and "Try it out" at `/api`.

## Swift client

The Swift package also offers the library `WatchSwiftyClient`, generated from the same OpenAPI description as the
server. Values that may grow with new versions (streaming services, genres, import and matching states, device kind) are open
there, so older apps keep understanding newer servers.
