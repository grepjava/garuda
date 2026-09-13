"""The contract Flask app, with every response marked fresh for shared caches.

The same routes and bodies as benchmarks/contract/flask_app.py, plus
`Cache-Control: public, s-maxage=60`, so that --cache-size has something it
may keep. Used to measure the cache, not to compare frameworks.
"""

from flask import Flask

app = Flask(__name__)
FRESH = {"Cache-Control": "public, s-maxage=60"}


@app.route("/")
def index():
    return "", 200, FRESH


@app.route("/user/<int:id>")
def get_user(id):
    return str(id), 200, FRESH


@app.route("/user", methods=["POST"])
def create_user():
    return ""
