FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MEDIA_ROOT=/app/media

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN python manage.py collectstatic --noinput \
    && adduser --disabled-password --gecos "" appuser \
    && mkdir -p /app/media \
    && chown -R appuser:appuser /app/media

USER appuser

EXPOSE 16136

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:16136/', timeout=4)" || exit 1

CMD ["python", "manage.py", "runserver", "0.0.0.0:16136"]
