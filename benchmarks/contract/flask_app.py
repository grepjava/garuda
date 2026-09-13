"""Flask app matching the-benchmarker/web-frameworks python/flask/server.py."""

from flask import Flask

app = Flask(__name__)


@app.route("/")
def index():
    return ""


@app.route("/user/<int:id>")
def get_user(id):
    return str(id)


@app.route("/user", methods=["POST"])
def create_user():
    return ""
