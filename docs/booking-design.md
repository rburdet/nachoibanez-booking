# Calendario de reservas — Nacho Ibáñez (instructor de kitesurf)

> Diseño validado — contexto y decisiones para pasar a un plan de implementación.

## Contexto

Instructor de kitesurf ([@nachoibanezw](https://www.instagram.com/nachoibanezw/)) necesita un
calendario de reservas público, enlazado desde su Instagram, para que los alumnos agenden clases.

## Decisión de stack: cal.diy self-hosted

- **[cal.diy](https://github.com/calcom/cal.diy)**: fork open-source (MIT) de Cal.com — la versión
  que quedó 100% abierta cuando Cal.com pasó sus features enterprise a closed-source. Next.js +
  tRPC + Prisma + Postgres. Solo se distribuye self-hosted, no hay versión gestionada por ellos.
- Requisito mínimo cómodo: ~2 vCPU / 4GB RAM para uso individual con bajo volumen. La VPS de
  Hetzner ya disponible (4GB RAM, plan más barato, comparte recursos con otros servicios livianos)
  alcanza sin problema.
- **Por qué no Cloudflare como host de la app**: el free tier de Cloudflare (Workers/Pages) es
  edge/serverless (runtime V8), no soporta bien un monorepo Next.js+Prisma+Postgres como cal.diy —
  no está entre sus targets de one-click deploy. Cloudflare se usa como capa de red, no como host.

## Infraestructura y despliegue

- Docker Compose en la VPS Hetzner con 3 contenedores:
  - `cal.diy` (Next.js)
  - `postgres` (con volumen persistente)
  - `cloudflared` (daemon del Cloudflare Tunnel)
- `cloudflared` abre conexión saliente hacia Cloudflare — no hace falta abrir puertos entrantes
  en el firewall de Hetzner ni exponer la IP del server.
- DNS: `clases.rburdet.com` (dominio de Rodrigo, ya gestionado en Cloudflare), apuntando al
  Tunnel, con SSL gratis de Cloudflare.
- Repo en GitHub con el Docker Compose, templates de env vars y esta doc; la VPS despliega
  vía `git pull`.
- Emails transaccionales (confirmación de reserva) vía **Resend** — ya se usa en la instancia
  de Rodrigo, se reutiliza la misma cuenta/API key con un remitente nuevo para este proyecto.

## Acceso y autenticación

- **Cloudflare Access** (Zero Trust, free tier hasta 50 usuarios) gatea las rutas de
  administración (login, dashboard, disponibilidad, reservas) restringido por allowlist de
  email (Rodrigo + Nacho) vía código OTP — sin passwords propias.
- La página pública de reserva (donde entran los alumnos) queda sin restricción de Access.
- Detrás de Access, el login propio de cal.diy sigue existiendo para entrar al dashboard.

## Configuración de reservas

- **Event Types**: uno por tipo de clase (ej. clase privada, clase grupal, alquiler de equipo),
  cada uno con su precio puesto como texto en la descripción — cal.diy no tiene cobro online
  integrado, y por ahora no se cobra en la reserva (se arregla aparte).
- **Disponibilidad**: horario semanal fijo y recurrente, cargado una sola vez. Nacho bloquea
  manualmente los días puntuales que no den las condiciones de viento (no hay toggle semanal
  de apertura).

## Flujos

- **Alumno**: link en bio de Instagram → página pública de reserva → elige tipo de clase → elige
  horario disponible → confirma con su email → recibe confirmación por mail.
- **Nacho / Rodrigo**: entran a `clases.rburdet.com` → Cloudflare Access pide OTP al email →
  login de cal.diy → dashboard (ver reservas, bloquear fechas).

## Backups

- Cron nightly con `pg_dump` del Postgres a un archivo local con fecha, reteniendo los últimos
  14 días.
- Copia semanal de ese dump a **Cloudflare R2** (free tier, 10GB — ya hay cuenta Cloudflare, no
  suma otro proveedor) vía `rclone` o el CLI de R2 (S3-compatible), para no depender solo del
  disco de la VPS.

## Plan de verificación

Antes de dar por terminada la implementación:

- Stack levanta en Hetzner, contenedores healthy.
- `clases.rburdet.com` resuelve por el Tunnel con HTTPS.
- Cloudflare Access: bloquea un email no autorizado, deja pasar los dos emails whitelisteados
  (Rodrigo + Nacho) vía OTP.
- Página pública de reserva carga sin pedir Access.
- Se cargan los Event Types reales (con precios en texto) y la disponibilidad semanal.
- Reserva de prueba end-to-end por cada tipo de clase → aparece en el dashboard → llega el
  email de confirmación vía Resend.
- Bloquear una fecha manualmente → el slot desaparece en la página pública.
- Backup: se dispara el cron una vez a mano y se verifica que el dump llegue a R2.
- Reiniciar el stack (`docker compose restart` o reboot de la VPS) y confirmar que todo vuelve
  solo.
