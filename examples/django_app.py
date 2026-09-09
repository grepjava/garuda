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


def proto(request):
    """What carried this request, and what else this connection could do.

    The view is identical whether it was reached over HTTP/1.1, HTTP/2 or
    HTTP/3 -- which is the point. Only the answer changes.
    """
    from peregrine.contrib.django import http_version, is_http3, supports_webtransport
    return JsonResponse({
        "http_version": http_version(request),
        "http3": is_http3(request),
        "scheme": request.scheme,
        "webtransport": supports_webtransport(request),
    })


urlpatterns = [
    path("", index),
    path("echo", echo),
    path("stream", stream),
    path("sleep", sleep),
    path("boom", boom),
    path("proto", proto),
]

import django

django.setup()
application = WSGIHandler()


# --- ASGI: HTTP, WebSocket and WebTransport in one application ---------------
#
# Django's ASGI handler asserts scope["type"] == "http", which rules out two
# things at once: it will not route a WebSocket, and it will not route a
# WebTransport session. Both answers have the same shape -- something in front
# of Django that owns the scope types Django does not. Channels does the first,
# peregrine.contrib.django the second, and they compose.
#
#   application       the WSGI entry point above, unchanged
#   asgi_application  HTTP + WebSocket + WebTransport, over any HTTP version

from django.core.asgi import get_asgi_application  # noqa: E402

from peregrine.contrib.django import WebTransportRouter  # noqa: E402

django_asgi = get_asgi_application()

try:
    from channels.generic.websocket import AsyncWebsocketConsumer
    from channels.routing import ProtocolTypeRouter, URLRouter
except ImportError:
    # Channels is optional. Without it Django serves HTTP and WebTransport,
    # and a WebSocket upgrade gets a 404 from the router rather than a crash.
    http_and_websocket = django_asgi
else:

    class EchoConsumer(AsyncWebsocketConsumer):
        async def connect(self):
            await self.accept()

        async def receive(self, text_data=None, bytes_data=None):
            if text_data is not None:
                await self.send(text_data="echo:" + text_data)
            else:
                await self.send(bytes_data=b"echo:" + bytes_data)

    websocket_urlpatterns = [path("ws", EchoConsumer.as_asgi())]

    http_and_websocket = ProtocolTypeRouter({
        "http": django_asgi,
        "websocket": URLRouter(websocket_urlpatterns),
    })

asgi_application = WebTransportRouter(http_and_websocket)


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
