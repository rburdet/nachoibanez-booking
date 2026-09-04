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
- cal.diy application source is a pinned upstream dependency (tag `v6.2.0`), not vendored into this repo's git history — cloned into `vendor/cal.diy` at deploy time, gitignored.

---

## Task 1: VPS baseline — Docker, swap, deploy directory

The cal.diy image builds from source (multi-stage Next.js/Prisma build) — no maintained prebuilt image exists on Docker Hub or GHCR (verified: both registries return empty/unknown for `calcom/cal.diy`). On a 4GB VPS shared with other services, that build can be memory-hungry enough to risk an OOM kill. A swap file is cheap insurance.

**Files:**
- Create (on the VPS, not in the repo): `/swapfile`, and an fstab entry for it.

- [ ] **Step 1: Check Docker is installed and current**

Run on the VPS:
```bash
docker --version && docker compose version
```
Expected: both print a version (Docker 24+, Compose v2). If either is missing, install Docker per Hetzner's standard `get.docker.com` install script before continuing — do not proceed without this.

- [ ] **Step 2: Check current memory and swap**

```bash
free -h
```
Expected: ~4GB total RAM. Note how much is already used by other services running on the box.

- [ ] **Step 3: Add a 2GB swap file (skip if swap already present and >= 2GB)**

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

- [ ] **Step 4: Verify swap is active**

```bash
swapon --show
```
Expected: lists `/swapfile` with size 2G.

- [ ] **Step 5: Create the deploy directory and clone this repo there**

```bash
sudo mkdir -p /opt/nachoibanez-booking
sudo chown "$USER":"$USER" /opt/nachoibanez-booking
git clone git@github.com:rburdet/nachoibanez-booking.git /opt/nachoibanez-booking
```
Expected: `/opt/nachoibanez-booking` contains `README.md`, `docs/`, `.gitignore`.

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

- [ ] **Step 1: Add `vendor/` to `.gitignore`**

```
.env
*.env.local
backups/
node_modules/
vendor/
```

- [ ] **Step 2: Write `docker-compose.yml`**

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
    build:
      context: ./vendor/cal.diy
      dockerfile: Dockerfile
      args:
        NEXT_PUBLIC_WEBAPP_URL: ${NEXT_PUBLIC_WEBAPP_URL}
    restart: unless-stopped
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

- [ ] **Step 3: Write `.env.example`**

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

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml .env.example .gitignore
git commit -m "Add docker-compose stack and env template for cal.diy"
git push
```

---

## Task 3: Vendor cal.diy source + deploy script

**Files:**
- Create: `scripts/deploy.sh`

**Interfaces:**
- Consumes: `docker-compose.yml` from Task 2.
- Produces: `vendor/cal.diy` (gitignored working tree) that Task 2's `calcom` build context reads from.

- [ ] **Step 1: Write `scripts/deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CAL_DIY_TAG="v6.2.0"
VENDOR_DIR="vendor/cal.diy"

if [ -d "$VENDOR_DIR/.git" ]; then
  git -C "$VENDOR_DIR" fetch --tags origin
  git -C "$VENDOR_DIR" checkout "$CAL_DIY_TAG"
else
  git clone --branch "$CAL_DIY_TAG" --depth 1 https://github.com/calcom/cal.diy.git "$VENDOR_DIR"
fi

docker compose up -d --build
```

- [ ] **Step 2: Make it executable and commit**

```bash
chmod +x scripts/deploy.sh
git add scripts/deploy.sh
git commit -m "Add deploy script that pins and vendors cal.diy v6.2.0"
git push
```

- [ ] **Step 3: Run it on the VPS (dry structural check only — no real secrets yet)**

```bash
cd /opt/nachoibanez-booking
git pull
./scripts/deploy.sh
```
Expected: `vendor/cal.diy` gets cloned at tag `v6.2.0`. The `docker compose up -d --build` call will fail at this point because `.env` doesn't exist yet with real secrets — that's expected; this step only confirms the clone succeeds and the build context is valid. Confirm with:
```bash
test -d vendor/cal.diy/.git && echo "vendored ok"
```

---

## Task 4: Real secrets + bring the stack up

**Files:**
- Create (on the VPS only, not committed): `.env`

- [ ] **Step 1: Generate the two secrets**

```bash
openssl rand -base64 32   # NEXTAUTH_SECRET
openssl rand -base64 24   # CALENDSO_ENCRYPTION_KEY
```

- [ ] **Step 2: Create `/opt/nachoibanez-booking/.env` from `.env.example`**

Copy `.env.example` to `.env` and fill in:
- `POSTGRES_PASSWORD` — a fresh random value (e.g. `openssl rand -hex 24`)
- `NEXTAUTH_SECRET`, `CALENDSO_ENCRYPTION_KEY` — from Step 1
- `EMAIL_SERVER_PASSWORD` — the Resend API key (create one in the Resend dashboard scoped to sending only; the "sending domain" must already be verified for `rburdet.com` in Resend, since `EMAIL_FROM=reservas@rburdet.com`)
- `CLOUDFLARE_TUNNEL_TOKEN` — leave blank until Task 5
- `R2_BUCKET_NAME` — leave blank until Task 7

- [ ] **Step 3: Bring up database + calcom only (cloudflared has no token yet)**

```bash
docker compose up -d --build database calcom
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
cd /opt/nachoibanez-booking
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
0 3 * * * /opt/nachoibanez-booking/scripts/backup.sh >> /var/log/nachoibanez-booking-backup.log 2>&1
```

---

## Task 9: Restart resilience check

**Files:** none.

- [ ] **Step 1: Restart the whole stack**

```bash
cd /opt/nachoibanez-booking
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
