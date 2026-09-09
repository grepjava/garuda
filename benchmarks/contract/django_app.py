"""Django app matching the-benchmarker/web-frameworks python/django."""

import django
from django.conf import settings
from django.core.handlers.asgi import ASGIHandler
from django.core.handlers.wsgi import WSGIHandler
from django.http import HttpResponse
from django.urls import path

if not settings.configured:
    settings.configure(
        DEBUG=False,
        SECRET_KEY="bench",
        ROOT_URLCONF=__name__,
        ALLOWED_HOSTS=["*"],
        MIDDLEWARE=[],
        INSTALLED_APPS=[],
        USE_I18N=False,
        USE_TZ=False,
    )
    django.setup()


def index(request):
    return HttpResponse(status=200)


def get_user(request, id):
    return HttpResponse(id)


def create_user(request):
    return HttpResponse(status=200)


urlpatterns = [
    path("", index),
    path("user/<int:id>", get_user),
    path("user", create_user),
]

application = WSGIHandler()
app = ASGIHandler()
