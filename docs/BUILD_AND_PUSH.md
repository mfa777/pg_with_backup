# Build & Push images using GitHub Actions

This repository contains a GitHub Actions workflow that builds and pushes Docker images to Docker Hub when commits are pushed to the `master` branch.

## What the workflow does
- On push to `master`, it builds two images:
  - `Dockerfile.postgres-walg` → `DOCKERHUB_USERNAME/pg-with-backup` (tags: `latest`, `commit-sha`)
  - `Dockerfile.backup` → `DOCKERHUB_USERNAME/pg-backup-walg` (tags: `latest`, `commit-sha`)
- Pushes the images to Docker Hub using the provided credentials.

## Required GitHub repository secrets
Add the following secrets in your repository settings -> Secrets -> Actions:
- `DOCKERHUB_USERNAME` — your Docker Hub username (or organization)
- `DOCKERHUB_TOKEN` — a Docker Hub access token or password

## How to use the pushed images (start with only `.env` and `docker-compose.yml`)
1. Option A (recommended): modify `docker-compose.yml` to use the pushed images instead of building locally. Example change:

   services:
     postgres:
-      build:
-        context: .
-        dockerfile: Dockerfile.postgres-walg
+      image: <DOCKERHUB_USERNAME>/pg-with-backup:latest

     backup:
-      build:
-        context: .
-        dockerfile: Dockerfile.backup
+      image: <DOCKERHUB_USERNAME>/pg-backup-walg:latest

2. After updating `docker-compose.yml` (or using a version that already references the remote images), deploy on any host with Docker engine and `docker compose`:

```bash
# Ensure .env is present in the same directory as docker-compose.yml
# Create external volume if required by compose (the repository's compose uses an external named volume for pg_data):
docker volume create --name postgres-data

docker compose up -d
```

Notes:
- If you don't want the external volume requirement, edit `docker-compose.yml` to remove `external: true` for `pg_data`.
- If you need an SSH test server, either enable the `ssh-testing` profile and provide the SSH public key at the path referenced by `SSH_KEY_PATH`, or set `WALG_SSH_PRIVATE_KEY` in `.env` (base64-encoded) and avoid mounting host keys.

## Customizing image names/tags
- The workflow uses `${{ secrets.DOCKERHUB_USERNAME }}` as the user/org for image tags. If you prefer different names, update `.github/workflows/build-and-push.yml`.

## Troubleshooting
- Build may fail if GitHub runners cannot reach the wal-g binary release or if the pgvector build step fails; check Actions logs for the failing step.
- If you want multi-arch images, extend the action with `platforms` in the `docker/build-push-action` steps.

---
If you want, I can also apply the `docker-compose.yml` edits that replace the `build:` sections with `image:` lines and add comments to document the external volume requirement. Would you like me to apply that patch now?