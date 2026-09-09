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
