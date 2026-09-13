"""The contract FastAPI app, with every response marked fresh for shared caches.

The same routes and bodies as benchmarks/contract/fastapi_app.py, plus
`Cache-Control: public, s-maxage=60`, so that --cache-size has something it
may keep. Used to measure the cache, not to compare frameworks.
"""

from fastapi import FastAPI
from starlette.responses import PlainTextResponse

app = FastAPI()
FRESH = {"Cache-Control": "public, s-maxage=60"}


@app.get("/")
async def index():
    return PlainTextResponse(content="", headers=FRESH)


@app.get("/user/{id}")
async def get_user(id: int):
    return PlainTextResponse(content=f"{id}".encode(), headers=FRESH)


@app.post("/user")
async def create_user():
    return PlainTextResponse(content="")
