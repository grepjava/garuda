use ntex::web::{self, App, HttpResponse};

async fn root() -> HttpResponse {
    HttpResponse::Ok().finish()
}

async fn post_user() -> HttpResponse {
    HttpResponse::Ok().finish()
}

async fn get_user(id: web::types::Path<String>) -> String {
    id.into_inner()
}

#[ntex::main]
async fn main() -> std::io::Result<()> {
    web::server(|| {
        App::new()
            .route("/", web::get().to(root))
            .route("/user", web::post().to(post_user))
            .route("/user/{id}", web::get().to(get_user))
    })
    .bind(("0.0.0.0", 3000))?
    .run()
    .await
}
