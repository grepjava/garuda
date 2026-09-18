// The four requests benchmarks/workloads.sh measures, written as an axum
// application would write them:
//
//   GET  /user/{id}  the path parameter, as text
//   POST /json       an Order decoded, and a Receipt encoded
//   GET  /db/{id}    one row from PostgreSQL, as JSON
//   GET  /stream     64 KiB written as 16 chunks of 4 KiB
//
// benchmarks/workloads/garuda-app answers the same requests with the same bytes.
// DATABASE_URL names the database; the script makes the table. Listens on
// 0.0.0.0:3000 with Tokio's default of a worker thread per CPU.

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use bytes::Bytes;
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use serde::{Deserialize, Serialize};
use std::convert::Infallible;

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

async fn user(Path(id): Path<String>) -> String {
    id
}

async fn json(Json(order): Json<Order>) -> Json<Receipt> {
    let count = order.tags.len();
    Json(Receipt { id: order.id, name: order.name, tags: order.tags, count })
}

async fn db(Path(id): Path<i32>, State(pool): State<Pool>) -> Response {
    let client = match pool.get().await {
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

    let router = Router::new()
        .route("/user/{id}", get(user))
        .route("/json", post(json))
        .route("/db/{id}", get(db))
        .route("/stream", get(stream))
        .with_state(pool);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, router).await.unwrap();
}
