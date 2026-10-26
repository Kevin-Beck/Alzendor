FROM python:3.13-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN useradd --system --no-create-home alzendor
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# `docker compose run --rm test` runs the test suite against the compose Redis.
FROM base AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY . .
USER alzendor
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider"]

FROM base AS runtime
COPY alzendor ./alzendor
COPY world ./world
USER alzendor
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"
CMD ["python", "-m", "alzendor"]
