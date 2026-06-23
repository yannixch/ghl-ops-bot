---
name: crm-appointment-nudge
description: Pipeline-hygiene watchdog for Paley Renovations. Hourly, finds any opportunity still sitting in the "Appointment Set" stage 3+ hours after its appointment start time — meaning the visit should have happened but the stage was never advanced — and Telegrams Yannis a nudge asking for the outcome (he forwards to Nazar). Read-only against GoHighLevel. Triggers for "appointment nudge", "stale appointment check", "hygiene check", "who didn't update", "appointment set check".
user-invocable: true
allowed-tools: [Read, Write, Bash]
metadata:
  version: 0.1.0
  domains: [crm, pipeline-hygiene, gohighlevel]
  type: utility
  client: paley-renovations
  inputs: [gohighlevel-mcp, telegram-mcp]
  outputs: [telegram-message]
  status: DRAFT — needs a live dry-run; sends to Yannis via Telegram only
---

# CRM Appointment Nudge — Paley Renovations

**Purpose:** solve the core pain — Nazar (estimator + PM) not advancing the pipeline after appointments. If a deal is **still in "Appointment Set" 3+ hours after the appointment's scheduled start time**, the visit has presumably happened (or was a no-show) and the stage should have moved. This nudges Yannis to chase the update.

**Cadence:** runs **hourly during business hours** (TZ-aware). **Read-only** — only output is a Telegram message to Yannis. No writes to GHL.

---

## Constants (verified live 2026-06-10)

```
GHL_MCP            = gohighlevel-paley
LOCATION_ID        = SBWsCsOvoKci7htWODay
PIPELINE           = Customer Journey  (id zEfi70fS2rNS3wFnYN1a)
APPT_SET_STAGE_ID  = 054ba5a3-70d4-42f4-b7fe-08dce954c6df   ← "Appointment Set"
NUDGE_AFTER_HOURS  = 3                  ← hours past appointment start before nudging
LOOKBACK_HOURS     = 36                 ← ignore appointments older than this (don't re-litigate history)
TIMEZONE           = America/Los_Angeles   ← CONFIRM Paley's local timezone
TELEGRAM_TARGET    = 8519030231   (Yannis / @Yanix_GL — own id = Saved Messages)
STATE              = state/nudge-dedupe.json   (project root; gitignored)
```

---

## Logic

### Phase 0 — Bootstrap
1. Confirm `gohighlevel-paley` + `telegram` MCP servers available. If GHL missing → stop with a clear error.
2. Load `STATE` (list of appointment IDs already nudged). If the file/dir doesn't exist:
   - **First-run baseline:** create it and record every *currently-stale* appointment as already-nudged **without sending** (so going live doesn't fire a burst of nudges about old appointments). Print "baseline captured, nudging starts next run." Then stop.
3. Resolve `TELEGRAM_TARGET` if unset (`mcp__telegram__get_me` → self / Saved Messages).

### Phase 1 — Find candidate appointments
1. `calendars_get-calendar-events` for the window `now - LOOKBACK_HOURS` → `now`, in `TIMEZONE`.
2. Keep appointments where `now - appointmentStart >= NUDGE_AFTER_HOURS hours` (the visit's window has passed).
3. Drop appointments whose status is already cancelled/no-show if the event exposes that (those don't need a "did it happen" nudge — but a no-show still left the deal in Appointment Set, so optionally nudge with a "no-show?" framing; default: include them).

### Phase 2 — Check stage
For each candidate, join appointment → opportunity:
1. From the event, get `contactId`.
2. `opportunities_search-opportunity` for that contact in pipeline `Customer Journey`.
3. If the contact's opportunity `pipelineStageId == APPT_SET_STAGE_ID` → **stale, needs nudge.** (If it already moved past Appointment Set, Nazar did his job — skip silently.)

### Phase 3 — Dedupe + nudge
1. Skip any appointment whose ID is already in `STATE`.
2. For each new stale appointment, send one Telegram message to `TELEGRAM_TARGET`:

```
⏰ Pipeline nudge — appt not updated
[Contact name] · [kitchen/bath if known]
Appointment was [day] [time] — 3h+ ago, still in "Appointment Set".
Did it happen? What's the outcome / next step?
(Reply with the outcome — soon I'll update the pipeline for you.)
```

3. Add the appointment ID to `STATE` so it's never nudged twice.
4. If multiple are stale in one run, send them as one combined message (a short list) rather than several pings.

---

## Phase 2 write-back (roadmap, NOT in v1)
The "Reply with the outcome" line seeds the flagship feature: a later version reads Yannis's/Nazar's reply, extracts {disposition, next step + date, quote $, scope}, and **updates the opportunity stage + fields** via `opportunities_update-opportunity` — so the pipeline maintains itself. v1 only asks; it does not parse replies or write.

---

## Notes
- **Read-only in v1** — only a Telegram message goes out. The PIT has write scopes, but this skill must never call an update tool until Phase 2 is explicitly approved.
- **First run captures a baseline** so you don't get spammed about historical stale deals.
- **One nudge per appointment, ever** (state file dedupe). If an appointment is rescheduled and re-stales, that's a new appointment ID → fine.
- **Timezone governs "3 hours after start"** — use `TIMEZONE`, not UTC.
- **No GHL SMS in v1** — routing is Telegram-to-Yannis. When Nazar should get it directly, add an SMS recipient (needs his number + a GHL send path) in a config, not hardcoded.
- Shares the GHL connection + stage map with [crm-daily-brief]. Keep stage IDs in sync if the pipeline is ever restructured.
