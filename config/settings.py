import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

ROOT_URLCONF = 'config.urls'

# 2. Set the static files URL
STATIC_URL = 'static/'
STATICFILES_DIRS = [
    BASE_DIR / 'static',          # ← This is important
]
SESSION_ENGINE = 'django.contrib.sessions.backends.signed_cookies'
SECRET_KEY = '4u1u!1qno6nhz6#e3dyq(^v3om1og1@eqj%j@p-a1vow)yl=hz'
# 1. Register App
INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'login',  # Authentication & admin application module
    'ticket',  # Ticket management application module
]

# 2. Configure Templates Directory
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

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.oracle',
        'NAME': '172.18.18.166:1521/JBPAY',
        'USER': 'JBCALLCENTER',
        'PASSWORD': 'Jb1234*',
    }
}
# 3. Media Files Configuration (For JPG Attachments)
MEDIA_URL = '/media/'
MEDIA_ROOT = os.path.join(BASE_DIR, 'media')

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'login.middleware.ForcePasswordChangeMiddleware',  # Lock first-login users to the change-password page only
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
    'login.middleware.NoCacheAuthenticatedMiddleware',  # Prevent caching of authenticated pages
    'login.middleware.AuditTrailMiddleware',  # Register Custom Audit Logging Middleware
]

# 4. Email Engine Settings (Update with real SMTP credentials)
EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
EMAIL_HOST = 'smtp.gmail.com'
EMAIL_PORT = 587
EMAIL_USE_TLS = True
EMAIL_USE_SSL = False
EMAIL_HOST_USER = 'bidhan.workspace@gmail.com'
EMAIL_HOST_PASSWORD = 'eibhkstioxbkltlz'
DEFAULT_FROM_EMAIL = 'JB Call Center <bidhan.workspace@gmail.com>'

DEBUG = True
ALLOWED_HOSTS = ['127.0.0.1', 'localhost']