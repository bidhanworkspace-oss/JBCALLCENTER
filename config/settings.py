import os
from pathlib import Path

from login.clssecurity import clsSecurity

BASE_DIR = Path(__file__).resolve().parent.parent

ROOT_URLCONF = 'config.urls'

WSGI_APPLICATION = 'config.wsgi.application'


STATIC_URL = 'static/'
STATICFILES_DIRS = [
    BASE_DIR / 'static',          
]
STATIC_ROOT = BASE_DIR / 'staticfiles'

SESSION_ENGINE = 'django.contrib.sessions.backends.signed_cookies'
SECRET_KEY = '4u1u!1qno6nhz6#e3dyq(^v3om1og1@eqj%j@p-a1vow)yl=hz'

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'login',  
    'ticket',  
]

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'


TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [os.path.join(BASE_DIR, 'templates')],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

#Oracle App Connection
EJANATA_USER = 'SkJDQUxMQ0VOVEVS'
EJANATA_PASSWORD = 'SmIxMjM0Kg=='
EJANATA_HOST = 'MTcyLjE4LjE4LjE2Ng=='
EJANATA_PORT = 'MTUyMQ=='
EJANATA_SCHEMA = 'SkJQQVk='
EJANATA_USER_SCHEMA = 'SkJDQUxMQ0VOVEVSLg=='

# Database connections are now created directly using API.dbConnectionEJanataStr()
# (see login.api.API.dbConnectionEJanataStr). The Django DATABASES setting is no
# longer required for Oracle access here.
DATABASES = {}


def _env_int(name, default):
    try:
        value = int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


DB_CALL_TIMEOUT = _env_int('DB_CALL_TIMEOUT', 30)
DB_CONNECT_TIMEOUT = _env_int('DB_CONNECT_TIMEOUT', 10)

MEDIA_URL = '/media/'
MEDIA_ROOT = os.environ.get('MEDIA_ROOT') or str(BASE_DIR.parent / 'media')
os.makedirs(MEDIA_ROOT, exist_ok=True)

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'login.middleware.ForcePasswordChangeMiddleware',  
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'login.middleware.UserSessionStateMiddleware',  
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
    'login.middleware.NoCacheAuthenticatedMiddleware',  
    'login.middleware.AuditTrailMiddleware',  
]


MAIL_API_APILINK = os.environ.get(
    'MAIL_API_APILINK',
    'aHR0cDovL2liYW5raW5ndWF0LmpiLmNvbS5iZDo1MDQw',
)

MAIL_API_SOLUTIONINFOID = os.environ.get('MAIL_API_SOLUTIONINFOID', '1')
MAIL_API_SOLUTIONCODE = os.environ.get('MAIL_API_SOLUTIONCODE', 'JB0001')
MAIL_API_TIMEOUT = int(os.environ.get('MAIL_API_TIMEOUT', '30'))




EJANATA_APILINK = os.environ.get(
    'EJANATA_APILINK',
    'aHR0cDovL2liYW5raW5ndWF0LmpiLmNvbS5iZDo1MDQw',
)

#EJANATA_APILINK = os.environ.get('EJANATA_APILINK')


EJANATA_ACC_STATEMENT_ENDPOINT = os.environ.get('EJANATA_ACC_STATEMENT_ENDPOINT', '')


EJANATA_UPDATE_USER_SOLUTIONINFOID = os.environ.get(
    'EJANATA_UPDATE_USER_SOLUTIONINFOID', 'NA==',
)
EJANATA_UPDATE_USER_SOLUTIONCODE = os.environ.get(
    'EJANATA_UPDATE_USER_SOLUTIONCODE', 'SkIwMDA0',
)

EJANATA_API_TIMEOUT = int(os.environ.get('EJANATA_API_TIMEOUT', '30'))

DEBUG = True
ALLOWED_HOSTS = [h.strip() for h in os.environ.get(
    'ALLOWED_HOSTS',
    '127.0.0.1,localhost,callcenter.jb.com.bd'
).split(',') if h.strip()]

CSRF_TRUSTED_ORIGINS = [
    'http://127.0.0.1', 'http://localhost',
    'http://127.0.0.1:16136', 'http://localhost:16136',
] + [o for o in os.environ.get('CSRF_TRUSTED_ORIGINS', '').split(',') if o]

EJANATASOLUTIONCODE = 'SkIwMDAx'
EJANATASOLUTIONINFOID ='MQ=='
ACCESSSOLKEY = 'bWlBUE1xa1U1WTVtMGtvVE5HeFZjbHpqbjhCVUpnWnJIckxLc0ZrMWNCWm01QXBrUXE2L1ZaNXlTdW03UXo4VjJTbzlTUlplQ1M0VGtGbnJwTTlKOXc9PQ=='
