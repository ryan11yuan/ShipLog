FROM python:3.13-slim

# No .pyc files; flush output immediately so logs reach Log Analytics without delay
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

RUN useradd --system --uid 10001 shiplog
WORKDIR /srv

# Dependencies first: this layer is cached until requirements.txt changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Only the app code, never the whole folder (which holds tfstate and tfvars)
COPY app/ app/

# Set late so a new commit SHA doesn't invalidate the cached layers above
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

# Numeric UID so Kubernetes can verify "not root" without reading /etc/passwd
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
