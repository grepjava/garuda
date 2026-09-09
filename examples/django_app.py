"""A single-file Django project, to check the WSGI path against a real framework."""

import os
import sys
import time

from django.conf import settings
from django.core.handlers.wsgi import WSGIHandler
from django.http import HttpResponse, JsonResponse, StreamingHttpResponse
from django.urls import path

settings.configure(
    DEBUG=False,
    SECRET_KEY="only-for-a-compatibility-test",
    ALLOWED_HOSTS=["*"],
    ROOT_URLCONF=__name__,
    MIDDLEWARE=[
        "django.middleware.common.CommonMiddleware",
    ],
    DATABASES={},
    USE_TZ=True,
)


def index(request):
    return JsonResponse({
        "hello": "peregrine",
        "scheme": request.scheme,
        "remote": request.META.get("REMOTE_ADDR"),
        "secure": request.is_secure(),
        "multithread": request.META.get("wsgi.multithread"),
    })


def echo(request):
    return HttpResponse(request.body, content_type="application/octet-stream")


def stream(request):
    def produce():
        for i in range(5):
            yield b"chunk-%d\n" % i

    return StreamingHttpResponse(produce(), content_type="text/plain")


def sleep(request):
    time.sleep(float(request.GET.get("s", "0.5")))
    return HttpResponse(b"slept\n")


def boom(request):
    raise RuntimeError("intentional django failure")


urlpatterns = [
    path("", index),
    path("echo", echo),
    path("stream", stream),
    path("sleep", sleep),
    path("boom", boom),
]

import django

django.setup()
application = WSGIHandler()


# --- ASGI, with WebTransport ------------------------------------------------
#
# Django's ASGI handler asserts scope["type"] == "http", so a session has to be
# answered before it gets there. `asgi_application` is what to serve when you
# want both; `application` above stays the WSGI entry point.

from django.core.asgi import get_asgi_application  # noqa: E402

from peregrine.contrib.django import WebTransportRouter  # noqa: E402

asgi_application = WebTransportRouter(get_asgi_application())


@asgi_application.route("wt/echo")
async def wt_echo(session):
    await session.accept()
    async for stream in session.incoming_streams():
        body = await stream.read()
        if stream.bidirectional:
            await stream.send(b"echo:" + body, end=True)
        else:
            reply = await session.create_stream(bidirectional=False)
            await reply.send(b"echo:" + body, end=True)


@asgi_application.route("wt/room/<str:name>/")
async def wt_room(session):
    await session.accept()
    name = session.path_params["name"].encode()
    stream = await session.create_stream(bidirectional=False)
    await stream.send(b"welcome to " + name, end=True)
    async for _ in session.incoming_streams():
        pass


@asgi_application.route("wt/n/<int:count>/")
async def wt_count(session):
    await session.accept()
    count = session.path_params["count"]
    stream = await session.create_stream(bidirectional=False)
    await stream.send(("n=%d" % count).encode(), end=True)
    async for _ in session.incoming_streams():
        pass
