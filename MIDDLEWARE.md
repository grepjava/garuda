# Middleware

Middleware is code that runs for many routes: it refuses requests, adds
headers, loads a session, or times what happened. This page covers how it
works in Garuda, every piece Garuda ships, and how to write your own.

- [How middleware runs](#how-middleware-runs)
- [Order within a scope](#order-within-a-scope)
- [What Garuda ships](#what-garuda-ships)
- [Server flags that act as middleware](#server-flags-that-act-as-middleware)
- [Writing your own](#writing-your-own)

## How middleware runs

`app.use` adds middleware to the current scope: the whole application, or the
group or router it is called in.

```swift
app.use { request, response in
    guard request.header("x-api-key") == expectedKey else { return HTTPStatus.unauthorized }
    return nil
}

app.group("/admin") {
    app.use { request, response async throws -> (any ResponseConvertible)? in
        let allowed = try await audit.check(request.path)
        return allowed ? nil : HTTPStatus.forbidden
    }
    app.get("/stats") { "stats" }
}
```

- A middleware returns `nil` to let the request through, or an answer (any
  `ResponseConvertible`) to answer in the handler's place. Throwing answers as
  a handler that throws does.
- Middleware runs from the outside in: application first, then each group.
  Within a scope, `use` calls run in the order they were made. Where the routes
  are registered does not matter: a `use` after them still covers them.
- A closure that awaits is async middleware. The synchronous middleware before
  the first async one runs on the worker thread; the rest of the chain and the
  handler run on one of the worker's handler tasks.
- A route with no middleware pays nothing: the chain is assembled once, when
  the application compiles.

### Seeing the response: `onSend`

Middleware runs before the handler and cannot wrap it. To see or change the
answer, it registers a hook that runs just before the response head is written,
whoever answers: the handler, a later middleware, a thrown error, a deadline.

```swift
app.use { request, response in
    let started = Timestamp.now
    response.onSend { outgoing in
        let ms = (Timestamp.now.microsecondsSinceEpoch - started.microsecondsSinceEpoch) / 1000
        outgoing.addHeader("server-timing", "app;dur=\(ms)")
    }
    return nil
}
```

Hooks run once, the last registered first, so the middleware that ran first
sees the response last. A hook can read and change the status, headers and
body. Static files, `--cache-size` hits and answers given before a route is
chosen (a 404) do not run hooks.

### Seeing every request: `onResponse`

`app.onResponse` sees every request once it is answered, including 404s:

```swift
app.onResponse { done in
    metrics.record(route: done.route ?? "unmatched", status: done.status, micros: done.microseconds)
    if let failure = done.failure { AppLog.error("request failed", ["why": "\(failure)"]) }
}
```

`CompletedRequest` holds the method, path, matched route pattern, status,
duration, protocol, client address, request ID, trace IDs, and why a route
answered 5xx on its own account.

### Handing values to handlers

Middleware stores what it found in the request's context, and handlers ask for
it by key:

```swift
enum CurrentUser: RequestContextKey { typealias Value = User }

app.use { request, _ async throws -> (any ResponseConvertible)? in
    request[context: CurrentUser.self] = try await users.find(request)
    return nil
}
app.get("/me") { (user: Context<CurrentUser>) in JSON(user.value) }
```

An [async extractor](#extractors-instead-of-middleware) is often simpler, when
only some routes need the value.

## Order within a scope

Most shipped middleware is added with `use`, so order matters. A good order:

```swift
app.securityHeaders()                          // 1. first, so every refusal below carries them
app.allowedHosts(["example.com"])              // 2. cheap refusals
app.addressFilter(allow: ["10.0.0.0/8"])
app.csrfProtection()                           // 3. before any work for a forged request
app.requestDecompression()                     // 4. before anything reads the body
app.sessions(store: sessionStore)              // 5. state for the handlers
app.authenticate(bearer: CurrentUser.self) { token in try await users.find(token) }
```

A few pieces are not in that order, because they belong to a scope rather than
a position:

- **`app.cors`** runs in front of all of a scope's middleware. A browser's
  preflight carries no credentials and must not meet authentication, and a
  401 needs CORS headers for the page to read it.
- **`app.deadline`, `app.maxBodySize` and `app.concurrencyLimit`** wrap the
  routes registered inside their closure.
- **`app.trailingSlash`** is set once for the application, because it runs
  before a route is chosen.

## What Garuda ships

| Middleware | What it does | Answers with |
|---|---|---|
| [`app.cors`](#cors) | Cross-origin resource sharing, preflights included | 204 to a preflight |
| [`app.authenticate`](#authentication) | Bearer tokens and Basic credentials | 401 with a challenge |
| [`JWT<Claims>`, `authenticate(jwt:)`](#json-web-tokens) | Signed tokens checked without a lookup | 401 with `error="invalid_token"` |
| [`app.sessions`](#sessions) | Server-side sessions in memory, Redis or SQLite | 500 if the store fails |
| [`app.csrfProtection`](#csrf-protection) | Refuses cross-site request forgery | 403 |
| [`app.securityHeaders`](#security-headers) | nosniff, framing, referrer, cross-origin policies, HSTS | nothing refused |
| [`app.allowedHosts`](#allowed-hosts) | Only the Host names you serve | 400 |
| [`app.addressFilter`](#address-filter) | Allow or deny client addresses and networks | 403 |
| [`app.requestDecompression`](#request-decompression) | Decodes gzip, deflate, br and zstd bodies | 400, 413, 415 |
| [`app.maxBodySize`](#request-limits) | A body limit for some routes | 413 |
| [`app.concurrencyLimit`](#request-limits) | A cap on handlers running at once | 503 |
| [`app.deadline`](#deadlines) | A time limit on waiting | 504 |
| [`app.trailingSlash`](#trailing-slashes) | `/users/` for a route `/users` | 308, or served |
| [`request.log`](#logging) | Log lines carrying the request's IDs | |
| [Cookies](#cookies) | Reading, setting, signing and encrypting cookies | |

### CORS

```swift
app.group("/api") {
    app.cors(CORSPolicy(origins: .list(["https://app.example.com"]), allowCredentials: true))
    app.get("/me") { … }
}
```

`origins` is `.any`, `.list([...])` or `.matching { origin in … }`. `methods`
defaults to the methods the path is routed for and `headers` to what the
preflight asks for; `exposedHeaders`,
`allowCredentials` and `maxAge` (600 seconds) are there to set. A preflight is
answered 204 even when the path has no OPTIONS route. A request from an origin
the policy does not allow is served without the headers, and the browser keeps
the answer from the page. One policy per scope; the innermost wins.

### Authentication

```swift
enum CurrentUser: RequestContextKey { typealias Value = User }

app.group("/account") {
    app.authenticate(bearer: CurrentUser.self, state: SQLiteDatabase.self) { token, db in
        try await db.first(User.self, "select … where token_digest = ?", Tokens.digest(token))
    }
    app.get("/me") { (user: Context<CurrentUser>) in JSON(user.value) }
}
```

- `authenticate(bearer:)` and `authenticate(basic:realm:)` read the
  Authorization header and hand the token or the user name and password to
  your closure, sync or async. The `state:` variants also pass what
  `app.state` built.
- The closure returns who the credentials belong to, kept under the key, or
  nil for a 401 with the `WWW-Authenticate` challenge RFC 9110 requires.
- `BearerToken` and `BasicCredentials` are the same parsing as extractors.
- `constantTimeEquals` compares secrets without leaking timing.
- `Passwords.hash` and `Passwords.verify` store passwords as PBKDF2-SHA256 on
  the blocking pool; `Tokens.random` and `Tokens.digest` make session tokens
  worth storing only as digests.

### JSON Web Tokens

```swift
struct UserClaims: Codable, Sendable {
    let sub: String
    let exp: Int
    let role: String
}

let keys = try JWTKeys([.pem(privateKeyPEM, algorithm: .ES256, keyID: "2026")],
                       validation: JWTValidation(issuer: "https://auth.example.com", audience: "shop"))
app.jwtVerifier { _ in keys }

app.post("/token") { (login: Body<Login>) async throws -> JSON<[String: String]> in
    let user = try await users.check(login.value)
    let token = try keys.sign(UserClaims(sub: "\(user.id)", exp: Int(Timestamp.now.secondsSinceEpoch) + 900, role: user.role))
    return JSON(["access_token": token, "token_type": "Bearer"])
}
app.get("/me") { (jwt: JWT<UserClaims>) async in "user \(jwt.claims.sub)" }
app.group("/admin") {
    app.authenticate(jwt: UserClaims.self, verifier: keys)
    app.get("/stats") { (jwt: JWT<UserClaims>) async in "stats for \(jwt.claims.sub)" }
}
app.get("/.well-known/jwks.json") { JSON(keys.publicJWKS) }
```

- **Algorithms:** HS256/384/512, RS256/384/512, PS256/384/512, ES256/384/512
  and EdDSA (Ed25519). Keys come from `JWTKey.hmac`, `.pem` (public key,
  certificate or private key), `.jwk`, or `.generate`.
- **Checks:** the signature; `exp` and `nbf` with `leewaySeconds` (60); and
  `iss` and `aud` when the validation names them. A token without `exp` is
  refused unless `requireExpiration` is off.
- **Refused outright:** `alg: none`, a `crit` header, tokens over 16 KiB, RSA
  keys under 2048 bits, and HMAC secrets shorter than the hash.
- **Keys are bound to one algorithm.** A token is checked only with a key of
  its `alg`, chosen by `kid` or as the only key of that algorithm. That rules
  out signing with HS256 and an RSA public key as the secret.
- **Failures are all a 401** with `WWW-Authenticate: Bearer error="invalid_token"`
  and the same body, so a client learns nothing about which check failed.
- `JWT<Claims>` verifies on its own with what `app.jwtVerifier` registered, or
  uses the token `authenticate(jwt:)` already verified.
- `keys.publicJWKS` is the public half of every asymmetric key, to publish for
  other services. HMAC secrets are never included.

#### Refresh tokens

```swift
struct RefreshRequest: Decodable { let refresh_token: String }

app.state { _ in
    let db = try SQLiteDatabase(SQLiteConfiguration(path: "auth.db"))
    return TokenIssuer(keys: keys, store: SQLiteRefreshTokenStore(db)) { subject, lifetime in
        UserClaims(sub: subject, exp: lifetime.expiresAt, role: try await users.role(of: subject))
    }
}
app.post("/login") { (login: Body<Login>, issuer: State<TokenIssuer<UserClaims>>) async throws in
    JSON(try await issuer.value.issue(subject: try await users.check(login.value)))
}
app.post("/token/refresh") { (body: Body<RefreshRequest>, issuer: State<TokenIssuer<UserClaims>>) async throws in
    JSON(try await issuer.value.refresh(body.value.refresh_token))
}
app.post("/logout") { (body: Body<RefreshRequest>, issuer: State<TokenIssuer<UserClaims>>) async throws -> HTTPStatus in
    try await issuer.value.revoke(body.value.refresh_token)
    return .noContent
}
```

- `issue` answers a login with a `TokenPair`, which encodes as an OAuth 2.0
  token response: `access_token`, `token_type`, `expires_in`, `refresh_token`,
  `refresh_expires_in`.
- The access token is a JWT lasting `accessTokenSeconds` (15 minutes), and its
  claims come from your closure at login and at every refresh. A role taken
  away is gone within one access token's life.
- The refresh token is 32 random bytes, stored only as its SHA-256. Every
  refresh spends it and returns a new pair in the same **family**, the chain
  that began at one login.
- **Reuse is theft.** A spent token presented again revokes its whole family,
  so both the thief and the client must sign in again. Within
  `reuseGraceSeconds` (10) it is refused without revoking anything, so two
  browser tabs refreshing at once do not sign the user out.
- A refresh token unused for `refreshTokenSeconds` (14 days) expires. A family
  ends `maximumSessionSeconds` (90 days) after the login however often it is
  refreshed.
- `revoke(token)` ends one family, as a logout does, and is safe to repeat.
  `revokeAll(subject:)` ends every family of a user, after a password change
  for example.
- A refused refresh is 400 `{"error":"invalid_grant"}` whatever the reason.
- **Stores:** `MemoryRefreshTokenStore` for `--workers 1` and tests,
  `RedisRefreshTokenStore`, and `PostgresRefreshTokenStore` and
  `SQLiteRefreshTokenStore` (`createTables()` or `schema()`, and
  `deleteExpired()` now and then). Spending a token is atomic in each, so two
  workers refreshing one token at once cannot both succeed.

#### Tokens from an identity provider

```swift
app.jwtVerifier { _ in
    JWKSVerifier(url: "https://auth.example.com/.well-known/jwks.json",
                 validation: JWTValidation(issuer: "https://auth.example.com/", audience: "shop"))
}
app.get("/me") { (jwt: JWT<UserClaims>) async in jwt.claims.sub }
```

- `JWKSVerifier` fetches the provider's JWK Set on the first token, keeps it
  for `maxAgeSeconds` (an hour), then fetches it again.
- A token naming a `kid` the set lacks triggers a fetch, since that is how a
  key rotation shows.
- It never fetches more than once per `minimumRefetchSeconds` (a minute), so
  made-up key IDs or a provider outage cannot turn into a flood of requests.
- Requests that arrive during a fetch wait for it. If a fetch fails, the keys
  already in hand keep working; with none yet, the answer is 503.
- Only asymmetric algorithms are trusted: `oct` keys and `use: enc` keys are
  ignored, and `algorithms` narrows the list further. An RSA key without `alg`
  counts as RS256.
- Checked against Google's and Microsoft's published sets.

### Sessions

```swift
app.sessions { request in RedisSessionStore(try request.state(RedisPool.self)) }

app.post("/login") { (session: Session, login: Body<Login>) async throws -> HTTPStatus in
    let user = try await users.check(login.value)
    try await session.renew()               // a new ID at login
    try await session.set("user", "\(user.id)")
    return .noContent
}
app.get("/me") { (session: Session) in session["user"] ?? "nobody" }
app.post("/logout") { (session: Session) async throws -> HTTPStatus in
    try await session.destroy()
    return .noContent
}
```

- A request whose cookie names a live session has it loaded before the handler
  runs, and its idle timeout starts again. A request without one costs the
  store nothing.
- **Changes are written when made.** `set`, `set(_:json:)`, `update { … }`,
  `renew` and `destroy` return once the store holds the change, so the next
  request sees it. Use `update` for several keys in one write.
- **Change the session before answering.** The cookie for a new ID is added
  as the response is sent.
- The ID is 32 random bytes and is never taken from the client. `renew()` moves
  the data to a new ID; call it at login.
- `SessionConfiguration(cookieName:idleTimeoutSeconds:)` sets the cookie (`id`,
  `Path=/`, `HttpOnly`, `SameSite=Lax`, `Secure` over HTTPS) and the timeout (a
  day). Give `cookie.maxAge` to keep the cookie past the browser session.

| Store | Use it for | Notes |
|---|---|---|
| `MemorySessionStore()` | `--workers 1`, tests | Each worker process has its own memory |
| `RedisSessionStore(pool, prefix:)` | Several workers or servers | JSON with a PX expiry; needs Redis 6.2+ or Valkey for GETEX |
| `SQLiteSessionStore(db, table:)` | One machine, several workers | `createTable()` or `schema(table:)` in a migration; `deleteExpired()` now and then |

A store of your own implements `SessionStore`: `load`, `save` and `delete`.

### CSRF protection

```swift
app.csrfProtection(trustedOrigins: ["https://admin.example.com"])
```

A request other than GET, HEAD or OPTIONS is refused with 403 when the browser
says another site's page started it:

- `Sec-Fetch-Site: cross-site` or `same-site`.
- Without `Sec-Fetch-Site`, an `Origin` naming a host other than the request's
  Host, or `null`.

`same-origin`, `none`, and requests with neither header (not made by a browser
page) pass. An origin in `trustedOrigins` always passes; list any origin your
CORS policy lets send credentials. No tokens in forms are needed. Keep GET
requests free of side effects: they are not checked.

### Security headers

```swift
var headers = SecurityHeaders()
headers.contentSecurityPolicy = "default-src 'self'"
app.securityHeaders(headers)
```

| Header | Default |
|---|---|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains`, over HTTPS only |
| `X-Content-Type-Options` | `nosniff` |
| `X-Frame-Options` | `SAMEORIGIN` |
| `Referrer-Policy` | `no-referrer` |
| `Cross-Origin-Opener-Policy` | `same-origin` |
| `Cross-Origin-Resource-Policy` | `same-origin` |
| `Content-Security-Policy` | not sent unless set |
| `Permissions-Policy` | not sent unless set |

Set a field to nil to leave that header out. A header the response already has
is kept, so a route can set its own. Headers go on every answer after the
middleware ran, errors and refusals included, which is why it goes first.

### Allowed hosts

```swift
app.allowedHosts(["example.com", "*.example.com", "[::1]"])
```

A request whose Host (`:authority` on HTTP/2 and HTTP/3) is not listed, or that
has none, is answered 400. The port is not compared. `*.example.com` covers
names under the domain, not `example.com` itself. This stops a name an
attacker points at your server from ending up in absolute links, password-reset
mails and cache keys.

### Address filter

```swift
app.group("/admin") {
    app.addressFilter(allow: ["10.0.0.0/8", "fd00::/8"], deny: ["10.0.9.0/24"])
}
```

A client on `deny`, or not on a non-empty `allow`, is answered 403. Deny is read
first. Entries are addresses, CIDR blocks, `unix` and `*`. The address is
`request.remoteAddress`: behind a proxy, set `--forwarded-allow-ips` so the
forwarded address is used, and only then. An IPv4 client on an IPv6 socket
(`::ffff:a.b.c.d`) matches as IPv4.

### Request decompression

```swift
app.group("/ingest") {
    app.requestDecompression()
    app.post("/events") { (events: Body<[Event]>) in … }
}
```

A body with `Content-Encoding: gzip`, `deflate`, `br` or `zstd` (several stacked
too) is decoded before the handler and the middleware after it read it. The
decoded size is held to the route's body limit as it grows, so a small
compressed body that inflates to gigabytes stops with 413. Bytes that do not
decode are 400, and a coding the server cannot decode is 415 with
`Accept-Encoding`. A streaming route's body is left as it came. The
`Content-Encoding` header stays as it arrived.

### Request limits

```swift
app.maxBodySize(64 << 20) {
    app.post("/uploads") { … }
}
app.concurrencyLimit(8) {
    app.post("/reports") { … }
}
```

- **`maxBodySize(bytes)`** replaces `--max-body` for the routes inside, larger
  or smaller. A declared length past it is 413 before the body is read.
- **`concurrencyLimit(max)`** lets `max` of those handlers run at once in each
  worker process and answers the next one 503. With four workers, up to
  `4 × max` run in total. Middleware is not counted, and a request that goes
  away gives its place back.

Both nest, and both work on a `Router`.

### Deadlines

```swift
app.deadline(milliseconds: 2_000) {
    app.get("/search") { … }
}
```

A request still unanswered when its deadline passes is answered 504, and a
handler waiting on the engine for it is unwound. A deadline limits waiting, not
computing: nothing interrupts a loop that never awaits.

### Trailing slashes

```swift
app.trailingSlash(.redirect)    // or .ignore; .strict is the default
```

When no route matches a path ending in `/` but one matches it without, the
request gets a 308 to that path (`.redirect`, query kept) or is served by that
route (`.ignore`). A path that matched as it came is never changed. Set once
for the application.

### Logging

```swift
app.post("/orders") { request, response in
    request.log.info("order received", ["bytes": .int(request.body.count), "tenant": "acme"])
    response.send(status: .accepted)
}
AppLog.warning("cache cold", ["entries": 0])
```

`request.log` writes lines that carry the method, path, request ID and trace
IDs. `.with(["tenant": "acme"])` adds fields to every line after it. `AppLog`
writes the same format outside a request. `--log-format json` makes every line
a JSON object, and the access log follows unless `--access-log-format` says
otherwise.

### Cookies

```swift
let key = CookieKey(secret: secretBytes)        // 32 bytes or more; previous: [...] for rotation

app.get("/theme") { request, response in
    response.setCookie(Cookie("theme", "dark"))
    response.setCookie(Cookie("cart", cartJSON), key: key, .encrypted)
    response.send(request.cookie("theme") ?? "light")
}
```

- `request.cookie(name)`, `request.cookies` and the `Cookies` extractor read
  cookies.
- `Cookie` defaults to `Path=/`, `HttpOnly`, `SameSite=Lax`, and `Secure` when
  the request came over HTTPS.
- `.signed` uses HMAC-SHA256 and `.encrypted` uses AES-256-GCM, both bound to
  the cookie's name. `request.cookie(name, key: key, .signed)` returns nil for
  a cookie that was tampered with.
- `response.removeCookie(name)` expires one.

## Server flags that act as middleware

These run in the engine, for every route, and are set on the command line
([CONFIG.md](CONFIG.md)):

| Flag | What it does |
|---|---|
| `--compress` | Compresses handler responses with brotli, zstd or gzip, as the client accepts |
| `--rate-limit N/s` | 429 past a request rate per client address |
| `--request-id` | Gives every request an `X-Request-ID`, kept from a trusted proxy |
| `--trace-context` | Records a W3C `traceparent` in the access log and `request.log` |
| `--access-log` | One line per request, text or JSON |
| `--max-body BYTES` | The default body limit, 413 past it |
| `--cache-size MIB` | A response cache shared by every worker |
| `--static-dir P=DIR`, `--spa-fallback P=FILE` | Files from disk, and a single-page application's page for navigations nothing else answers |
| `--health-check-path P` | Answers health probes without touching a route |
| `--metrics-port PORT` | Prometheus metrics on a port of their own, server-wide and by route pattern |
| `--forwarded-allow-ips LIST` | Which proxies' forwarded headers are believed |

## Writing your own

### A reusable middleware

Write it as an extension on `RouteBuilder`, so it works on an application, a
group and a `Router` alike:

```swift
extension RouteBuilder {
    /// Answers 503 to every request in scope while `flag` is on.
    func maintenanceMode(_ flag: @escaping () -> Bool) {
        use { _, response in
            guard flag() else { return nil }
            response.addHeader("retry-after", "120")
            return HTTPStatus.serviceUnavailable
        }
    }
}
```

Keep in mind:

- **Read the request before the first `await`.** The request is a view of a
  connection slot; after a wait the client may have gone.
- **Register `onSend` hooks before the first `await`** too, and keep them fast:
  they run on the worker thread for every response in scope.
- **Refuse with an answer, or throw a `ResponseError`** such as `HTTPError`,
  when the refusal is expected. Any other error is logged as a failure, shows
  in `onResponse`, and is answered 500.

### Extractors instead of middleware

When only some routes need a value, an extractor is often clearer than
middleware plus a context key. An `AsyncRequestExtractor` can await:

```swift
struct SignedInUser: AsyncRequestExtractor {
    let user: User

    static func extract(from request: borrowing Request, parameter: inout Int) async throws -> SignedInUser {
        guard let token = try? BearerToken.extract(from: request, parameter: &parameter) else {
            throw HTTPError.unauthorized
        }
        let db = try request.state(SQLiteDatabase.self)
        guard let user = try await findUser(token: token.token, db) else { throw HTTPError.unauthorized }
        return SignedInUser(user: user)
    }
}

app.get("/me") { (me: SignedInUser) async in JSON(me.user) }
app.get("/hello") { (me: SignedInUser?) async in "hello \(me?.user.username ?? "stranger")" }
```

`E?` is nil where `E` would refuse, and `Result<E, any Error>` hands the
refusal to the handler. A synchronous handler that takes an async extractor
stops the program when the route is registered.
