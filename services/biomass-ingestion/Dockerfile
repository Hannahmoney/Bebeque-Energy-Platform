FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.12-slim AS runtime

RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app

COPY --from=builder /install /usr/local

COPY app/ ./app/

USER appuser

# Workers have no port to expose — they make outbound
# connections to SQS and PostgreSQL, nobody connects to them.
# No EXPOSE, no port mapping needed.

# The entrypoint runs the worker module directly.
# python -m app.worker means "run app/worker.py as a module."
CMD ["python", "-m", "app.worker"]