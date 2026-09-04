# Kitesurf Booking Calendar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a self-hosted cal.diy booking calendar for Nacho Ibáñez's kitesurf classes at `clases.rburdet.com`, running on the existing Hetzner VPS behind a Cloudflare Tunnel, with admin access gated by Cloudflare Access.

**Architecture:** Docker Compose stack (Postgres + cal.diy web app + cloudflared) on the Hetzner VPS. Cloudflare Tunnel exposes the app with no inbound firewall ports; Cloudflare Access gates the admin/dashboard paths behind an email-OTP allowlist while the public booking pages stay open. Nightly Postgres dumps are copied to Cloudflare R2.

**Tech Stack:** cal.diy v6.2.0 (Next.js/Prisma/Postgres, MIT), Docker Compose, cloudflared, Cloudflare Access + R2, Resend (SMTP relay), rclone.

**Spec:** `docs/booking-design.md`

## Global Constraints

- Self-hosted only — no cal.com/cal.diy managed/cloud product, no Vercel.
- No online payment collection — event type prices are informational text only.
- Availability is a fixed recurring weekly schedule; Nacho blocks individual dates manually.
- Admin access has no separate password login of its own beyond Cloudflare Access OTP + cal.diy's built-in auth — the two allowlisted emails are Rodrigo's and Nacho's.
- Public booking pages (`/<username>`, `/<username>/<event-slug>`, `/booking/<uid>`) must never sit behind Cloudflare Access — only Nacho/Rodrigo hit an Access wall, students never do.
- Subdomain: `clases.rburdet.com`. Repo: `github.com/rburdet/nachoibanez-booking` (already created, public, `main` branch).
- cal.diy application source is a pinned upstream dependency (tag `v6.2.0`), not vendored into this repo's git history.
- **Revised during implementation (2026-09-04):** the `calcom` image is built in CI (`.github/workflows/build-calcom-image.yml`) and pulled from GHCR, not built on the VPS. A real build attempt on the VPS drove memory usage to ~3GB used + 3.1GB of 4GB swap and measurably degraded another production service (`guardias`) sharing the box, before Turbopack's compile step even started. The VPS has only 2 vCPUs / 4GB RAM shared with other live services — insufficient headroom for this monorepo's build. See Task 3 for the CI-build approach.

---

## Task 1: VPS baseline — Docker, swap, deploy directory

The cal.diy image builds from source (multi-stage Next.js/Prisma build) — no maintained prebuilt image exists on Docker Hub or GHCR (verified: both registries return empty/unknown for `calcom/cal.diy`). On a 4GB VPS shared with other services, that build can be memory-hungry enough to risk an OOM kill. A swap file is cheap insurance.

**Files:**
- Create (on the VPS, not in the repo): `/swapfile`, and an fstab entry for it.

- [x] **Step 1: Check Docker is installed and current**

Run on the VPS:
```bash
docker --version && docker compose version
```
Expected: both print a version (Docker 24+, Compose v2). If either is missing, install Docker per Hetzner's standard `get.docker.com` install script before continuing — do not proceed without this.

Done: Docker 29.8.0, Compose v5.5.1. `rburdet` added to the `docker` group; `docker ps` runs without `sudo` after re-logging in.

- [x] **Step 2: Check current memory and swap**

```bash
free -h
```
Expected: ~4GB total RAM. Note how much is already used by other services running on the box.

Done: 3.7Gi total RAM.

- [x] **Step 3: Add a 2GB swap file (skip if swap already present and >= 2GB)**

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

- [x] **Step 4: Verify swap is active**

```bash
swapon --show
```
Expected: lists `/swapfile` with size 2G.

Done: `/swapfile` active, 2G.

- [x] **Step 5: Deploy directory**

The repo is already cloned at `/home/rburdet/nachoibanez-booking` (this working directory) — used as the deploy directory in place of `/opt/nachoibanez-booking` from the original spec. No further action needed for this step.

No commit for this task — it's VPS-side setup, not a repo change.

---

## Task 2: docker-compose.yml + .env.example

**Files:**
- Create: `docker-compose.yml`
- Create: `.env.example`
- Modify: `.gitignore` (add `vendor/`)

**Interfaces:**
- Produces: the `stack` Docker network and service names `database`, `calcom`, `cloudflared` that later tasks attach to and exec into.
- Consumes: `vendor/cal.diy` as the build context for the `calcom` service (populated by Task 1's sibling script in Task 4, not this task).

- [x] **Step 1: Add `vendor/` to `.gitignore`**

```
.env
*.env.local
backups/
node_modules/
vendor/
```

- [x] **Step 2: Write `docker-compose.yml`**

Only two of upstream cal.diy's five services are needed: `database` and `calcom` (the web app). `redis`, `calcom-api` (the v2 public API) and `studio` (Prisma Studio) are exclusively used by the v2 API service — nothing here calls the v2 API, so they're dropped (confirmed: `redis` and `calcom-api`-only env vars never appear in cal.diy's own `.env.example`).

```yaml
volumes:
  database-data:

networks:
  stack:
    name: stack
    external: false

services:
  database:
    container_name: database
    image: postgres:16
    restart: unless-stopped
    volumes:
      - database-data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    networks:
      - stack

  calcom:
    container_name: calcom
    # Built in CI (.github/workflows/build-calcom-image.yml), pulled here — see
    # the revision note in Global Constraints for why this isn't built on the VPS.
    image: ghcr.io/rburdet/nachoibanez-booking-calcom:v6.2.0
    restart: unless-stopped
    shm_size: '1gb'
    networks:
      - stack
    ports:
      - "3000:3000"
    env_file: .env
    environment:
      - DATABASE_HOST=database
      - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@database/${POSTGRES_DB}
      - DATABASE_DIRECT_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@database/${POSTGRES_DB}
    depends_on:
      - database

  cloudflared:
    container_name: cloudflared
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    networks:
      - stack
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
    depends_on:
      - calcom
```

- [x] **Step 3: Write `.env.example`**

Documents every variable the compose file and cal.diy's `start.sh` entrypoint need, with no real secrets:

```bash
# Postgres
POSTGRES_USER=calcom
POSTGRES_PASSWORD=
POSTGRES_DB=calendso

# cal.diy core
NEXT_PUBLIC_WEBAPP_URL=https://clases.rburdet.com
NEXT_PUBLIC_WEBSITE_URL=https://clases.rburdet.com
NEXT_PUBLIC_EMBED_LIB_URL=https://clases.rburdet.com/embed/embed.js
NEXTAUTH_URL=https://clases.rburdet.com
# Generate with: openssl rand -base64 32
NEXTAUTH_SECRET=
# Generate with: openssl rand -base64 24
CALENDSO_ENCRYPTION_KEY=
CALCOM_TELEMETRY_DISABLED=1
ALLOWED_HOSTNAMES='"clases.rburdet.com"'

# Email — Resend's SMTP relay (nodemailer-compatible, the well-documented path;
# cal.diy's native RESEND_API_KEY var is unverified/experimental upstream).
EMAIL_FROM=reservas@rburdet.com
EMAIL_FROM_NAME=Nacho Ibáñez Kitesurf
EMAIL_SERVER_HOST=smtp.resend.com
EMAIL_SERVER_PORT=465
EMAIL_SERVER_USER=resend
EMAIL_SERVER_PASSWORD=

# Cloudflare Tunnel
CLOUDFLARE_TUNNEL_TOKEN=

# Backups (Task 7)
R2_BUCKET_NAME=
```

- [x] **Step 4: Commit**

```bash
git add docker-compose.yml .env.example .gitignore
git commit -m "Add docker-compose stack and env template for cal.diy"
git push
```

---

## Task 3: Build calcom image in CI + deploy script

**Revised during implementation (2026-09-04).** Originally this task vendored cal.diy source
into `vendor/cal.diy` on the VPS and built the image there with `docker compose up -d --build`.
A real attempt showed the build (`yarn install` alone, before any Next.js compilation) pushes
this 4GB VPS to ~3GB RAM + 3.1GB of 4GB swap used, and measurably degraded the `guardias`
service also running on the box (its `next-server` process went into disk-wait state). The VPS
has only 2 vCPU / 4GB RAM shared with other live services — not enough headroom for this
monorepo's build. Building in CI (ample RAM, isolated) and pulling the finished image instead
avoids the problem entirely and never touches the shared VPS's resources.

**Files:**
- Create: `.github/workflows/build-calcom-image.yml`
- Create: `scripts/deploy.sh`

**Interfaces:**
- Produces: `ghcr.io/rburdet/nachoibanez-booking-calcom:v6.2.0`, consumed by `docker-compose.yml`'s
  `calcom` service (Task 2) and pulled by `scripts/deploy.sh`.

- [x] **Step 1: Write `.github/workflows/build-calcom-image.yml`**

Manually triggered (`workflow_dispatch`) job that checks out `calcom/cal.diy` at the pinned tag,
builds it, and pushes to GHCR using the repo's own `GITHUB_TOKEN` (no extra secrets needed):

```yaml
name: Build and push calcom image

on:
  workflow_dispatch:

env:
  CAL_DIY_TAG: v6.2.0
  IMAGE: ghcr.io/${{ github.repository_owner }}/nachoibanez-booking-calcom

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout cal.diy at pinned tag
        uses: actions/checkout@v4
        with:
          repository: calcom/cal.diy
          ref: ${{ env.CAL_DIY_TAG }}
          path: cal.diy

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: ./cal.diy
          push: true
          tags: ${{ env.IMAGE }}:${{ env.CAL_DIY_TAG }}
          build-args: |
            NEXT_PUBLIC_WEBAPP_URL=https://clases.rburdet.com
```

- [ ] **Step 2: Run the workflow and make the GHCR package public**

In GitHub: **Actions → Build and push calcom image → Run workflow**. Once it finishes, go to the
repo's **Packages** (or `github.com/rburdet?tab=packages`) → `nachoibanez-booking-calcom` →
**Package settings → Change visibility → Public**. This lets the VPS `docker pull` without
authenticating to GHCR.

- [x] **Step 3: Write `scripts/deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# The calcom image is built in CI (.github/workflows/build-calcom-image.yml)
# and published to GHCR — this VPS only pulls it, it never builds the
# Next.js/Prisma monorepo locally (see docker-compose.yml for why).
docker compose pull
docker compose up -d
```

- [x] **Step 4: Make it executable and commit**

```bash
chmod +x scripts/deploy.sh
git add scripts/deploy.sh .github/workflows/build-calcom-image.yml docker-compose.yml
git commit -m "Build calcom image in CI instead of on the VPS"
git push
```

- [ ] **Step 5: Run it on the VPS once the image is public**

```bash
cd /home/rburdet/nachoibanez-booking
git pull
./scripts/deploy.sh
```
Expected: `docker compose pull` fetches the GHCR image without needing a login (package is
public from Step 2); `database` and `calcom` start. `cloudflared` will still fail to find a
token until Task 5 — that's expected at this point.

---

## Task 4: Real secrets + bring the stack up

**Files:**
- Create (on the VPS only, not committed): `.env`

- [x] **Step 1: Generate the two secrets**

```bash
openssl rand -base64 32   # NEXTAUTH_SECRET
openssl rand -base64 24   # CALENDSO_ENCRYPTION_KEY
```

- [x] **Step 2: Create `/home/rburdet/nachoibanez-booking/.env` from `.env.example`**

Copy `.env.example` to `.env` and fill in:
- `POSTGRES_PASSWORD` — a fresh random value (e.g. `openssl rand -hex 24`)
- `NEXTAUTH_SECRET`, `CALENDSO_ENCRYPTION_KEY` — from Step 1
- `EMAIL_SERVER_PASSWORD` — reused the existing Resend account/API key from the `hurabeach`
  project (same machine); `EMAIL_FROM` set to `reservas@emails.rburdet.com` to match that
  account's already-verified sending domain (see `.env.example` comment)
- `CLOUDFLARE_TUNNEL_TOKEN` — set (Task 5 tunnel token, provided ahead of schedule)
- `R2_BUCKET_NAME` — leave blank until Task 8

Done: all of the above are set in `/home/rburdet/nachoibanez-booking/.env` on the VPS.

- [ ] **Step 3: Bring up database + calcom (pulls the image built in Task 3)**

Blocked on Task 3 Step 2 (running the GHCR build workflow + making the package public) — needs
GitHub UI/CLI access this session doesn't have. Once the image is public:

```bash
docker compose pull
docker compose up -d database calcom
```

- [ ] **Step 4: Watch the calcom container come up**

```bash
docker compose logs -f calcom
```
Expected: `wait-for-it.sh` reports the database is up, `prisma migrate deploy` runs and applies migrations, `seed-app-store.ts` runs, then the Next.js server starts listening. This can take several minutes on first build — do not interrupt it.

- [ ] **Step 5: Verify the app answers locally on the VPS**

```bash
curl -sI http://localhost:3000 | head -1
```
Expected: `HTTP/1.1 200 OK` (or a redirect to `/auth/login`).

No commit for this task — nothing here touches the repo.

---

## Task 5: Cloudflare Tunnel + DNS

**Files:** none (Cloudflare dashboard configuration + filling in `.env` on the VPS).

- [ ] **Step 1: Create the tunnel**

In the Cloudflare Zero Trust dashboard: **Networks → Tunnels → Create a tunnel** → choose **Cloudflared** → name it `nachoibanez-booking`. Cloudflare shows a connector install command containing a token — copy just the token value (the long string after `--token`).

- [ ] **Step 2: Add the public hostname route**

Still in the tunnel's setup: **Public Hostname** tab → Add a public hostname:
- Subdomain: `clases`, Domain: `rburdet.com` (i.e. `clases.rburdet.com`)
- Service: `HTTP`, URL: `calcom:3000` (the Docker service name from Task 2, reachable because `cloudflared` shares the `stack` network with `calcom`)

- [ ] **Step 3: Set the token and start cloudflared**

On the VPS, set `CLOUDFLARE_TUNNEL_TOKEN` in `.env` to the token from Step 1, then:
```bash
docker compose up -d cloudflared
docker compose logs cloudflared
```
Expected: logs show `Registered tunnel connection`.

- [ ] **Step 4: Verify the public domain resolves end-to-end**

```bash
curl -sI https://clases.rburdet.com | head -1
```
Expected: `HTTP/1.1 200 OK` (or redirect to login), served with Cloudflare's SSL — no Hetzner IP or open port involved.

No commit for this task — pure Cloudflare/VPS configuration.

---

## Task 6: Cloudflare Access on admin paths only

Access must gate the admin/dashboard surface but never the public booking flow — a mis-scoped policy would lock students out of their own booking confirmation page. Verification below tests both directions explicitly.

**Files:** none (Cloudflare dashboard configuration).

- [ ] **Step 1: Create the Access application**

Zero Trust dashboard: **Access → Applications → Add an application → Self-hosted**.
- Application domain: `clases.rburdet.com`
- Path: add each of these as separate path rules on the same application (Access supports multiple path matches per app): `/auth*`, `/settings*`, `/event-types*`, `/bookings*`, `/teams*`, `/apps*`, `/workflows*`, `/insights*`
- Session duration: 24 hours (reasonable default; adjust later if annoying).

- [ ] **Step 2: Add the policy — email allowlist**

Policy name: `Nacho + Rodrigo`. Action: **Allow**. Include rule: **Emails** — add Rodrigo's and Nacho's exact email addresses. No other identity providers needed; leave Cloudflare's built-in **One-time PIN** as the login method.

- [ ] **Step 3: Verify a non-whitelisted email is blocked**

From a private/incognito browser window, visit `https://clases.rburdet.com/settings/profile`. Expected: Cloudflare Access login page appears, requesting an email. Enter an email NOT on the allowlist — expected: Access denies it (no OTP is even sent, or access is refused after entering the code).

- [ ] **Step 4: Verify a whitelisted email is allowed**

Same URL, enter Rodrigo's or Nacho's email. Expected: Cloudflare emails a one-time code, entering it grants access through to cal.diy's own login page underneath.

- [ ] **Step 5: Verify the public booking page is NOT gated**

From the same private browser window (no Access session), visit `https://clases.rburdet.com/` and whatever public booking URL exists for the seeded user (finalized in Task 7). Expected: loads directly, no Cloudflare Access prompt.

No commit for this task — pure Cloudflare configuration.

---

## Task 7: cal.diy content — account, event types, availability

**Files:** none (configuration inside the running app).

- [ ] **Step 1: Create Nacho's account**

Visit `https://clases.rburdet.com/auth/setup` (or `/auth/signup` if setup already ran) through the Access wall and create the first user account for Nacho — this becomes his cal.diy login, layered behind the Cloudflare Access OTP from Task 6. Note the resulting username (used in the public booking URL, e.g. `https://clases.rburdet.com/nacho`).

- [ ] **Step 2: Set weekly availability**

In **Availability**, edit the default schedule to the fixed weekly hours Nacho wants open every week (e.g. every day 9:00–18:00). This is the recurring schedule from the spec — no per-week toggling.

- [ ] **Step 3: Create the event types**

In **Event Types**, create one entry per class Nacho offers (e.g. "Clase privada", "Clase grupal", "Alquiler de equipo"), each with its own duration and its price written into the event's description field (cal.diy has no payment integration wired here, per spec — price is informational text only).

- [ ] **Step 4: Confirm Rodrigo has admin visibility**

Since cal.diy here runs as a single-user instance (no teams/orgs needed per spec), Rodrigo's access is via the same Cloudflare Access allowlist (Task 6) reaching Nacho's account's dashboard — no second cal.diy user is required unless Rodrigo specifically wants his own separate login; skip creating a second account unless asked.

- [ ] **Step 5: End-to-end booking test**

From a private browser window (simulating a student, no Access session), open the public event URL (e.g. `https://clases.rburdet.com/nacho/clase-privada`), pick a slot, and complete a booking with a real test email. Expected: booking confirmation page loads (and is NOT blocked by Access — confirms Task 6, Step 5 didn't over-scope), and a confirmation email arrives via Resend within a minute or two.

- [ ] **Step 6: Manual date block**

In the dashboard, block out one specific date (e.g. via **Availability → Troubleshoot/Out of office** or blocking that date directly). Reload the public booking page for that date. Expected: no slots are offered for the blocked date.

No commit for this task — nothing here is repo content.

---

## Task 8: Backups to Cloudflare R2

**Files:**
- Create: `scripts/backup.sh`

**Interfaces:**
- Consumes: `POSTGRES_USER`, `POSTGRES_DB`, `R2_BUCKET_NAME` from `.env` (Task 2/4).

- [ ] **Step 1: Create the R2 bucket and API token**

Cloudflare dashboard: **R2 → Create bucket**, name it `nachoibanez-booking-backups`. Then **R2 → Manage API tokens → Create API token** scoped to that bucket with read+write. Note the Access Key ID, Secret Access Key, and the account's R2 S3 endpoint (`https://<account-id>.r2.cloudflarestorage.com`).

- [ ] **Step 2: Install and configure rclone on the VPS**

```bash
curl https://rclone.org/install.sh | sudo bash
rclone config create r2 s3 provider=Cloudflare access_key_id=<ACCESS_KEY_ID> secret_access_key=<SECRET_ACCESS_KEY> endpoint=https://<account-id>.r2.cloudflarestorage.com
```

- [ ] **Step 3: Set `R2_BUCKET_NAME` in `.env`**

```
R2_BUCKET_NAME=nachoibanez-booking-backups
```

- [ ] **Step 4: Write `scripts/backup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
source .env
set +a

BACKUP_DIR="backups"
RETENTION_DAYS=14
TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/calendso_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"
docker compose exec -T database pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$DUMP_FILE"

find "$BACKUP_DIR" -name 'calendso_*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete

rclone copy "$DUMP_FILE" "r2:${R2_BUCKET_NAME}/backups/"
```

- [ ] **Step 5: Make it executable, commit**

```bash
chmod +x scripts/backup.sh
git add scripts/backup.sh
git commit -m "Add nightly Postgres backup script with R2 upload"
git push
```

- [ ] **Step 6: Run it once by hand and verify**

```bash
cd /home/rburdet/nachoibanez-booking
git pull
./scripts/backup.sh
rclone ls r2:nachoibanez-booking-backups/backups/
```
Expected: the new `calendso_<timestamp>.sql.gz` file is listed.

- [ ] **Step 7: Schedule it nightly via cron**

```bash
crontab -e
```
Add:
```
0 3 * * * /home/rburdet/nachoibanez-booking/scripts/backup.sh >> /var/log/nachoibanez-booking-backup.log 2>&1
```

---

## Task 9: Restart resilience check

**Files:** none.

- [ ] **Step 1: Restart the whole stack**

```bash
cd /home/rburdet/nachoibanez-booking
docker compose restart
```

- [ ] **Step 2: Verify everything comes back on its own**

```bash
docker compose ps
curl -sI https://clases.rburdet.com | head -1
```
Expected: all three containers show `Up`/healthy, and the public domain answers `200`/redirect within a minute of the restart — no manual intervention needed.

- [ ] **Step 3: Final commit**

If any fixes were needed to get here, commit them now. Otherwise this task is verification-only — nothing to commit.

---

## Self-Review Notes

- **Spec coverage:** infra/deploy (Tasks 1–3), auth/Access (Task 6), event types + availability + no-payment (Task 7), backups (Task 8), full verification checklist from the spec (Tasks 4 Step 5, 5 Step 4, 6 Steps 3–5, 7 Steps 5–6, 8 Step 6, 9) — every spec section maps to a task.
- **Placeholder scan:** no TBD/TODO; all commands and file contents are concrete.
- **Type/naming consistency:** service names (`database`, `calcom`, `cloudflared`), env var names, and file paths (`vendor/cal.diy`, `.env`, `scripts/deploy.sh`, `scripts/backup.sh`) are used identically across every task that references them.
- **Known risk flagged explicitly, not hidden:** Cloudflare Access path-scoping (Task 6) could over-block student-facing routes if cal.diy's route structure differs from what's assumed here — Task 6 Step 5 and Task 7 Step 5 both independently verify the public booking flow survives the Access policy before calling this done.
