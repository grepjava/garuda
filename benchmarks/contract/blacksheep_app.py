"""BlackSheep app matching the-benchmarker/web-frameworks python/blacksheep/server.py."""

from blacksheep.server import Application
from blacksheep.server.responses import Response, text

app = Application()


@app.router.get("/")
async def home(_) -> Response:
    return text("")


@app.router.get("/user/:id")
async def user_info(_, id: int) -> Response:
    return text(f"{id}")


@app.router.post("/user")
async def user(_) -> Response:
    return text("")
