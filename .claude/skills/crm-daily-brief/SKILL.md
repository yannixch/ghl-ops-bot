---
name: crm-daily-brief
description: Generate the Paley Renovations end-of-day brief for Nazar (estimator + PM) and send it to Yannis on Telegram. Two parts — (1) today's booked appointments with a per-lead conversation summary (text + GHL call transcript) and appointment details, (2) a pipeline action list across three buckets — pending estimate, estimate sent, approved/needs scheduling. Read-only against GoHighLevel via the official MCP. Triggers for "daily brief", "crm brief", "paley brief", "end of day brief", "eod brief", "what got booked today", "pipeline reminders".
user-invocable: true
allowed-tools: [Read, Write, Bash]
metadata:
  version: 0.1.0
  domains: [crm, reporting, gohighlevel]
  type: utility
  client: paley-renovations
  inputs: [gohighlevel-mcp, telegram-mcp]
  outputs: [telegram-message, markdown-report]
  status: DRAFT — verify all MCP tool names + field paths + the 3 stage mappings against a live smoke test before first real run
---

# CRM Daily Brief — Paley Renovations

One end-of-day message to **Yannis on Telegram** (he forwards relevant parts to Nazar). Read-only against GoHighLevel.

**Audience framing:** the content is written *for Nazar* — the estimator who attends the in-home kitchen & bath appointments and manages the pipeline. So summaries should answer "what does Nazar need to know to walk into tomorrow's appointments prepared, and who in the pipeline needs action."

**Read-only.** The only thing this skill sends is the Telegram brief. It never edits GHL.

---

## ⚠️ Setup — verify before first real run

Depends on two MCP servers in `.mcp.json`:
- `gohighlevel-paley` — GHL official MCP (PIT + Location ID), read scopes + conversations read.
- `telegram` — already wired.

The tool names + field paths below are drafted from GHL MCP docs and **must be confirmed** at the Phase 0 smoke test.

| Thing to verify | Drafted value | Confirm by |
|---|---|---|
| Bookings today | `calendars_get-calendar-events` (date range = today, TZ-aware) | Run it; inspect appointment objects |
| Appointment → contact link | `contactId` on the event | Inspect a real event |
| Appointment fields | start time, title/type, assigned user, address/location | Inspect a real event |
| Opportunities by stage | `opportunities_search-opportunity` + `opportunities_get-pipelines` | Run; confirm stage IDs + names |
| Conversation for a contact | `conversations_search-conversation` then fetch messages | Run for one booked contact |
| **Call transcript availability** | a message of type `CALL` carrying `transcript` and/or `recordingUrl` | **Critical — see Voice section** |
| Stale/idle field | `updatedAt` per opportunity | Inspect |
| Telegram send | `mcp__telegram__send_message` to `TELEGRAM_TARGET` | Send a test |

---

## Constants (verified live 2026-06-10)

```
GHL_MCP          = gohighlevel-paley
GHL_ENDPOINT     = https://services.leadconnectorhq.com/mcp/   (auth: PIT bearer + locationId header)
LOCATION_ID      = SBWsCsOvoKci7htWODay
PIPELINE         = Customer Journey  (id zEfi70fS2rNS3wFnYN1a)  ← primary pipeline
TELEGRAM_TARGET  = 8519030231   (Yannis / @Yanix_GL — own id = Saved Messages)
TIMEZONE         = America/Los_Angeles               ← CONFIRM Paley's local timezone
STALE_DAYS       = 5                                 ← days-in-stage before a deal is flagged "needs a nudge"
REPORT_DIR       = briefs/   (project root; gitignored)
```

### Stage bucket mapping (real stage IDs — Customer Journey pipeline)

| Bucket | GHL stage | Stage ID |
|---|---|---|
| **Pending estimate** | `Send out Estimate` (+ optionally `Appointment Set`) | `df5552df-2227-4b16-94a0-98cb19bfdc5e` (`054ba5a3-70d4-42f4-b7fe-08dce954c6df`) |
| **Estimate sent** | `Pending / Estimate sent` | `4adcfcbb-2ad1-4bb0-b735-c9734d60a850` |
| **Approved — needs scheduling** | `Approved / to be Scheduled` | `cb5ccf70-9738-47fb-80bc-06c3c3623c97` |

Full stage list (position order): Nurture · New Lead · Cancellation/Reschedule · **Appointment Set** · **Send out Estimate** · **Pending/Estimate sent** · Ghosting · **Approved/to be Scheduled** · Scheduled · In Progress · Completed · Newsletter · UNQUALIFIED. Other pipelines exist (`FB API LEADS`, `REACTIVATION`) — ignore unless asked.

### GHL message-type codes (observed)
`1`=CALL · `2`=SMS · `3`=EMAIL · `28`=ACTIVITY_OPPORTUNITY (e.g. "Opportunity created") · `31`=ACTIVITY_APPOINTMENT (e.g. booking). The speed-to-lead SMS setter is the **Appointwise** app (`meta.marketplace.appName`).

### MCP transport note (for any direct/script calls)
Responses are SSE: keep only lines starting `data:`, strip the prefix, parse JSON; the tool payload is a JSON string at `result.content[0].text`. Server is stateless (no Mcp-Session-Id required).

---

## Phase 0 — Bootstrap & smoke test

1. Confirm `gohighlevel-paley` and `telegram` MCP servers are available. If GHL missing → stop: `ERROR: gohighlevel-paley MCP not connected. Add PIT + Location ID to .mcp.json.`
2. Pull pipelines → build stage-ID → name map. Map the three buckets to real stage IDs (table above). If any bucket can't be mapped, stop and ask Yannis.
3. Confirm `TELEGRAM_TARGET` is set. If not, resolve via `mcp__telegram__get_me` / ask which chat.
4. **Voice check:** fetch messages for one contact that had a recent call; confirm whether a `CALL` message carries `transcript` text (native) or only `recordingUrl`. Record which — it decides the Voice path below.

If any tool name/shape differs from the table, stop and print the raw response. Do not guess alternates.

---

## Phase 1 — Bookings today

1. `calendars_get-calendar-events` for **today** in `TIMEZONE`. (Definition of "booked today" = appointment **created** today, even if the appointment date is future. Confirm whether the event object exposes a created/booked timestamp vs only the appointment start; if only start time is available, use appointments scheduled in the relevant window and note the limitation.)
2. For each booking capture: contact name + id, appointment start datetime, type/title (kitchen vs bath if present), assigned user (estimator), location/address.
3. For each booked contact, pull the conversation (Phase 2) and produce a summary.

If zero bookings today → say so plainly; still run the pipeline section.

---

## Phase 2 — Conversation summaries (text + voice)

For each booked contact, gather the conversation history via `conversations_search-conversation` → messages, then summarize.

**Text messages:** read the inbound/outbound SMS thread (the speed-to-lead bot + any setter texts).

**Voice — GHL native transcription (chosen 2026-06-10):**
Yannis is the setter for now, calling through GHL's dialer. Calls land in the conversation as a `type:1 / TYPE_CALL` message with a recording. Requires GHL's **Voice Intelligence** call-transcription add-on to be **enabled** (Settings → Phone System → Voice tab → Call Transcription) — billed $0.024/recorded min. Applies to calls going forward, not retroactively.

Fetch the transcript via **direct REST** (the MCP server has no transcript tool):
```
GET https://services.leadconnectorhq.com/conversations/locations/{LOCATION_ID}/messages/{messageId}/transcription
Headers: Authorization: Bearer {PIT}   ·   Version: 2021-04-15 (confirm)   ·   Accept: application/json
```
- Read the **PIT from the `gohighlevel-paley` entry in `.mcp.json`** at runtime — never hardcode it in this file (this file is git-tracked; `.mcp.json` is gitignored).
- Get each call's `messageId` from `conversations_get-messages` (the `type:1` CALL message).
- Transcription is async — if the endpoint returns empty/404, the transcript isn't ready yet; retry next run. Until then note "call recorded, transcript pending."
- Once a transcript exists, summarize it alongside the text thread (Phase 2 summary), and tag the summary so Nazar knows which parts came from the call.

**Per-lead summary (3–5 lines), written for Nazar:**
- Who + what: name, kitchen vs bath, scope signals.
- Money/timeline hints: budget mentions, urgency, decision-maker.
- Appointment: date/time + address/area.
- Objections / watch-outs surfaced in text or call.

---

## Phase 3 — Pipeline action buckets

Pull open opportunities (`opportunities_search-opportunity`, all pages). Bucket by the mapped stage IDs:

- **Pending estimate** — booked, estimate not yet done. List: name, appointment date if known, days in stage.
- **Estimate sent** — awaiting decision. List: name, quote $ (`monetaryValue`), days since sent (flag `STALE_DAYS`+ as "needs follow-up").
- **Approved — needs scheduling** — won/approved, not yet on the calendar. List: name, job value, days waiting (these are the most urgent — money on the table).

Sort each bucket oldest-idle first so the stalest items surface.

---

## Phase 4 — Compose the Telegram brief

Keep it scannable. Shape:

```
🏠 Paley Daily Brief — Tue Jun 10

📅 BOOKED TODAY (2)
• Sarah Smith — Kitchen reno, Vancouver WA. Appt Thu 6/12 10am.
  Budget ~$30k, wants island + quartz. Husband decides too. No objections.
• Mike Lee — Bath remodel. Appt Fri 6/13 2pm.
  Called in, motivated (water damage). Insurance involved — bring that up.

📋 PIPELINE — needs action
Pending estimate (3): Garcia (appt 6/11), Nguyen (appt 6/12), Cole (appt 6/14)
Estimate sent (2): ⚠️ Tran — $42k, 6d no reply · Brooks — $19k, 2d
Approved → SCHEDULE (1): 🔴 Patel — $55k, approved 4d ago, not on calendar

Full brief saved.
```

Use 🔴 for approved-needs-scheduling and ⚠️ for estimate-sent past `STALE_DAYS`.

Also save a fuller markdown version to `REPORT_DIR/paley-brief-YYYY-MM-DD.md`.

---

## Phase 5 — Deliver

1. Save the markdown report (create `REPORT_DIR` if needed).
2. Send the Telegram brief to `TELEGRAM_TARGET` via `mcp__telegram__send_message`.
3. Print one-line confirmation: report path + Telegram delivery status.

If `TELEGRAM_TARGET` isn't set or send fails, print the full brief to the console so nothing is lost.

---

## Notes

- **Read-only guarantee:** PIT carries no write scopes in v1. The skill only reads GHL and sends Telegram.
- **Voice is design-ready but live only when calls exist** — the appointment setter isn't hired yet. Until real GHL calls are recorded, the voice path is dormant; text summaries + bookings + pipeline buckets work today.
- **Whisper fallback costs money** — never enable it without Yannis's explicit OK; default to GHL-native transcripts.
- **Stage mapping is the one thing that must be right** — wrong stage→bucket mapping makes the pipeline section useless. Confirm against the live pipeline, not guesses.
- **Timezone** governs "today" — all date math uses `TIMEZONE`, not server UTC.
- **Forwarding:** brief goes to Yannis only for now; he forwards to Nazar. When ready to send Nazar directly, add him as a recipient (Telegram or SMS) — keep routing in a config, not hardcoded.
