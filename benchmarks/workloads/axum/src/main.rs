// The requests benchmarks/workloads.sh measures, written as an axum
// application would write them:
//
//   GET  /user/{id}  the path parameter, as text
//   POST /json       an Order decoded, and a Receipt encoded
//   GET  /db/{id}    one row from PostgreSQL, as JSON
//   GET  /stream     64 KiB written as 16 chunks of 4 KiB
//   GET  /me         an HS256 bearer token verified, and its subject answered
//   POST /upload     a body read whole, and its length answered
//   GET  /download   1 MiB answered from memory
//   GET  /relay      ORIGIN_URL fetched and streamed on as it arrives
//
// benchmarks/workloads/garuda-app answers the same requests with the same bytes.
// DATABASE_URL names the database; the script makes the table. Listens on
// 0.0.0.0:3000 with Tokio's default of a worker thread per CPU.

use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use bytes::Bytes;
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde::{Deserialize, Serialize};
use std::convert::Infallible;
use std::sync::Arc;

/// The secret the script signs its token with.
const SECRET: &[u8] = b"workloads-benchmark-secret-0123456789abcdef";

#[derive(Clone)]
struct AppState {
    pool: Pool,
    http: reqwest::Client,
    origin: Arc<str>,
    key: Arc<DecodingKey>,
    validation: Arc<Validation>,
}

#[derive(Deserialize)]
struct Claims {
    sub: String,
    #[allow(dead_code)]
    exp: u64,
}

#[derive(Deserialize)]
struct Order {
    id: i64,
    name: String,
    tags: Vec<String>,
}

#[derive(Serialize)]
struct Receipt {
    id: i64,
    name: String,
    tags: Vec<String>,
    count: usize,
}

#[derive(Serialize)]
struct Item {
    id: i32,
    name: String,
    price: i32,
}

static CHUNK: [u8; 4096] = [b'x'; 4096];
static BLOB: [u8; 1 << 20] = [b'y'; 1 << 20];

async fn user(Path(id): Path<String>) -> String {
    id
}

async fn json(Json(order): Json<Order>) -> Json<Receipt> {
    let count = order.tags.len();
    Json(Receipt { id: order.id, name: order.name, tags: order.tags, count })
}

async fn db(Path(id): Path<i32>, State(state): State<AppState>) -> Response {
    let client = match state.pool.get().await {
        Ok(client) => client,
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    };
    // Prepared once per connection and cached, as Garuda's pool does.
    let statement = match client
        .prepare_cached("select id, name, price from bench_items where id = $1")
        .await
    {
        Ok(statement) => statement,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    match client.query_opt(&statement, &[&id]).await {
        Ok(Some(row)) => Json(Item { id: row.get(0), name: row.get(1), price: row.get(2) }).into_response(),
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn stream() -> Response {
    let chunks = futures_util::stream::iter(
        (0..16).map(|_| Ok::<Bytes, Infallible>(Bytes::from_static(&CHUNK))),
    );
    ([(header::CONTENT_TYPE, "application/octet-stream")], Body::from_stream(chunks)).into_response()
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    let Some(token) = token else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    match jsonwebtoken::decode::<Claims>(token, &state.key, &state.validation) {
        Ok(data) => format!("user {}", data.claims.sub).into_response(),
        Err(_) => StatusCode::UNAUTHORIZED.into_response(),
    }
}

async fn upload(body: Bytes) -> String {
    body.len().to_string()
}

async fn download() -> Response {
    ([(header::CONTENT_TYPE, "application/octet-stream")], Bytes::from_static(&BLOB)).into_response()
}

async fn spin(Path(n): Path<u64>) -> String {
    let mut hash: u64 = 1_469_598_103_934_665_603;
    for i in 0..n {
        hash = (hash ^ (i & 0xff)).wrapping_mul(1_099_511_628_211);
    }
    hash.to_string()
}

async fn relay(State(state): State<AppState>) -> Response {
    match state.http.get(&*state.origin).send().await {
        Ok(upstream) => (
            [(header::CONTENT_TYPE, "application/octet-stream")],
            Body::from_stream(upstream.bytes_stream()),
        )
            .into_response(),
        Err(_) => StatusCode::BAD_GATEWAY.into_response(),
    }
}

#[tokio::main]
async fn main() {
    let url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://garuda:garuda-secret@127.0.0.1:5432/bench?sslmode=disable".into());
    // Garuda runs four workers with eight connections each; this is the same
    // 32 in one pool.
    let size: usize = std::env::var("POOL_SIZE").ok().and_then(|s| s.parse().ok()).unwrap_or(32);
    let config: tokio_postgres::Config = url.parse().expect("DATABASE_URL");
    let manager = Manager::from_config(
        config,
        tokio_postgres::NoTls,
        ManagerConfig { recycling_method: RecyclingMethod::Fast },
    );
    let pool = Pool::builder(manager).max_size(size).build().expect("pool");
    let origin: Arc<str> = std::env::var("ORIGIN_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:3001/stream".into())
        .into();
    let state = AppState {
        pool,
        http: reqwest::Client::new(),
        origin,
        key: Arc::new(DecodingKey::from_secret(SECRET)),
        validation: Arc::new(Validation::new(Algorithm::HS256)),
    };

    let router = Router::new()
        .route("/user/{id}", get(user))
        .route("/json", post(json))
        .route("/db/{id}", get(db))
        .route("/stream", get(stream))
        .route("/me", get(me))
        .route("/upload", post(upload))
        .route("/download", get(download))
        .route("/relay", get(relay))
        .route("/spin/{n}", get(spin))
        // Garuda's --max-body default.
        .layer(DefaultBodyLimit::max(16 << 20))
        .with_state(state);

    let cert = std::env::var("TLS_CERT").unwrap_or_default();
    let key = std::env::var("TLS_KEY").unwrap_or_default();
    if !cert.is_empty() && !key.is_empty() {
        let tls = axum_server::tls_rustls::RustlsConfig::from_pem_file(cert, key)
            .await
            .expect("TLS_CERT and TLS_KEY");
        let addr: std::net::SocketAddr = "0.0.0.0:3000".parse().unwrap();
        axum_server::bind_rustls(addr, tls).serve(router.into_make_service()).await.unwrap();
        return;
    }
    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, router).await.unwrap();
}
