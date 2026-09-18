<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Releases

**Garuda has not been released.** No tag or package has been published. The
tags `v1.0.0` to `v1.1.5` in this repository predate Garuda and do not describe
it.

**Keeping this file.** A change someone using Garuda would notice gets a line
under [Unreleased](#unreleased) in the commit that makes it. When a version is
cut, that section is renamed to the version and its date, and a new empty
Unreleased section goes above it.

**What CI runs.** `.github/workflows/ci.yml` runs on every push to `main` and
every pull request:

- the release build and `swift test` on Ubuntu 24.04 and macOS 15, and the
  handler code that must not compile;
- `swift test` again against a real PostgreSQL and a real Redis, which is what
  turns the opt-in connector suites on, and the example applications with
  them;
- the end-to-end suites, which drive the release binary over a socket.

The protocol suites -- HTTP/2, HTTP/3, WebSocket, WebTransport, uploads,
broadcast -- and a `pgfuzz` run under AddressSanitizer go on every push to
`main`, nightly and on demand, but not on a pull request: they are slow and
want a QUIC stack. The fuzzer runs for ten minutes on the nightly run and one
minute on the others.

**Before cutting a version.** Run the lot against the release build, including
what CI keeps off a pull request:

```bash
swift build -c release
swift test                             # 946 unit tests; GARUDA_REDIS and GARUDA_POSTGRES run the database ones
bash scripts/compile-fail-test.sh      # 6
bash scripts/integration-test.sh       # 36
bash scripts/static-test.sh            # 93
bash scripts/compress-test.sh          # 76, and garuda-conformance
bash scripts/cache-test.sh             # 85, runs garuda-conformance
bash scripts/ratelimit-test.sh         # 18
bash scripts/redirect-test.sh          # 22
bash scripts/sni-test.sh               # 11
bash scripts/acme-test.sh              # 12, needs Pebble (PEBBLE_DIR)
bash scripts/request-id-test.sh        # 12
bash scripts/trace-context-test.sh     # 17
bash scripts/drain-test.sh             # 14
bash scripts/reload-test.sh            # 7
python3 scripts/feature-test.py        # 62
python3 scripts/http2-test.py          # 54
python3 scripts/http3-test.py          # 63
python3 scripts/router-streams-test.py # 41
python3 scripts/handler-test.py        # 143, runs garuda-conformance
python3 scripts/websocket-test.py      # 104, runs garuda-conformance
python3 scripts/websocket-streams-test.py # 94, runs garuda-conformance
python3 scripts/webtransport-test.py   # 46, runs garuda-conformance
python3 scripts/upload-test.py         # 35, runs garuda-conformance
python3 scripts/broadcast-test.py      # 36, runs garuda-conformance
```

The Python suites need `h2` and `aioquic`.

---

## Unreleased

### Applications and routes

- `Application` registers handlers by method and pattern: literal, `:param`
  and trailing `*rest` segments, at most 8 parameters, compiled into a byte
  trie. HEAD falls back to GET. A path routed under other methods is answered
  405 with `Allow`.
- `app.run()` parses the command line and runs the supervisor.
  `app.run(configuration:)` takes a `ServerConfig`, checked the same way.
  `onWorkerStart` and `onWorkerShutdown` hooks run in each worker.
- `app.group("/api") { … }` mounts routes under a prefix, and groups nest.
  `--root-path` is the mount every route is matched within.
- `Router` holds routes, middleware, groups, deadlines and fallbacks built on
  their own. `app.nest("/users", router)` mounts one under a prefix and
  `app.merge(router)` registers it where the call is, inside the open group,
  whose middleware runs in front of the router's. Routers nest, and one router
  can be mounted twice. Every registration API, typed routes, WebSockets,
  WebTransport and resumable uploads included, works on both.
- `app.fallback { request, response in … }` answers requests no route matches,
  in place of 404, with the middleware of its scope. Inside a group or a
  nested router it answers only under that prefix, and the most specific
  scope wins. A path routed under other methods is still 405.
- `app.test` serves the application from a worker in the test process over a
  socket pair: `try app.test.get("/user/42")` returns the status, headers and
  body.
- The `garuda` binary serves the-benchmarker's contract through this API.
  `garuda-conformance` holds the routes the end-to-end suites need.

### Requests and responses

- `Request` and `Response` are `~Copyable`. The request lends its bytes to
  closures as `Span`s (`withPath`, `withHeader`, `withBody` and others), and the
  compiler refuses a handler that lets one escape. `path`, `header(_:)`, `body`
  and the rest return owned copies. `request[context: Key.self]` holds typed
  values for the rest of the request.
- Every response goes through one path. It frames 204, 304 and HEAD, adds the
  server's headers unless the handler set its own, and holds the body to a
  declared `Content-Length`. A handler that throws or never answers gets a 500.
- `HTTPStatus` names statuses and still takes an integer literal.
  `send(json:)`, `send(text:)`, `send(html:)`, `send(bytes:contentType:)` and
  `redirect(to:status:)` set the content type they imply.
- `Digest.sha256(_:)` hashes bytes or a file, `SHA256Digest` hashes what
  arrives a piece at a time, and `Digest.field(_:)` and
  `Digest.sha256(field:)` write and read the `sha-256=:...:` of RFC 9530's
  `Content-Digest` and `Repr-Digest`. A field naming an algorithm this does
  not check reads as nil, so a caller sees "nothing to check" rather than a
  check that passed.
- `JSONCoder` encodes and decodes `Encodable` and `Decodable` types without
  Foundation. Decoding reads only the keys a type asks for. Nesting is bounded
  at 64, a number that does not fit its type is an error, and the coder is
  fuzzed.

### Typed handlers

- A handler declares extractors and returns an answer:
  `app.get("/person/:id") { (id: Path<Int>) in JSON(person(id.value)) }`.
  `Path<T>`, `Query<T>`, `Body<T>` (JSON), `Form<T>`, `Multipart`, `State<T>`
  and `Context<Key>` are built in, and `RequestExtractor` makes more. A value
  that will not decode is a 400 saying what was wrong. A body of the wrong kind
  is a 415.
- Handlers return `JSON`, `HTML`, `Text`, `Bytes`, `Redirect`, a `String`, an
  `HTTPStatus`, or an Optional whose nil is a 404.
- A thrown `ResponseError` is the response: `HTTPError(.conflict, "the name is
  taken")` answers 409 with a JSON body. Other errors are a 500 and a log line.
- Rules beyond a type's shape are a `Validated` conformance, and `Body<T>`,
  `Query<T>` and `Form<T>` hold whatever they decode to them before the handler
  runs. `validate(_ check: inout Validation)` states the rules field by field
  -- `check.range("quantity", quantity, atLeast: 1)`, `notEmpty`, `length`,
  `email`, `oneOf`, `count`, `nested` and `each` for values inside this one,
  `require` for anything else -- and a field named "" is a rule about the value
  as a whole. Every broken rule is answered at once, as 422: the type was
  right and what it asks for is not allowed, where 400 stays a body that is
  not the type at all. `try value.validated()` checks a value that came from a
  queue or a file rather than a request.
- An error that knows which fields are at fault says so: an answer carries
  `"fields":[{"field":"email","message":"must look like an email address"}]`
  beside `error`, so a form can put every message where it belongs. Validation
  fills it, and so do JSON and query decoding, from the path they already
  report -- `items[0].sku` for a body, the item's name for a query string. An
  error with nothing to add there answers with the one key it always did.
  `ResponseError` has a `fields` requirement with an empty default, so an
  error of your own can fill it too.
- A route whose input has rules documents the 422 it can answer, and the body
  it carries, in the OpenAPI document.
- `app.state { worker in … }` builds a value once in each worker, after the
  fork and before it reports ready. A factory that throws stops that worker's
  start-up. An optional `shutdown:` tears the value down. Registering the same
  type twice is refused: it used to run both factories in every worker, so one
  value was reachable by nobody and shut down never, while the other was shut
  down twice.
- `app.documentProblems(info)` says what the OpenAPI document cannot promise,
  for a team generating clients from it: a schema read from a type whose
  decoding stopped early, which is a schema that may be missing whatever came
  after, and two routes sharing an `operationID`. Reading a type used to
  discard the failure, so an incomplete schema was silent.
- The test client takes `json:` on `post`, `put`, `patch` and `request`,
  encoding with the coder the server decodes with and setting the content type
  unless the test sets its own, and has `patch` and the `String` forms of
  `put` and `patch` it was missing.
- `app.problems()` says what about the routes cannot work, before anything is
  served: a handler taking more `Path` extractors than its pattern has
  parameters, and a handler asking for a `State<T>` no `app.state` registered.
  Both used to be a 500 for whoever sent the first request that reached them.
  `run()` prints every problem and exits 2 rather than serving, and a test can
  ask for them without starting anything -- `#expect(app.problems().isEmpty)`,
  which the starter does. An optional extractor asks for nothing, since `E?`
  is nil where `E` would have refused, and a middleware's
  `request.state(T.self)` is a call rather than a declaration and cannot be
  checked this way.
- `Multipart` gives each part's name, filename, content type and bytes, up to
  1,000 parts.

### Async handlers

- A closure that awaits registers as an async handler under the same names.
  `app.onAsync` is the raw form. Handlers run on long-lived tasks reused from a
  pool on each worker's own executor, on the worker's thread. After warm-up an
  async request allocates nothing.
- `app.deadline(milliseconds:)` answers 504 for a request still unanswered at
  its deadline, and unwinds a handler waiting on the engine. It bounds waiting,
  not computing.
- A closed connection or reset stream cancels a handler waiting on the engine.
- A request body over its limit is answered 413 on HTTP/2 too, then its stream
  is reset with NO_ERROR, where it used to get only a reset. A declared
  `Content-Length` over the limit is refused before the body is read, as on
  HTTP/1.1.
  An answer to a request that has gone is dropped rather than written into the
  next request on the slot.
- Handlers registered from `main.swift` take `sending` closures, so they run on
  the worker rather than being isolated to the main actor.
- `try await blocking { … }` runs a call that would block the worker -- a C
  library, disk I/O, a long computation -- on a thread of the worker's blocking
  pool, and resumes the handler on the worker with what it returns or throws.
  Threads start as work arrives, up to `--blocking-threads` (16) per worker;
  work beyond them waits, up to `--blocking-queue` (1024), and past that is
  refused with `BlockingPoolError.full`, a 503. The closure is `@Sendable`, and
  `Path`, `Query` and `Body` are `Sendable` when their values are.

### Middleware

- `app.use` runs middleware before every route in its scope, whether it is
  called before or after the routes. It returns nil to carry on or an answer to
  send instead, and may be async.
- `response.onSend { outgoing in … }` sees the final response, whoever
  answered, and can change its status, headers and body. Hooks run last-added
  first. They do not run for static files, cache hits, or answers given before
  a route is chosen.
- `app.cors(CORSPolicy(origins: […]))` sets the CORS policy of a scope: the
  application, a group or a router, the innermost winning. Origins are any, a
  list, or a closure's decision; methods and request headers are a list or
  what the path is routed for and the preflight asks for; exposed headers,
  credentials and max age are set with it. Any origin with credentials is
  refused when the policy is made.
- The policy answers a preflight 204 whether or not the path has an OPTIONS
  route, so a path routed only for GET no longer answers a preflight 405. It
  runs in front of the scope's middleware, so a preflight skips
  authentication, and a refusal or thrown error from an allowed origin carries
  Access-Control-Allow-Origin. `Vary` names what the answer depends on.
- `app.authenticate(bearer: Key.self) { token in … }` and
  `app.authenticate(basic: Key.self, realm:) { username, password in … }`
  read the Authorization header, keep what the closure returns under `Key` in
  the request's context, and answer 401 with the WWW-Authenticate challenge for
  a missing, malformed or refused one. The closure may be async, and a throw
  answers as a handler's does.
- `Policy` is a named rule about who may reach a route, and
  `app.authorize(CurrentUser.self, .admin)` requires it of every route in the
  scope, after the `authenticate` that says whose request it is. `and`, `or`
  and `about` combine rules and their names; a policy is a plain
  `(Value) -> Bool`, so a test calls it without a request. A rule that does
  not hold is 403 saying what would have been enough -- `{"error":"this route
  needs an administrator or the billing role"}` -- and a request with nobody
  under the key is 401 instead, since signing in may be the answer.
  `authorize(_:needs:_:)` writes a rule where it is used, and its `async`
  form may ask a database; `authorize(jwt:_:)` reads the claims
  `authenticate(jwt:)` checked, with `Policy.scope("orders:write")` for claims
  conforming to `ScopedClaims`. A handler with a rule about one row throws
  `AuthorizationError(needs:)` for the same answer.
- `app.authenticate(jwt: Claims.self)` guards a scope with the verifier
  `app.jwtVerifier` registered, found in the worker rather than passed in, so a
  `Router` built on its own can require a token without being handed the keys.
- A scope says what it can answer in the OpenAPI document: `authenticate` adds
  its 401 and its security scheme to every route in its scope, and `authorize`
  its 403. `app.describeRoutes { operation in … }` does the same for a
  middleware of your own. A note applies to every route of the scope wherever
  in it the call is, as `use` does, and leaves alone what a route said about
  the same status itself.
- `BearerToken` and `BasicCredentials` extract the same credentials in a
  handler, and `constantTimeEquals` compares a secret in time that does not
  depend on where it differs.
- `app.authenticate(bearer:state:)` and `app.authenticate(basic:realm:state:)`
  hand the check what `app.state` built for a type in the worker, such as the
  database sessions are kept in. `request.state(T.self)` reads it in any
  middleware.
- `Passwords.hash` stores a password as `$pbkdf2-sha256$i=600000$salt$hash`,
  PBKDF2-HMAC-SHA256 with a random salt, computed on the blocking pool.
  `Passwords.verify` compares in constant time, and `Passwords.needsRehash`
  says when a stored hash used fewer iterations than asked for now.
- `Tokens.random()` is 32 random bytes in base64url, and `Tokens.digest` their
  SHA-256 in hex, to store and look up instead of the token.
- `request.log` writes the application log at debug, info, warning or error,
  held to `--log-level`. Each line carries the request's method, path,
  request ID and trace context, and fields given as
  `["order": "\(id)", "cents": 1250]`. `log.with([…])` adds fields to every
  line, and a logger outlives an `await`. `AppLog` writes the same lines
  outside a request.
- `--log-format json` writes those lines as one JSON object each, and sets the
  access log's format unless `--access-log-format` is given. A line is one
  write of at most 4096 bytes: a longer one is cut and marked `truncated`.
  Nothing in a message or field can start a new line.
- `app.onResponse { done in … }` is called with every request once its
  response head is settled: a route's answer, a 404, a 429, a static file, a
  cache hit or a WebSocket's 101. `done.route` is the matched pattern, safe as
  a metric label. `done.failure` says why a route answered 5xx on its own
  account: a throw, a handler that returned without answering, or its
  deadline.
- `app.maxBodySize(bytes) { … }` holds the bodies of the routes registered
  inside it to `bytes` instead of `--max-body`, larger or smaller. A declared
  length past it is 413 before the body is read, and a chunked, HTTP/2 or
  HTTP/3 body is refused as it grows past it. Nested scopes apply the
  innermost, and a streaming route keeps its own `maxBodySize:`.
- `app.concurrencyLimit(max) { … }` lets at most `max` handlers of its routes
  run at once in each worker process, and answers one more 503 without
  running it. Middleware is not counted, so a request authentication refuses
  takes no place. A streamed response holds its place until it is written,
  a request that goes away gives its place back, and nested limits all apply.
  Both work on a `Router` too.
- `request.cookie(name)`, `request.cookies` and the `Cookies` extractor read
  every Cookie header, HTTP/2's one-per-cookie included, and take the first
  value of a repeated name.
- `response.setCookie(Cookie(name, value))` adds a Set-Cookie header with
  `Path=/`, `HttpOnly`, `SameSite=Lax`, and `Secure` when the request came
  over HTTPS, directly or through a trusted proxy. Max-Age, Expires, Domain
  and Partitioned are there to set. `SameSite=None` is always `Secure`.
  A name that is not a token, a value outside RFC 6265's cookie characters, or
  a path or domain holding `;` is refused rather than sent.
  `response.removeCookie(name)` expires one.
- `response.setCookie(cookie, key: key, .signed)` signs the value with
  HMAC-SHA256, and `.encrypted` seals it with AES-256-GCM. The cookie's name
  is bound in, and either way the value may be any string.
  `request.cookie(name, key: key, .signed)` returns nil for a cookie that
  was changed, moved from another name, or made with another secret.
  `CookieKey(secret:previous:)` takes a secret of at least 32 bytes and the
  ones it replaced, derives separate signing and encryption keys with HKDF,
  and reads cookies made with any of them. `CookieKey.randomSecret()` makes one.
- `app.sessions(store:)` gives every route in its scope a `Session`, which a
  handler takes as an extractor. A request whose cookie names a live session
  has it loaded before the handler runs, and its idle timeout
  (`idleTimeoutSeconds`, a day by default) starts again. A request without one
  costs the store nothing.
- `session["key"]` and `session.value(T.self, "key")` read it.
  `session.set`, `session.set(_:json:)` and `session.update { … }` write the
  change to the store before they return, so the client's next request sees
  it. The first change makes the ID, 32 random bytes, and the cookie that
  carries it goes out with the response: change the session before answering.
- An ID the server did not make is never used: a cookie naming no live session
  is ignored, and the first change makes a fresh ID. `session.renew()` moves
  the data to a new ID, for a login. `session.destroy()`, or emptying the
  session, deletes it and expires the cookie.
- `SessionConfiguration` names the cookie (`id` by default) and sets its path,
  domain, SameSite and the rest. With a Max-Age the cookie is sent again each
  time the session loads, so it lasts as long as the session does.
- Stores: `MemorySessionStore`, for `--workers 1` and tests, since each
  worker is a process with its own memory. `RedisSessionStore` keeps each
  session as JSON with a PX expiry, extended with GETEX (Redis 6.2 or later).
  `SQLiteSessionStore` keeps a table (`createTable()`, or `schema` in a
  migration) and moves a session's expiry once half of the timeout has gone,
  so reads rarely write. `deleteExpired()` clears expired rows. A store of
  your own implements `SessionStore`'s load, save and delete.
- `app.csrfProtection(trustedOrigins:)` refuses cross-site request forgery
  in its scope without tokens. A request other than GET, HEAD or OPTIONS is
  answered 403 when Sec-Fetch-Site says `cross-site` or `same-site`, or, from
  a browser that sends no Sec-Fetch-Site, when Origin names a host other than
  the request's Host or `:authority` (`:80` and `:443` aside) or is `null`.
  `same-origin`, `none`, and a request with neither header, which no browser
  page made, pass. An origin in `trustedOrigins` passes whatever the headers
  say. This is the check Go's net/http added in 1.25.
- `app.securityHeaders(SecurityHeaders())` adds, to every answer in its scope
  including errors and middleware refusals, `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: no-referrer`, and
  `same-origin` Cross-Origin-Opener-Policy and Cross-Origin-Resource-Policy.
  `Strict-Transport-Security: max-age=31536000; includeSubDomains` goes only
  on answers to HTTPS requests, a trusted proxy's included. Each is a field to
  change or set to nil; `contentSecurityPolicy` and `permissionsPolicy` are
  there to fill. A header the response already carries is not replaced.
- `app.trailingSlash(.redirect)` answers a path whose trailing slashes no
  route has, such as `/users/` when `/users` is routed for any method, with
  308 and the path without them, query kept. `.ignore` serves it from that
  route instead, a streaming body's own limit included. `.strict`, the
  default, leaves routes matching exactly. A path that matches as it came is
  never touched, so this costs a matched request nothing, and a redirect whose
  Location would start with `//` is not sent.
- `app.requestDecompression()` decodes the request bodies of its scope whose
  Content-Encoding is gzip, deflate, br or zstd, several stacked included,
  before the middleware after it and the handler read them. The decoded size
  is held to `app.maxBodySize` or `--max-body` as it grows: 413 past it, 400
  for bytes the coding did not make, and 415 with Accept-Encoding for a coding
  that cannot be decoded. A streaming route's body is left as it came.
- `app.allowedHosts(_:)` answers 400 to a request in its scope whose Host or
  `:authority`, port aside, is not listed, or that has none. An entry is a
  host, an IP literal (`[::1]` for IPv6), or `*.example.com` for the names
  under a domain, which does not include the domain itself.
- `app.addressFilter(allow:deny:)` answers 403 to a client whose address is
  on `deny`, or is not on a non-empty `allow`; deny is read first. Entries are
  addresses, CIDR blocks, `unix` and `*`. The address is `request.remoteAddress`,
  a proxy's forwarded one when `--forwarded-allow-ips` trusts the peer, and an
  IPv4 client on an IPv6 socket (`::ffff:a.b.c.d`) matches as IPv4.
- `app.openAPI(OpenAPIInfo(...), path: "/openapi.json")` serves an OpenAPI
  3.1 document of every route, built once when the application compiles, and
  `app.openAPIDocument(_:)` and `app.openAPIJSON(_:)` return it for a build
  step. `app.swaggerUI(path: "/docs")` serves Swagger UI, loaded from jsDelivr,
  reading the document by a relative URL so it works under `--root-path`.
- A typed route describes itself: `Path<T>` is a typed path parameter,
  `Query<T>` a query parameter per field, `Body<T>` a JSON request body,
  `Form<T>` and `Multipart` form bodies, `BearerToken` and `BasicCredentials`
  security schemes with a 401, `LastEventID` a header, and `JSON<T>`, `String`,
  `HTML`, `Bytes`, `EventStream` and an optional (with its 404) the response.
  A raw route is listed with its path parameters; a WebSocket route with 101.
  Routes in groups and nested routers carry their full paths.
- Schemas come from decoding each `Decodable` type once with a decoder that
  records what it is asked: properties, which are required, integers and
  numbers with their formats, `UUID` and `Timestamp` as `uuid` and
  `date-time` strings, arrays, sets, string-keyed dictionaries, and enums
  with `CaseIterable` raw values. A named type is a component under
  `$ref`, and a type that contains itself refers to itself.
  `OpenAPISchemaDescribing` lets a type write its own.
- Route methods (`get`, `post`, `on`, `webSocket` and the rest) now return
  the route's `OpenAPIOperation`, discardable, with `summary`, `description`,
  `tags`, `operationID`, `deprecated`, `hidden`, `response` (with or without a
  JSON type) and `security`. An extractor or response type of your own
  conforms to `OpenAPIExtractorDescribing` or `OpenAPIResponseDescribing`.
  `RouteBuilder` gains a `document(_:)` requirement.
- `AsyncRequestExtractor` is an extractor that awaits: a database, a session
  store, another service. Async handlers await it in order with the others,
  and a request that ended while it waited stops before the extractors after
  it read the request. A synchronous handler, WebSocket or WebTransport route
  that takes one stops the program when it is registered, not on a request.
- An optional extractor, `E?`, is nil where `E` would have refused the
  request, and `Result<E, any Error>` gives the handler the error to answer
  as it likes. Either way the path parameters `E` would have taken are left
  for the next extractor, and the OpenAPI document describes `E`.
- The auth example adds `SignedInUser`, an async extractor over its sessions
  table, and `GET /whoami`, which takes it as `SignedInUser?`.
- `--metrics-port` also reports each route: `garuda_route_requests_total`
  by method, route pattern and status class, and a
  `garuda_route_request_duration_seconds` histogram by method and pattern.
  The label is the registered pattern (`/users/:id`), so series are bounded by
  the number of routes; unmatched requests and fallbacks have a series each.
  Counted in shared memory mapped before the fork, a row per worker, with no
  locks; nothing is counted without `--metrics-port`.
- `--spa-fallback PREFIX=FILE` serves a single-page application's page for a
  browser navigation under PREFIX that no static file, route, 405 or scope
  fallback answered: `GET` or `HEAD` whose `Accept` names `text/html`. Other
  requests, such as a missing asset or an API call, keep their 404. The file
  goes out as a static file does, with its ETag and 304.
- JSON Web Tokens: `JWTKeys` signs and verifies HS256/384/512, RS256/384/512,
  PS256/384/512, ES256/384/512 and EdDSA, with keys from HMAC secrets, PEM
  (public keys, certificates, private keys), JWK, or generated. Verifying
  checks the signature, `exp` and `nbf` with leeway, and `iss` and `aud`
  when asked. It refuses `alg: none`, `crit`, tokens over 16 KiB, RSA keys under
  2048 bits and short HMAC secrets. Each key is bound to one algorithm, which
  rules out HS256 signed with an RSA public key. Signatures use the system's
  libcrypto through a small C target; tokens interoperate with PyJWT in both
  directions for every algorithm.
- `JWT<Claims>` extracts a verified bearer token with its claims decoded, from
  what `app.jwtVerifier` registered. `app.authenticate(jwt:verifier:)` requires
  one of every request in a scope. Failures are 401 with
  `WWW-Authenticate: Bearer error="invalid_token"`. `keys.publicJWKS` is the
  public key set to publish.
- `JWKSVerifier(url:validation:)` verifies tokens from an identity provider
  against its JWK Set. The set is fetched on first use and kept for
  `maxAgeSeconds`. An unknown `kid` fetches it again, and requests during a
  fetch share it. Fetches happen at most once per `minimumRefetchSeconds`, and
  keys in hand survive a failed fetch; with none, the answer is 503. Only
  asymmetric keys for `algorithms` are trusted: `oct` and `use: enc` keys are
  skipped. Google's and Microsoft's sets load.
- `TokenIssuer` issues short-lived JWT access tokens with rotating refresh
  tokens. `issue(subject:)` answers a login with a `TokenPair`, encoded as an
  OAuth 2.0 token response, and `refresh(_:)` spends a refresh token for a new
  pair in the same family, with claims rebuilt by your closure. A spent token
  presented again revokes its family, the reuse detection RFC 9700 recommends,
  except within `reuseGraceSeconds`, where it is only refused. The family is
  checked again once the new pair is built, so a logout that lands while the
  claims are being made does not hand back a working access token.
- Refresh tokens are 32 random bytes stored as SHA-256 digests. They expire
  after `refreshTokenSeconds` unused, and families after
  `maximumSessionSeconds`. `revoke(_:)` logs out one family and
  `revokeAll(subject:)` every family of a user. A refused refresh is 400
  `invalid_grant`.
- Stores: `MemoryRefreshTokenStore`, `RedisRefreshTokenStore` (spending with
  `SET NX`), and `PostgresRefreshTokenStore` and `SQLiteRefreshTokenStore`
  (spending with a conditional `UPDATE`), each atomic across workers. The memory store locks its state, so
  it is safe to reach from the blocking pool or a thread of your own. The Redis
  store's index of a subject's families only ever has its expiry pushed out, so
  two logins arriving at once cannot leave `revokeAll(subject:)` blind to a
  family that is still good.
- A fifth example, the starter (`swift run starter`, Examples/STARTER.md): a
  whole application rather than one feature. PostgreSQL, accounts with JWT
  access tokens and rotating refresh tokens, an append-only migration list run
  both by `starter migrate` and by every worker at start-up, configuration read
  from the environment and checked once with every problem reported at once,
  cursor paging, ownership answered as 404, OpenAPI with Swagger UI, health and
  readiness, tests through `app.test` against a real database, and a Dockerfile
  and systemd unit in Examples/deploy/.
- `String.trimmingWhitespace()` is public: validating a field someone typed
  starts with it, and Swift without Foundation has no such method.
- `PostgresClientError.isConstraintViolation` says whether the server refused a
  statement for breaking a constraint, as `SQLiteClientError` already did.
- PostgreSQL types for what had none: `PostgresDate` (`date`),
  `PostgresTime` (`time`), `PostgresInterval` (`interval`, months, days and
  microseconds kept apart), `PostgresNumeric` (`numeric`, exact, kept as its
  digits) and `PostgresJSON<T>` (`json` and `jsonb`, decoded into your type).
  Each reads the binary form and text as a fallback, and binds as text the
  server accepts whatever its `DateStyle` or `IntervalStyle` is. The interval
  parser reads every style PostgreSQL writes, ISO-8601, the default and
  `sql_standard`. `PostgresClientError.isConstraintViolation` joins
  `sqlState`.
- PostgreSQL arrays are Swift lists: `[String]` for `text[]`, `[Int]` for
  `int[]`, `[String?]` where NULLs are among the elements, and a list of any
  other type the driver reads, `[[UInt8]]` for `bytea[]` included. A list
  binds as an array literal, so `$1 = any(tags)` takes a list as readily as a
  column gives one, and every element -- a comma, a quote, a brace, an empty
  string, the word NULL -- survives the round trip. `[UInt8]` is still a
  `bytea` rather than a list of numbers. Arrays of more than one dimension are
  refused rather than flattened. One array column asked for as a list --
  `pool.first([String].self, "select tags from notes where id = $1", id)` --
  is that column rather than a row of columns, as bytes already were.
  `PostgresType.elementType(of:)` and `PostgresArrayText` are public for a
  driver of your own.
- `COPY` in both directions: `pool.copyIn(sql, rows:)` loads rows without a
  round trip each, `pool.copyIn(sql) { ... }` streams whatever bytes the
  statement's format asks for, and `pool.copyOut(sql) { chunk in ... }` reads a
  table out a chunk at a time, with `copyOutRows` for the text format's rows.
  `PostgresCopyText` writes and reads that format -- tabs, `\N` for a null,
  and a backslash before anything that would be punctuation. A `copyIn` whose
  closure throws sends `CopyFail`, so the server keeps none of the load and the
  connection stays usable; a `copyOut` whose closure throws closes the
  connection, since a copy out cannot be stopped politely. Both are on
  `PostgresTransaction` as well, where a load belongs to the transaction.
- Composite types are `PostgresRecord`: the fields in order, since the wire
  carries no names, read from `(a,b,"c,d")` and bound back as one. An enum
  needs nothing of its own -- it arrives as its label, so a Swift enum backed
  by `String` reads it -- which is now tested rather than assumed.
- PostgreSQL over a unix socket: `PostgresConfiguration(unixSocketPath:user:)`,
  or `?host=/var/run/postgresql` in a URL, or the path percent-encoded where
  the host goes. The path may name the socket or the directory holding it, as
  libpq's does. TLS is off for a socket, and asking for it anyway is
  `tlsUnavailable` rather than a quiet fallback.
- SASLprep's mapping step is applied to a password before SCRAM, as the server
  applies it before storing a verifier: a non-ASCII space becomes a space and
  a soft hyphen goes. A password that was pasted with a non-breaking space in
  it now authenticates. NFKC normalisation is still not done, and
  [CONNECTORS.md](CONNECTORS.md) says so.
- The macOS CI job prints its descriptor limit and runs the unit tests a
  second time one suite at a time. That split the four failures it alone
  has: three pass serially, so those interfere with one another through
  something the suites share, and `aClosedDatabaseRefusesStatements` fails
  either way, so that one is the platform. It is the only test whose
  database is never written to, and a read-only connection cannot create a
  WAL database's -shm file, so it now says which of those files the writer
  left behind. The SQLite tests also no longer share a plain `Int` between
  suites that run beside one another.
- The broadcast suite waits until an event stream is demonstrably subscribed
  before it publishes to it, rather than the instant its head arrives: the
  head of a stream goes out before its handler has subscribed, so the two
  orders are not the same. Where that check has passed and the stream is
  still sent nothing, the suite now says which worker the stream landed on
  and which workers the WebSockets landed on. A CI runner has failed here
  once, and the cause is not yet known; this is what will name it.
- The test that an idle outbound connection is swept away no longer sets the
  idle time down to a millisecond before it has checked the connection is
  there. A sweep landing in that gap failed the test by finding the very
  thing it was about to ask for, which reads as the opposite of what went
  wrong. A parallel run has done it.
- Two unit tests that want a second loopback address skip where the machine
  has not got one, and say what to do about it, instead of failing. Linux
  routes the whole of 127.0.0.0/8 to `lo`; macOS configures 127.0.0.1 and
  nothing else. Both tests are worth keeping -- they are what proves the
  address a resolver returned is the address connected to, and that a
  certificate is checked against the address actually reached.
- A handler resumed from a thread that is not its worker's no longer crashes
  the worker. An executor is entitled to be given a job from any thread -- the
  runtime resumes a task wherever it resumed whatever the task was waiting on,
  and for a wait the engine does not own that is a thread of its own choosing
  -- and the worker's executor took that as a fault to be refused loudly. Such
  a job now goes on a list under a lock, and a byte down a pipe the poller
  watches wakes the worker to run it on its own thread. A handler's code still
  runs only there, and the worker's own thread still enqueues without a lock
  or a syscall. The fault was found by CI on a macOS runner and could not be
  reproduced on any other machine; the test that now covers it resumes a
  handler from a thread of its own, which does not depend on luck.
- `response.cancellable { … }` gives up on a wait the engine does not own.
  A handler suspended on a library's own continuation was not woken when its
  request ended -- nothing knew to wake it -- and held a handler task until
  that wait finished on its own. The body now runs in a task of its own, raced
  against the request ending, so the handler throws `cancelled` at once. The
  body is cancelled in the ordinary Swift way, which works because that task
  is a fresh one: the pooled task running the handler cannot be cancelled,
  since a task cancelled in Swift's sense stays cancelled. A typed handler
  asks for the same thing as a `Cancellation` extractor.
- What that does not do is stop work which ignores cancellation, so the worker
  counts it, logs once past `ServerConfig.maxAbandonedWaits` (256) and
  answers the health check 503 until it has caught up. Out of rotation rather
  than failing requests that have nothing to do with whatever is stuck.
- Swift 6.2 builds and tests Garuda again, and the package and README say 6.2
  rather than 6.1, which is where `Span` arrived. Five places handed a
  `nonisolated(unsafe)` local to a `sending` closure, which 6.3 allows and 6.2
  does not; `Unsafely` says the claim once instead.
- CI checks every change instead of waiting to be started by hand. Build,
  unit tests and compile-fail run on each push and pull request, and so do two
  things that were not in CI at all: the connectors against a real PostgreSQL
  and a real Redis, which is what makes the opt-in suites run, and the
  end-to-end suites that drive the release binary over a socket. The protocol
  suites and the sanitizer fuzz run nightly. The Swift toolchain setup is one
  composite action rather than four copies.
- Two races in the tests themselves, which each failed about one full run in
  five: the resolver's fakes took a TCP port because a UDP one of that number
  was free, and the SPA fallback tests named their site directory from an
  unsynchronised counter.
- Every producer writing a streamed response waits while the client is
  behind, not only the first to find the backlog full. A second producer used
  to be let through on the ground that someone else was already waiting, which
  left it free to queue as fast as it could produce while the client read
  nothing -- the mark bounded one writer and nothing else. WebSocket sends had
  the same shape and are fixed with it. The ceiling is now the mark plus one
  write from each producer, which [TRANSPORT.md](TRANSPORT.md) states, since a
  write is queued before it is waited on and so can cross the mark by its own
  size.
- A Redis retry cannot repeat a write it may already have done. A failure
  with the command's bytes already written is `RedisClientError.unknownOutcome`,
  wrapping the `closed` or `timedOut` underneath -- `error.cause` reads it
  back and `error.mayHaveRun` is true. A failure before the first byte throws
  plainly, as before, because the server never saw it. `RedisCluster` and
  `RedisSentinelPool` take `replay:`: `.reads` by default, which sends only
  commands that read to another node, `.anything` for a cache where a second
  write costs nothing, and `.nothing`. `RedisReads.only(_:)` is the table
  behind `.reads`, and treats anything it does not recognise as a write.
  Before this, a lost reply to `INCR` or `EXEC` was a retry.
- A cluster follows a redirect per command rather than per batch. A slot in
  the middle of migrating answers the keys it still has and redirects the keys
  it does not, so a pipeline comes back part answered and part redirected:
  what was answered is kept and only what was refused goes again, each behind
  its own `ASKING`. Before this, the whole batch went again and every write in
  it already answered happened twice. A transaction is still treated as one
  thing, which is right: a command refused while it was being queued makes
  Redis abort all of it.
- A sentinel pool retries only the part of a pipeline the old master refused.
  A failover in the middle of a batch answers the commands before it and
  refuses the writes after it with `READONLY`; the refusal is proof they did
  not run, and the answers are proof the others did.
- Redis Cluster: `RedisCluster(seeds:)` is a pool per node and a map of which
  node owns which of the 16,384 slots, read with `CLUSTER SLOTS`. It is a
  `RedisCommandSender`, so every typed command a pool has it has too, aimed at
  the node that owns the key. `MOVED` corrects the map and sends the command
  again; `ASK` sends `ASKING` and the command to the node taking a slot on,
  without touching the map; `TRYAGAIN` and `CLUSTERDOWN` are waited out; a node
  that has gone is dropped and the map loaded from another. So a map that is
  behind costs a round trip, not a wrong answer. `pipeline` sends one write per
  slot and returns the replies in order; `transaction` and `session(for:)` are
  one slot's, as they must be; `subscribeSharded` and `spublish` reach the
  shard that owns a channel. `RedisSlots` and `RedisKeys` are public for a
  driver of your own.
- Redis Sentinel: `RedisSentinelPool(RedisSentinelConfiguration(sentinels:master:server:))`
  asks the sentinels where the master is instead of being told, and checks what
  they name with `ROLE` -- a sentinel can be behind and name a node that has
  been demoted. A lost connection, or the `READONLY` a demoted master answers a
  write with, means asking again and trying the new master. `masterAddress`
  says where it is; `refresh()` asks on demand.
- `RedisSessionStore` and `RedisRefreshTokenStore` take any
  `RedisCommandSender`, so they work on a cluster and behind sentinels as well
  as on one server. `pipeline` is part of that protocol now, and `RedisValue`
  has an `integer` beside `string`, `bytes` and `array`.
- `LISTEN` and `NOTIFY`: `app.listen("jobs") { notification, start in ... }`
  hears notifications in each worker, on the worker's thread with the worker's
  state, on a connection of its own that the pool does not count. A connection
  that goes is logged and made again with the same channels after
  `reconnectAfter` seconds; `whenListening:` runs each time the channels start
  listening, which is where an application picks up what was sent while it had
  no listener -- the server keeps nothing for a session that is not connected.
  A throw from the handler is logged and the next notification is handled as
  usual. Underneath, `pool.listen(channels)` gives a `PostgresListener` with
  `next(timeoutMilliseconds:)`, `listen`, `unlisten`, `channels`, `isOpen` and
  `processID`, and `pool.notify(channel, payload)` sends one through
  `pg_notify` so neither the channel nor the payload is part of the statement.
  `tx.notify(channel, payload)` sends one when its transaction commits, and
  not at all if it rolls back. A notification that arrives in the same read as
  the reply to the statement that subscribed is kept for the listener rather
  than refused as a reply nobody asked for.
- `app.every(interval, jitter:firstAfter:onWorker:) { start in ... }` runs work
  on a timer in each worker: clearing what has expired, refreshing a cache. It
  runs on the worker's own thread with the worker's state, from the moment that
  worker serves until it drains, and a throw is logged and retried at the next
  turn. `jitter` (a tenth of the interval by default) keeps workers from
  firing on the same tick, and `onWorker: 0` restricts a job to one worker --
  which is one process group's worker 0, not the cluster's, so work that must
  happen once takes a lock in the database. `app.test` runs the jobs too.
- `AppEnvironment` reads an application's own settings -- where its database
  is, what signs its tokens, which features are on -- and collects every
  problem instead of failing at the first: `string`, `int` with a range,
  `bool`, `choice` over a `CaseIterable`, `secret` and `secretOrFile` (which
  reads `<NAME>_FILE`, as a mounted secret arrives), and `url`, whose password
  is held back. `problem(_:)` records a check of the application's own, and
  `check()` throws `AppEnvironmentError` listing all of them. `mode` reads
  `APP_ENV`, and `default: production ? nil : value` is how a setting has a
  default in development and is required in production. `summary()` prints
  what was read for a `myapp env` command, with secrets held back and
  passwords taken out of URLs. Garuda's own settings stay on the command line.
- `app.run(arguments:)` parses a list of arguments as the `garuda` executable
  parses its command line, so an application with commands of its own can hand
  Garuda the flags that are Garuda's: `starter serve -- --port 8080`.
- `app.runOnce { start in ... }` runs one piece of async work against an
  application's state with nothing served: a migration, a backfill or a seed
  from the command line. A worker is built in the process with no listening
  socket, the work runs on its thread, and the state is torn down afterwards.
  It reports `RunOnceError.failed`, `.timedOut` or `.workerCouldNotBeBuilt`,
  so a command can exit non-zero.
- `app.prepare { start in ... }` runs async start-up work in each worker --
  a schema to migrate, a cache to warm -- after its state is built and before
  its listening socket is watched, so a connection that arrives meanwhile
  waits in the backlog instead of reaching a worker that is not ready.
  `start.state(_:)` gives the hook what `app.state` built, and
  `start.index` says which worker it is. A hook that throws or outstays
  `timeoutMilliseconds` (30 seconds by default, per hook) stops the worker.
  `app.test` runs the hooks too.
- `PostgresConfiguration(url:)` reads a `postgres://` connection URL, which is
  how a deployment usually passes one: credentials percent-decoded, an
  optional port and database, IPv6 in brackets, and the `sslmode`,
  `sslrootcert` and `connect_timeout` parameters. `sslmode=prefer` and
  `allow` are refused, because falling back to plaintext lets the path decide.
- `pool.migrate(_:table:)` brings a PostgreSQL schema up to date from an
  ordered list of migrations, each the statements it needs, applied in one
  transaction and counted in a version table. Workers starting together
  serialise on an advisory lock, and a database ahead of the build is
  `PostgresMigrationError.unknownSchemaVersion`.
- COMPATIBILITY.md: what an application may depend on -- the public Swift API,
  the flags, what goes over the wire, the schemas Garuda writes -- and what a
  release may change. Before 1.0 a minor release may break what is covered; a
  patch release may not. Deprecations warn for a release before anything is
  removed, and what must be true before 1.0 is listed.
- MIDDLEWARE.md: how middleware and `onSend` run, the order to add it in,
  every middleware Garuda ships with its options and answers, the server flags
  that act as middleware, and writing middleware and extractors of your own.
- EXAMPLES.md: the four runnable applications, and recipes for a first
  server, a JSON API, errors, routers, databases, sign-in with sessions, custom
  extractors, OpenAPI, server-sent events, WebSockets, testing and production
  flags, each compiled against the public API.

### Streaming responses and server-sent events

- `response.stream(contentType:)` or a returned `StreamingBody` writes a body as
  it is produced: chunked on HTTP/1.1, close-delimited on HTTP/1.0, DATA frames
  on HTTP/2 and HTTP/3. A `Content-Length` the handler sets is kept and
  enforced.
- A write waits while more than `writeHighWaterMark` (512 KiB) is queued,
  until the backlog is under `writeLowWaterMark` (128 KiB). `queuedBytes` says how far behind the
  client is, including what QUIC holds unacknowledged. A client that stops
  reading is closed after `--request-timeout`.
- Returning or `finish()` ends the body. A throw part-way closes the HTTP/1.1
  connection or resets the stream, so a client never takes half a body for a
  whole one.
- `EventStream` and `response.eventStream()` send server-sent events. Data is
  split into one `data:` line per line, a line break cannot start a field in an
  event name or ID, and `cache-control: no-cache` is set unless the handler set
  its own.
- A quiet event stream is sent a comment every `--sse-keep-alive` seconds (15),
  by the worker, whatever the handler is waiting on. `EventStream(keepAlive:)`
  sets it per stream.
- `Topic("name").publish(...)` sends a message to every subscriber on every
  worker, through a ring the workers share (`--broadcast-size`, 4 MiB).
  `events.subscribe`, `ws.subscribe` and `response.subscribe` hear it, and
  `events.forward(topic, after: lastEventID)` sends each message as an event
  whose `id` is its number. A client reconnecting with `Last-Event-ID` is sent
  what it missed from the ring, on whichever worker it reaches. What cannot be
  sent -- written over, or more than `--broadcast-queue` behind -- arrives as
  `.missed`.

### Streamed request bodies, interim responses and resumable uploads

- `app.onStreamingBody(.post, "/upload", maxBodySize:) { request, response, body in … }`
  runs when the request's head arrives. `body.read(maxBytes:)` returns the next
  piece, or nil at the end, and `readAll(maxBytes:)` the rest. `maxBodySize`
  replaces `--max-body` for that route and is unlimited if left out.
- Reading is flow control. Unread bytes hold back an HTTP/1.1 connection's
  reads, the HTTP/2 stream window and the QUIC stream window, so a handler
  that writes to a slow disk slows only its own client.
- A body that ends short throws `RequestBodyError.incomplete`, but only after
  everything that did arrive has been read. `body.cancel()` ends the request.
  Two reads at once throw `concurrentRead`.
- `response.sendInterim(status:headers:)` sends a 1xx before the answer, such
  as 103 Early Hints, on HTTP/1.1, HTTP/2 and HTTP/3. It does nothing on
  HTTP/1.0 or once the answer has started.
- A new module, `GarudaUploads`, implements resumable uploads
  (draft-ietf-httpbis-resumable-upload-12, interop version 9):
  `app.resumableUploads("/files", store: FileUploadStore(directory:)) { upload in … }`.
  A client that is cut off asks for the offset with HEAD or GET, and appends
  the rest with PATCH. Creation can be POST, PUT or PATCH.
  - Only a client that sends `Upload-Draft-Interop-Version: 9` gets 104
    responses, as the draft requires.
  - `UploadLimits` sets `max-size`, `min-size`, `max-append-size`,
    `min-append-size` and `max-age`, advertised in `Upload-Limit` and enforced
    as the body arrives, including bodies with no declared length. A client
    that declares a size under a minimum is refused before anything is stored;
    one whose body turns out to be short is refused the completion and keeps
    what arrived, so it can send the rest. Creating an upload is not held to
    `min-append-size`, since starting with an empty body is what the draft
    describes. Too small is a 400 carrying `Upload-Limit`, HTTP having no
    opposite of 413.
  - Integrity, as RFC 9530 has it. `Content-Digest` on a request is checked
    against the bytes that arrive; bytes that are not what it says were
    corrupted on the way, so they are dropped and the upload stays at the
    offset that request began at. `Repr-Digest` on the request that creates an
    upload is checked when the last byte is in, however many requests later
    that is; an upload that is whole and wrong cannot be mended by appending,
    so it is removed. `Want-Repr-Digest` asks for the digest in the answer,
    and `upload.digest()` gives the handler the same one to store beside the
    bytes, computed once. A digest field naming an algorithm the server does
    not check is refused rather than ignored.
  - The answer to the request that completed an upload is remembered as it is
    sent, and given again to a `GET` of the upload's URL until `max-age`: a
    client whose connection died before the answer arrived can ask for it
    rather than be told only that the upload is complete. It outlives the
    bytes, so a handler that files them away and calls `upload.remove()` still
    answers. `HEAD` is left exactly as the draft describes, and `DELETE` takes
    the answer away with the upload.
  - A wrong offset or inconsistent length is answered with the draft's problem
    documents.
  - Only one request appends to an upload at a time, across worker processes,
    through a file lock. A client that resumes on the same worker while its old
    request is still open ends the old one, keeping what it received.
- `scripts/upload-test.py` (35 checks) covers streamed bodies, flow control,
  per-route limits, interim responses and uploads over HTTP/1.1, HTTP/2 and
  HTTP/3, including resuming after a dropped connection and a reset QUIC
  stream.

### WebSockets

- `app.webSocket("/chat/:room", subprotocols: ["chat.v2"]) { (ws: WebSocket, room: Path<String>) async throws in … }`
  serves RFC 6455 over HTTP/1.1, cleartext or TLS. Middleware and extractors
  run before the upgrade and can refuse it with an ordinary status; headers
  middleware adds go out with the 101. A plain request to the route is 426.
- The same route serves WebSockets over HTTP/2 (RFC 8441) and HTTP/3
  (RFC 9220), on by default. HTTP/2 connections advertise
  `SETTINGS_ENABLE_CONNECT_PROTOCOL`, and an extended CONNECT is answered 200.
  A handler that is not reading holds back flow-control credit for its stream
  alone. The peer's END_STREAM or FIN is 1006, and an abandoned WebSocket
  resets only its own stream.
- `--websocket-protocols http1,http2,http3` chooses which protocols carry
  WebSockets. The others refuse them: 501 for an HTTP/1.1 upgrade or an HTTP/3
  CONNECT, and no advertisement on HTTP/2.
- The handler sees whole messages: `receive()`, or `for try await message in ws`,
  and `send` of text or bytes, which waits while the peer reads slowly.
  `close(code:reason:)` starts the close handshake, `closeCode` and
  `closeReason` say how the peer ended it, and `sleep(milliseconds:)` waits on
  the worker between sends.
- The engine joins fragments, checks UTF-8 as frames arrive, answers pings and
  closes, sends keepalive pings, and refuses protocol violations with the close
  code RFC 6455 gives them, whether or not the handler is reading. With
  `--ws-compress`, permessage-deflate is agreed and a message that inflates past
  `--ws-max-message` is refused.
- Messages a handler has not read wait in a queue bounded by `--ws-max-queue`
  and `--ws-max-queue-bytes`; past that the socket is not read.
- A handler that returns closes with 1000, one that throws with 1011, and a
  draining worker closes its WebSockets with 1001.
- Each WebSocket's handler runs on a task of its own, so open WebSockets do not
  take tasks from the pool ordinary requests use.
- The Autobahn testsuite's 517 cases pass: none fail, and the three marked
  non-strict (6.4.2 to 6.4.4) check UTF-8 inside a frame, which the engine
  checks once the frame has arrived.
- `app.test.webSocket("/path")` opens a WebSocket in a test: `send`, `receive`,
  `ping` and `close`, with the 101 or the refusal in `response` and the
  server's close in `closeCode` and `closeReason`.

### WebTransport

- `app.webTransport("/room/:id") { (session: WebTransportSession, id: Path<Int>) async throws in … }`
  serves HTTP/3 extended CONNECT. Middleware and extractors can refuse a
  session with an ordinary status. A session accepts and opens streams in both
  directions, sends and receives datagrams, and closes with a code and reason.
- Stream bytes stay in the transport until the handler reads them, and writes
  wait above `writeHighWaterMark`. At most 32 streams are held for a session
  not yet accepted. Datagrams a handler is slow to read are dropped oldest
  first.

### HTTP client

- `request.client` makes HTTP requests from a handler: `get`, `head`, `post`
  and `send`. It speaks HTTP/1.1, and HTTP/2 over TLS when the server offers
  it. An HTTP/2 connection is shared by every request to the same origin.
- Connections are opened on the worker's poller and kept for reuse, only for
  the same destination and verification identity, and only when the previous
  response was read whole.
- Outbound TLS verifies the certificate against the name or address asked for.
- Names are resolved on the poller from `resolv.conf`: UDP with TCP fallback,
  cached for their TTL. Every address in an answer is tried in order.
- Headers that could split a request are refused, and so are URLs with
  userinfo. A response to HEAD and a 204 carry no body whatever they declare.
- The client sends Accept-Encoding with the codings it can decode (gzip and
  deflate, brotli and zstd when their libraries load) and decodes the body,
  removing Content-Encoding and Content-Length. The decoded body is held to
  `maxBodyBytes` as it grows, and a corrupt one is `undecodableBody`. A coding
  it cannot decode is returned as it came. With `decompress = false` the caller
  may send its own Accept-Encoding.
- `client.redirects` follows redirects: `.none` (the default), `.sameOrigin()`,
  `.any()` or `.matching { url in … }`, each with a limit (10), past which is
  `tooManyRedirects`. 303, and 301 or 302 after a POST, become a GET without
  the body; 307 and 308 repeat the request. Leaving the origin drops
  Authorization, Cookie and Proxy-Authorization, and https is never left for
  http. A redirect the policy does not follow is the response.
  `ClientResponse.url` is where the request ended up.

### PostgreSQL

- A native driver on the worker's poller, with no libpq. A `PostgresPool` per
  worker runs `query`, `first` and `execute`. Rows decode into `Decodable`
  types by column name, values are bound as parameters, and a refused
  statement's SQLSTATE is `error.sqlState`.
- SCRAM-SHA-256, verifying the server's signature. MD5 is refused, and
  cleartext passwords are refused unless allowed and never sent without TLS.
  TLS is required by default.
- `db.transaction { tx in … }` commits when the closure returns and rolls back
  when it throws, or when a statement inside it failed. A connection left
  inside a transaction is closed, not pooled.
- A statement waiting for a connection gives up after
  `acquireTimeoutMilliseconds` with `PostgresClientError.poolTimedOut`.
- Each connection keeps up to `statementCacheCapacity` (256) statements
  prepared. A statement the server dropped is prepared again and retried
  outside a transaction. Repeated statements read booleans, integers, floats
  and bytea in binary.
- `[UInt8]` binds as `bytea`. `UUID` and `Timestamp` bind as `uuid` and
  `timestamptz`, and decode from text or binary, without Foundation.
- Sessions start with `client_encoding` UTF8 and `DateStyle` ISO.

### Redis

- A native driver on the worker's poller. A `RedisPool` per worker, built by
  `app.state`, with an acquire timeout like PostgreSQL's.
- HELLO 3 with the credentials and client name, so replies are RESP3; a server
  without HELLO is spoken to in RESP2 with AUTH. Valkey works the same. TLS is
  required by default and verifies the server's name; ACL users, a database
  other than 0 and unix sockets are configured on `RedisConfiguration`.
- Replies are parsed as they arrive, resuming where the last read ended, and
  held to `maxBulkBytes` and `maxReplyElements`. A reply past either, or one
  that is not RESP, closes the connection.
- Typed commands: `get`, `getBytes`, `set` with expiry and a condition, `del`,
  `exists`, `pexpire`, `pttl`, `incr`, `hset`, `hget`, `hgetall`, `hdel`,
  `lpush`, `rpush`, `lpop`, `rpop`, `lrange`, `sadd`, `srem`, `smembers`,
  `publish`, `getJSON` and `setJSON`. `send` runs any command, and a refusal
  throws `RedisClientError.server` with its code.
- `pipeline` sends commands in one write and returns every reply, refusals
  among them. `transaction` runs MULTI, the commands and EXEC in one round
  trip. `session` holds one connection, for WATCH followed by a transaction
  that returns nil when a watched key changed.
- A connection left in MULTI or WATCH, on another database, or changed by
  CLIENT REPLY, TRACKING or SETNAME is closed rather than handed to the next
  request. An idle connection with input waiting is replaced before use.
- `subscribe(channels:patterns:)` listens on a connection of its own;
  `next(timeoutMilliseconds:)` returns each message, and more channels and
  patterns can be added and removed.
- The reply parser is a `pgfuzz` target, `resp`.

### SQLite

- `SQLiteDatabase`, built by `app.state`: the system's libsqlite3, loaded at
  run time, so building needs no SQLite headers. Where it cannot be loaded,
  opening a database throws `SQLiteClientError.unavailable`.
- Every statement runs on the worker's blocking pool, prepared or taken from
  the connection's cache, stepped to the end and copied out; rows decode into
  `Decodable` types on the worker. `query`, `first`, `execute` and `rows`.
- Each worker has one writer and up to `maxReaders` (4) readers, opened as they
  are needed. A statement moves to a reader once SQLite has said, on the writer,
  that it cannot write. `:memory:` uses the writer alone.
- Files open in write-ahead-log mode with `synchronous=NORMAL` and foreign keys
  enforced, each configurable. Another worker's lock is waited for up to
  `busyTimeoutMilliseconds` (5000) on the blocking thread.
- `transaction` holds the writer from BEGIN IMMEDIATE to COMMIT, so a
  transaction that reads before it writes never fails to upgrade its lock. A
  statement outside it that leaves a transaction open is rolled back and
  refused with `transactionLeftOpen`.
- `migrate` runs the scripts past the database's `user_version` in one
  transaction, once across every worker, and refuses a database migrated by a
  newer program.
- Workers opening a new file at the same moment all start: switching it to
  WAL is retried while another holds the lock, for up to the busy timeout,
  where SQLite itself does not wait.
- SQL holding more than one statement is refused, and results are held to
  `maxRows` and `maxResultBytes`. A refusal carries SQLite's extended code as
  `sqliteCode`, and `isConstraintViolation` says whether a constraint failed.
- `Bool` binds as 0 or 1, `UUID` as text, and `Timestamp` as UTC text of one
  width, `2026-09-17 06:19:31.123456`, which sorts in order and which SQLite's
  date functions read. `UInt` and `UInt64` do not bind.

### Examples

- `Examples/` is a package of applications on the public API, each with tests
  through `app.test`: a todo CRUD API on SQLite; sign-up, login and sessions
  with hashed passwords; server-sent events, a streamed CSV export and uploads
  written to disk as they arrive; chat rooms over WebSockets and event streams,
  heard across every worker; and a file service.
- `swift run files` is that file service, and the shortest path through what
  uploads and downloads need: `app.resumableUploads` for an upload that
  survives a dropped connection, `UploadLimits` at both ends, `Repr-Digest`
  checked before the handler sees the bytes, a name from `Content-Disposition`
  held to what a file name may be, and `--static-dir` serving the store with
  `sendfile`, `ETag`, byte ranges and a listing -- the download side without a
  line of code. Its tests cut an upload off at 120 KB of 200 KB and resume
  it.
- The starter application has roles: an account is a `member` or an `admin`,
  the role rides in the access token, and `/admin/accounts` and
  `PUT /admin/accounts/:id/role` are guarded by two lines --
  `authenticate(jwt:)` and `authorize(jwt:, .admin)` -- with no handler
  checking anything about who is asking. `ADMIN_EMAILS` names the first
  administrators, since a new database has none and a route that promotes
  whoever asks is not a route; the list only promotes, because one that
  demoted would undo an administrator's work at each restart. A change of role
  ends that account's sessions, so the next refresh mints the new role rather
  than waiting out the token. The last administrator cannot be demoted, which
  is a question for the database and answers 409.
- The starter application states its input rules on the types, so a refused
  request names the field, and mounts its notes feature as a `Router`.
  [STARTER.md](Examples/STARTER.md) says how a feature is assembled as an
  application grows: routes as a `Router` when that is all it has, a function
  on `Application` when it also needs per-worker state, start-up work or a
  timer, one migration list, and one value for the shared services.

### Server

- `--static-dir` serves byte ranges. `Range` is answered 206 with
  `Content-Range` on HTTP/1.1, TLS, HTTP/2 and HTTP/3 alike,
  `Accept-Ranges: bytes` goes on every answer, and a range outside the file is
  416 carrying the file's size. The kernel copy takes an offset and the paths
  that read take a seek first, so a range costs what the whole file costs. One
  range per request: a request for several is answered whole, which RFC 9110
  section 14.2 allows, rather than interleaving `multipart/byteranges`
  boundaries with a file being handed to `sendfile`. `If-Range` sends the range
  only while the client's copy is still current, and the whole file when it is
  not.
- `--static-index` answers a request for a `--static-dir` directory with its
  `index.html`, and `--static-listing` lists one that has no index. Both are
  off by default: a directory that is not answered falls through to the
  routes, as an unserved path always has, and a listing tells whoever asks
  every name in the directory. A directory asked for without its trailing
  slash is a 301 to the slash, keeping the query. A listing shows regular
  files and directories, directories first, leaves out names beginning with
  `.`, and carries `Cache-Control: no-store`. It walks one segment at a time
  with `O_NOFOLLOW`, so it cannot leave the tree and a symlinked directory is
  not listed.
- `--compress` compresses handler responses, whoever answered them, with the
  coding the client rates highest. A whole body states its compressed length,
  and a streamed one is compressed as it is written, flushed with each write.
  It says Vary, sends a strong ETag weak, and leaves alone images, event
  streams, bodies the handler encoded, `no-transform`, HEAD and bodies declared
  under `--compress-min-size`.
- `--cache-size` stores handler responses marked fresh in memory every worker
  shares, and answers later GETs and HEADs from them, compressed afresh for
  each client, with 304 for a matching validator. A successful unsafe request
  retires a URL's copies. Responses with cookies, `private`, `no-store` or an
  unusual Vary, and requests with credentials, stay out.
- `--reload` watches the executable. When a rebuild holds still and answers
  `--version`, the supervisor execs it with its listening sockets open and
  replaces the workers one at a time. A changed `--tls-cert` or `--tls-key`
  replaces the workers without an exec.
- `--no-websockets` refuses an upgrade with 501 before anything else answers
  it.
- `--request-start-header` is read by handlers as `request.requestStart`, and
  `--scheme` is the scheme `request.scheme` falls back to.
- No target sets unsafe build flags, so Garuda can be depended on by version.
- The protocol and systems layers moved to
  [aviancore](https://github.com/grepjava/aviancore), a package of their own:
  `CAvian`, `AvianCore`, `AvianHTTP` and `AvianQUIC`, in place of `CGaruda`,
  `GarudaCore`, `GarudaHTTP` and `GarudaQUIC`. Code that imported those modules
  imports the Avian ones, and the C functions are named `av_` instead of `pg_`.
  Their unit tests run in aviancore.
- `GARUDA_UDP_GSO` and `GARUDA_NO_OPENAT2` are now `AVIAN_UDP_GSO` and
  `AVIAN_NO_OPENAT2`.

### Fixed

- A QUIC stream reset before it had sent anything could be forgotten before its
  RESET_STREAM went out, keeping its stream credit until the connection closed.
  A reset side now counts as finished once the reset is sent.
- An HTTPS/1.1 client request to a TLS 1.3 server could fail as `closed` when
  the server's session ticket arrived before its response.

### Not yet

- Middleware cannot wrap a handler's run. The server's own log lines stay
  text under `--log-format json`.
- WebTransport is HTTP/3 only.
- Resumable uploads have no `min-size` or `min-append-size` and no digests,
  and a completed upload is not replayed. A request still appending on
  another worker is waited for briefly, then the new request gets 409 with
  Retry-After. Expired uploads are removed when uploads are created.
- PostgreSQL has no `date`, `time`, `interval`, `numeric` or `json` types of
  its own (they read as text), no `LISTEN`, and no SASLprep for non-ASCII
  passwords.
- SQLite statements cannot be interrupted once on a blocking thread: a request
  cancelled meanwhile finds out when the statement returns. No `sqlite3_backup`,
  custom functions or extensions.
- Redis Cluster and Sentinel are not supported: the driver talks to one
  server. RESP3's streamed strings and aggregates are refused, and no command
  the driver sends is answered with them.
- What each connector does not support yet, Redis Cluster and Sentinel among
  them, and the plan for each, is in CONNECTORS.md.
- TLS over TCP is OpenSSL.
