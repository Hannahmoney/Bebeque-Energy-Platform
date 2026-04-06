# ── Stage 1: builder ──────────────────────────────────────────
# We use a two-stage build. The first stage installs dependencies
# and compiles anything that needs compiling. The second stage
# copies only what is needed to run the app — not the build tools.
# The final image is smaller and has a smaller attack surface.
# Teams call this a "multi-stage build."
FROM python:3.12-slim AS builder

# Set the working directory inside the container.
# All subsequent commands run from here.
WORKDIR /app

# Copy requirements first — before copying any application code.
# Why: if requirements.txt has not changed, Docker reuses the
# cached pip install layer even if your code has changed.
# This is the most important layer caching trick in Python Dockerfiles.
COPY requirements.txt .

# Install dependencies into a specific directory we can copy later.
# --no-cache-dir tells pip not to cache downloaded packages
# inside the image — reduces image size.
# --prefix installs into /install so we can copy it cleanly.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Stage 2: runtime ──────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Security best practice: never run as root inside a container.
# Create a non-root user called "appuser".
# Teams call this "running as a non-root user" or "least privilege."
# If an attacker exploits your app, they get appuser permissions,
# not root permissions.
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app

# Copy installed Python packages from the builder stage.
# Nothing else from the builder comes with it — not pip,
# not the build cache, not any temporary files.
COPY --from=builder /install /usr/local

# Copy application code.
# This layer changes every time you change your code.
# It is last because frequent changes should invalidate
# as few cached layers as possible.
COPY app/ ./app/

# Switch to the non-root user before the container starts.
USER appuser

# Document which port the application listens on.
# EXPOSE does not actually open the port — it is documentation.
# Kubernetes opens the port via the Service configuration.
EXPOSE 8000

# Tell Docker how to start the application.
# We use the JSON array form (exec form) rather than a shell string.
# Exec form means the process runs directly without a shell wrapper,
# so SIGTERM from Kubernetes reaches the application directly.
# Teams call this "signal propagation" — critical for graceful shutdown.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]