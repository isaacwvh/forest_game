FROM python:3.12-slim
ARG FOREST_RELEASE_COMMIT=unknown
LABEL org.opencontainers.image.revision=$FOREST_RELEASE_COMMIT
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY requirements.lock pyproject.toml ./
RUN python -m pip install --no-cache-dir -r requirements.lock
COPY src ./src
COPY alembic.ini ./
COPY migrations ./migrations
COPY scripts/configure_supabase_runtime.py scripts/cloud.py scripts/smoke_hosted.py ./scripts/
RUN python -m pip install --no-deps . && useradd --create-home --uid 10001 forest
USER forest
EXPOSE 8000
CMD ["uvicorn", "forest_api.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
