# Middleware

Middleware is code that runs around many routes: it refuses requests, adds
headers, loads a session, or times what happened. This page covers how it
works in Garuda, every piece Garuda ships, and how to write your own.

- [How middleware runs](#how-middleware-runs)
- [Order within a scope](#order-within-a-scope)
- [What Garuda ships](#what-garuda-ships)
- [Server flags that act as middleware](#server-flags-that-act-as-middleware)
- [Writing your own](#writing-your-own)

## How middleware runs

`app.use` adds middleware to the current scope: the whole application, or the
group or router it is called in. A middleware is a closure, or a type
conforming to `Middleware`, that gets the request, the response and `next`,
the rest of the chain:

```swift
app.use { request, response, next in
    guard request.header("x-api-key") == expectedKey else {
        return response.send(status: .unauthorized)
    }
    try await next()
}

app.group("/admin") {
    app.use { request, response, next in
        let started = Timestamp.now
        try await next()
        let ms = (Timestamp.now.microsecondsSinceEpoch - started.microsecondsSinceEpoch) / 1000
        response.addHeader("server-timing", "app;dur=\(ms)")
    }
    app.get("/stats") { () in "stats" }
}
```

- A middleware calls `next` at most once to run the layers inside it and the
  handler. To answer in the handler's place, it sends a response and returns
  without calling `next`, or throws: a thrown error is answered as it would be
  from a handler.
- After `next` returns, the middleware can still change the status and add
  headers: the response is written once the handler and every layer around
  it have returned (unless the handler streamed it with `response.stream()`).
  It can also catch what the handler threw, with `do`/`catch` around `next`.
- Middleware runs from the outside in: application first, then each group,
  and comes back out in the opposite order. Within a scope, `use` calls run in
  the order they were made. Where the routes are registered does not matter:
  a `use` after them still covers them.
- Middleware runs for requests that match a route, and in front of a scope's
  `fallback`. A request no route answers (a 404, a 405) does not run it.
- A route with no middleware pays nothing: each route's chain is put together
  once, when the application compiles, and costs one call per layer.

The same thing as a type, for middleware you reuse or test on its own:

```swift
struct RequireToken: Middleware {
    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        guard request.header("authorization") == "Bearer good" else {
            return response.send(status: .unauthorized, "no")
        }
        try await next()
    }
}

app.use(RequireToken())
```

### Seeing the final response: `onSend`

Some answers are made after every layer has unwound: the 500 for an error
that is not a `ResponseError`, or for a handler that never answered. To see
those as well, a middleware registers a hook that runs just before the
response head is written, whoever answered: the handler, a middleware, a
thrown error, a deadline.

```swift
app.use { request, response, next in
    response.onSend { outgoing in
        if outgoing.status.code >= 500 {
            outgoing.replaceBody(#"{"error":"internal"}"#, contentType: "application/json")
        }
        outgoing.setHeader("cache-control", "no-store")
    }
    try await next()
}
```

Hooks run once, the last registered first, so the middleware that ran first
sees the response last. A hook can read and change the status, read, add,
replace and remove headers, and read or replace the body. A hook added after
the head is written never runs. Static files, `--cache-size` hits and answers
given before a route is chosen (a 404, a 405) do not run hooks.

### Seeing every request: `onResponse`

`app.onResponse` sees every request once it is answered, including 404s,
405s and requests refused before they were routed:

```swift
app.onResponse { done in
    metrics.record(route: done.route ?? "unmatched", status: done.status, micros: done.microseconds)
    if let failure = done.failure { AppLog.error("request failed", ["why": "\(failure)"]) }
}
```

`CompletedRequest` holds the method, path, matched route pattern, status,
duration in microseconds, protocol, client address, request ID, trace and
parent IDs, and why a route answered 5xx on its own account. Observers run in
the connection's task, in the order added, before it reads the next request,
so keep them quick.

### Handing values to handlers

Middleware stores what it found in the request's context, and handlers ask for
it by key:

```swift
enum CurrentUser: RequestContextKey { typealias Value = User }

app.use { request, response, next in
    request[context: CurrentUser.self] = try await users.find(request)
    try await next()
}
app.get("/me") { (user: Context<CurrentUser>) in JSON(user.value) }
```

A route that takes `Context<Key>` when nothing stored a value under the key is
answered 500: the middleware that should have run did not. An
[extractor](#extractors-instead-of-middleware) is often simpler, when only
some routes need the value.

## Order within a scope

Most shipped middleware is added with `use`, so order matters. A good order:

```swift
app.securityHeaders()                          // 1. outermost, so every refusal below carries them
app.allowedHosts(["example.com"])              // 2. cheap refusals
app.addressFilter(allow: ["10.0.0.0/8"])
app.csrfProtection()                           // 3. before any work for a forged request
app.requestDecompression()                     // 4. before anything reads the body
app.sessions(store: sessionStore)              // 5. state for the handlers
app.authenticate(bearer: CurrentUser.self) { token in try await users.find(token) }
```

A few pieces are not in that order, because they belong to a scope rather than
a position:

- **`app.cors`** runs in front of all of a scope's middleware, wherever it is
  called. A browser's preflight carries no credentials and must not meet
  authentication, and a 401 needs CORS headers for the page to read it.
- **`app.deadline`, `app.maxBodySize` and `app.concurrencyLimit`** apply to
  the routes registered inside their closure. A deadline is a layer inside the
  surrounding scope's middleware, a concurrency limit wraps the handler inside
  every layer, and a body limit is applied as the body is read.
- **`app.trailingSlash`** is set once for the application, because it acts
  before a route is chosen.

## What Garuda ships

| Middleware | What it does | Answers with |
|---|---|---|
| [`app.cors`](#cors) | Cross-origin resource sharing, preflights included | 204 to a preflight |
| [`app.authenticate`](#authentication) | Bearer tokens and Basic credentials | 401 with a challenge |
| [`app.authorize`](#authorization) | A named rule about who may reach a scope | 403 saying what it needs |
| [`JWT<Claims>`, `authenticate(jwt:)`](#json-web-tokens) | Signed tokens checked without a lookup | 401 with `error="invalid_token"` |
| [`app.sessions`](#sessions) | Server-side sessions in memory, Redis or SQLite | 409 for a session another request ended, 500 if the store fails |
| [`app.csrfProtection`](#csrf-protection) | Refuses cross-site request forgery | 403 |
| [`app.securityHeaders`](#security-headers) | nosniff, framing, referrer, cross-origin policies, HSTS | nothing refused |
| [`app.allowedHosts`](#allowed-hosts) | Only the Host names you serve | 400 |
| [`app.addressFilter`](#address-filter) | Allow or deny client addresses and networks | 403 |
| [`app.requestDecompression`](#request-decompression) | Decodes gzip, deflate, br and zstd bodies | 400, 413, 415 |
| [`app.maxBodySize`](#request-limits) | A body limit for some routes | 413 |
| [`app.concurrencyLimit`](#request-limits) | A cap on handlers running at once | 503 |
| [`app.deadline`](#deadlines) | A time limit on I/O waits | 504 |
| [`app.trailingSlash`](#trailing-slashes) | `/users/` for a route `/users` | 308, or served |
| [`request.log`](#logging) | Log lines carrying the request's IDs | |
| [Cookies](#cookies) | Reading, setting, signing and encrypting cookies | |

### Shards and shared state

Under `--shards`, each shard is a process of its own, so what a middleware
keeps in memory belongs to one shard: a `MemorySessionStore`, a
`MemoryRefreshTokenStore`, a `JWKSVerifier`'s keys, and the count of
`concurrencyLimit`. The server logs a warning at start-up when either memory
store is used with more than one shard. What the server keeps for
`--rate-limit`, `--metrics-port`, `--cache-size` and `--broadcast-size` lives
in memory every shard shares, so a client's allowance, the counters and the
cache are the server's, not one shard's.

### CORS

```swift
app.group("/api") {
    app.cors(CORSPolicy(origins: ["https://app.example.com"], allowCredentials: true))
    app.get("/me") { … }
}
```

`origins` is a list of origins, or `.any`, `.list([...])` or
`.matching { origin in … }`; `.any` with `allowCredentials` stops the program.
`methods` defaults to the methods the path is routed for and `headers` to what
the preflight asks for; `exposedHeaders`, `allowCredentials` and `maxAge`
(600 seconds) are there to set. A preflight is answered 204 even when the path
has no OPTIONS route. A request from an origin the policy does not allow is
served without the headers, and the browser keeps the answer from the page.
One policy per scope; the innermost wins.

### Authentication

```swift
import GarudaSQLite

enum CurrentUser: RequestContextKey { typealias Value = User }

app.group("/account") {
    app.authenticate(bearer: CurrentUser.self, state: SQLiteDatabase.self) { token, db in
        try await db.first(User.self, "select … where token_digest = ?", Tokens.digest(token))
    }
    app.get("/me") { (user: Context<CurrentUser>) in JSON(user.value) }
}
```

- `authenticate(bearer:)` and `authenticate(basic:realm:)` read the
  Authorization header and hand the token, or the user name and password, to
  your closure, which may await. The `state:` variants also pass what
  `app.state` built in the shard.
- The closure returns who the credentials belong to, kept under the key, or
  nil for a 401 with the `WWW-Authenticate` challenge RFC 9110 requires.
- `BearerToken` and `BasicCredentials` are the same parsing as extractors.
- `constantTimeEquals` compares secrets without leaking timing.
- `Passwords.hash` and `Passwords.verify(_:against:)` store passwords as
  PBKDF2-SHA256 (600,000 iterations) on Vega's blocking pool, and
  `Passwords.needsRehash` says when a stored hash is due for more.
  `Tokens.random` and `Tokens.digest` make session tokens worth storing only
  as digests.

### Authorization

Authentication says who is asking. A `Policy` says whether they may, named
once and used wherever it applies:

```swift
extension Policy where Value == User {
    static let admin = Policy(needs: "an administrator") { $0.role == .admin }
    static let billing = Policy(needs: "the billing role") { $0.roles.contains("billing") }
}

app.group("/invoices") {
    app.authenticate(bearer: CurrentUser.self, state: SQLiteDatabase.self) { token, db in … }
    app.authorize(CurrentUser.self, Policy.admin.or(.billing))
    app.get("/") { … }                      // and every other route in the group
}
```

- `authorize` runs in the order of `use`, so it goes after the `authenticate`
  that puts whoever is asking under the key.
- A rule that does not hold is 403 with what would have been enough:
  `{"error":"this route needs an administrator or the billing role"}`. A
  request with nobody under the key is 401, since signing in may be the
  answer.
- `and` and `or` combine rules and their names. `about` points a rule written
  about one type at part of another. A policy is a plain `(Value) -> Bool`,
  so a test can call it: `#expect(Policy.admin(user))`.
- `app.authorize(CurrentUser.self, needs: "a member") { … }` writes the rule
  where it is used, and an `async` closure may ask a database -- once per
  request in the scope, so keep it cheap.
- `app.authorize(jwt: AccessClaims.self, .scope("orders:write"))` reads the
  claims `authenticate(jwt:)` checked. Claims conforming to `ScopedClaims`
  get `hasScope` and `scopes` from the OAuth 2.0 `scope` claim, matched whole.
- A rule about one row -- whether this order is this customer's -- belongs in
  the handler, which has the row: `throw AuthorizationError(needs: "the
  customer")` answers the same way.
- Both `authenticate` and `authorize` say what they can answer in the OpenAPI
  document, for every route in their scope: the 401, the 403 and the security
  scheme. `app.describeRoutes { operation in … }` does the same for a
  middleware of your own, and leaves alone whatever a route said for itself.

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
    let exp = Int(Timestamp.now.secondsSinceEpoch) + 900
    let token = try keys.sign(UserClaims(sub: "\(user.id)", exp: exp, role: user.role))
    return JSON(["access_token": token, "token_type": "Bearer"])
}
app.get("/me") { (jwt: JWT<UserClaims>) in "user \(jwt.claims.sub)" }
app.group("/admin") {
    app.authenticate(jwt: UserClaims.self, verifier: keys)
    app.get("/stats") { (jwt: JWT<UserClaims>) in "stats for \(jwt.claims.sub)" }
}
app.get("/.well-known/jwks.json") { () in JSON(keys.publicJWKS) }
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
  its `alg`, chosen by `kid` or as the only key there is. That rules out
  signing with HS256 and an RSA public key as the secret. With more than one
  key in a `JWTKeys`, every key needs a `kid`.
- **Failures are all a 401** with `WWW-Authenticate: Bearer error="invalid_token"`,
  the same whichever check failed, so a client learns nothing about which.
- `JWT<Claims>` verifies on its own with what `app.jwtVerifier` registered, or
  uses the token `authenticate(jwt:)` already verified. A token is checked
  without suspending when the keys are in hand: always with `JWTKeys`, and
  with a `JWKSVerifier` once it has fetched them.
- `keys.publicJWKS` is the public half of every asymmetric key, to publish for
  other services. HMAC secrets are never included.

#### Refresh tokens

```swift
import GarudaSQLite

struct RefreshRequest: Decodable { let refresh_token: String }

app.state { _ in
    let db = try SQLiteDatabase(SQLiteConfiguration(path: "auth.db"))
    let store = SQLiteRefreshTokenStore(db)
    try await store.createTables()
    return TokenIssuer(keys: keys, store: store) { subject, lifetime in
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
- **Stores:** `MemoryRefreshTokenStore` keeps tokens in one shard's memory,
  for a server of one shard and for tests. It lets ended families go by itself
  (spent tokens of a live family are kept, since presenting one again is how
  theft is noticed; `count` says how many families and tokens it holds). For
  several shards, use `RedisRefreshTokenStore` (GarudaRedis),
  `PostgresRefreshTokenStore` (GarudaPostgres) or `SQLiteRefreshTokenStore`
  (GarudaSQLite); the SQL stores make their tables with `createTables()` or
  `schema()` and want `deleteExpired()` now and then. Spending a token is
  atomic in each, so two requests refreshing one token at once cannot both
  succeed.

#### Tokens from an identity provider

```swift
app.jwtVerifier { _ in
    JWKSVerifier(url: "https://auth.example.com/.well-known/jwks.json",
                 validation: JWTValidation(issuer: "https://auth.example.com/", audience: "shop"))
}
app.get("/me") { (jwt: JWT<UserClaims>) in jwt.claims.sub }
```

- `JWKSVerifier` fetches the provider's JWK Set on the first token, keeps it
  for `maxAgeSeconds` (an hour), then fetches it again. Each shard has its own
  verifier and its own copy of the keys.
- A token naming a `kid` the set lacks triggers a fetch, since that is how a
  key rotation shows.
- It never fetches more than once per `minimumRefetchSeconds` (a minute), so
  made-up key IDs or a provider outage cannot turn into a flood of requests.
- Requests that arrive during a fetch wait for it. If a fetch fails, the keys
  already in hand keep working; with none yet, the answer is 503.
- A set that arrives holding no key the verifier can use is an answer, not
  a failure: it is how a provider withdraws a compromised key. Keys older
  than `maxAgeSeconds` are dropped then, and keys still within it are kept
  until they reach it.
- Only asymmetric algorithms are trusted: `oct` keys and `use: enc` keys are
  ignored, and `algorithms` narrows the list further. An RSA key without `alg`
  counts as RS256.
- The fetch uses Garuda's HTTP client with a 10-second `timeout` and the
  system's trust store unless `caFile` names another, and takes a 200 of at
  most a megabyte. `fetch:` replaces it with a function of your own.

### Sessions

```swift
import GarudaRedis

app.state { _ in RedisPool(RedisConfiguration(host: "cache")) }
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
- **A session another request ended stays ended.** Two requests from one
  client each load their own copy. When one destroys or renews the session, a
  change or `renew` by the other throws 409 and empties its copy, rather than
  writing the old ID back as a live, signed-in session.
- `SessionConfiguration(cookieName:idleTimeoutSeconds:)` sets the cookie (`id`,
  `Path=/`, `HttpOnly`, `SameSite=Lax`, `Secure` over HTTPS) and the timeout (a
  day). Give `cookie.maxAge` to keep the cookie past the browser session.

| Store | Use it for | Notes |
|---|---|---|
| `MemorySessionStore()` | One shard, tests | Each shard process has its own memory; the server warns at start-up with more than one shard |
| `RedisSessionStore(redis, prefix:)` | Several shards or servers | GarudaRedis. JSON with a PX expiry; needs Redis 6.2+ or Valkey for GETEX |
| `SQLiteSessionStore(db, table:)` | One machine, several shards | GarudaSQLite. `createTable()` or `schema(table:)` in a migration; `deleteExpired()` now and then |

A store of your own implements `SessionStore`: `load`, `save` and `delete`,
and `replace` (store only if the session is live) and `remove` (delete and say
whether it was live). Those two have defaults that load first and then write,
which another request can come between; do each in one step, as the bundled
stores do.

### CSRF protection

```swift
app.csrfProtection(trustedOrigins: ["https://admin.example.com"])
```

A request other than GET, HEAD or OPTIONS is refused with 403 when the browser
says another site's page started it:

- `Sec-Fetch-Site: cross-site` or `same-site`.
- Without `Sec-Fetch-Site`, an `Origin` naming a host or port other than the
  request's Host, or `null`. A port is read against the origin's own scheme:
  `https://example.com:80` is not `example.com:443`.

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
is kept, so a route can set its own. The headers are added on the way out to
whatever the layers inside answered, errors and refusals included, which is
why this goes first.

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
`Accept-Encoding`. The `Content-Encoding` and `Content-Length` headers stay as
they arrived.

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
  or smaller; nested, the innermost applies. A declared length past it is 413
  before the body is read, and a chunked body is refused when it grows past it.
  An `onStreamingBody` route is the exception: its own `maxBodySize:`
  argument, `Int.max` when left out, takes the place of the scope's.
- **`concurrencyLimit(max)`** lets `max` of those handlers run at once in each
  shard and answers the next one 503 at once, without queueing it. With four
  shards, up to `4 × max` run in total. Middleware is not counted, so a
  request the scope's authentication refuses takes no place. A handler holds
  its place from when it starts until it returns or throws: a body it writes
  with `response.stream()` is counted, while a `StreamingBody` or
  `EventStream` it returns is written after it has given its place back.
  Nested limits all apply.

Both work on a `Router` too.

### Deadlines

```swift
app.deadline(.seconds(2)) {
    app.get("/search") { … }
}
```

The routes inside run under an I/O deadline: a socket, pipe or database wait
still pending when the time is up fails with `IOError.timedOut`, and so does
any that would start after it. If that error reaches the deadline's layer
before anything has answered, the request is answered 504. A deadline limits waiting on I/O, not computing:
nothing interrupts a loop that never awaits, and a `Runtime.sleep`, a channel
or a child task's wait is not cut short. Inside another `deadline`, the inner
one is in force.

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
IDs. `.with(["tenant": "acme"])` returns a logger that adds fields to every
line it writes. `AppLog` writes the same format outside a request.
`--log-format json` makes every line a JSON object, and the access log follows
unless `--access-log-format` says otherwise.

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
- `CookieKey(base64:previous:)` reads secrets stored as base64 text, and
  `CookieKey.randomSecret()` makes one.
- `response.removeCookie(name)` expires one.

## Server flags that act as middleware

These run in the server, for every request, and are set on the command line
([CONFIG.md](CONFIG.md)):

| Flag | What it does |
|---|---|
| `--compress` | Compresses text responses with gzip, br or zstd, as the client accepts |
| `--rate-limit N/s\|m\|h`, `--rate-limit-burst N` | 429 past a request rate per client address, counted across every shard |
| `--request-id` | Gives every request an `X-Request-ID`, echoed on the response and logged; one a trusted proxy sent is kept |
| `--trace-context` | Records a W3C `traceparent`'s trace and parent IDs in the logs and `onResponse` |
| `--access-log`, `--access-log-format F` | One line per request, text or JSON |
| `--max-body BYTES` | The default body limit (16 MiB), 413 past it |
| `--cache-size MIB` | A response cache in memory every shard shares |
| `--hsts SECS` | `Strict-Transport-Security: max-age=SECS` on every answer over TLS |
| `--static-dir PREFIX=DIR`, `--spa-fallback PREFIX=FILE` | Files from disk, and a single-page application's page for navigations nothing else answers |
| `--health-check-path P` | Answers GET P with 200 before routing and before `--rate-limit` |
| `--metrics-port PORT` | Prometheus metrics on a port of their own, summed over every shard |
| `--forwarded-allow-ips LIST` | Which proxies' forwarded headers are believed |

## Writing your own

### A reusable middleware

Write it as an extension on `RouteBuilder`, so it works on an application, a
group and a `Router` alike:

```swift
extension RouteBuilder {
    /// Answers 503 to every request in scope while `flag` is on.
    func maintenanceMode(_ flag: @escaping @Sendable () -> Bool) {
        use { _, response, next in
            guard !flag() else {
                response.addHeader("retry-after", "120")
                return response.send(status: .serviceUnavailable)
            }
            try await next()
        }
    }
}
```

Keep in mind:

- **The request and response are borrowed.** They cannot be captured by an
  `onSend` hook or a task; copy what you need out of them first, as a `String`
  or a value.
- **Keep `onSend` hooks fast.** They are synchronous and run for every
  response in scope, just before its head is written.
- **Refuse with an answer, or throw a `ResponseError`** such as `HTTPError`,
  when the refusal is expected. Any other error is logged as a failure, shows
  in `onResponse`, and is answered 500.

### Extractors instead of middleware

When only some routes need a value, an extractor is often clearer than
middleware plus a context key. Any `RequestExtractor` may await:

```swift
struct SignedInUser: RequestExtractor {
    let user: User

    static func extract(from request: borrowing Request, parameter: inout Int) async throws -> SignedInUser {
        let token = try await BearerToken.extract(from: request, parameter: &parameter)
        let db = try request.state(SQLiteDatabase.self)
        guard let user = try await findUser(token: token.token, db) else { throw HTTPError.unauthorized }
        return SignedInUser(user: user)
    }
}

app.get("/me") { (me: SignedInUser) in JSON(me.user) }
app.get("/hello") { (me: SignedInUser?) in "hello \(me?.user.username ?? "stranger")" }
```

`E?` is nil where `E` would refuse, and `Result<E, any Error>` hands the
refusal to the handler.
