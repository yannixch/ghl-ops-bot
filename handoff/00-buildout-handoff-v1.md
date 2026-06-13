# Handoff — Paley Renovations CRM Assistant (Full Build)

**Created:** 2026-06-12 · **For:** a fresh build session (build in chunks, not all at once)
**Owner:** Yannis Choglo · **Client:** Paley Renovations (kitchen & bath remodeler)
**Why this exists:** Paley is the flagship client of Yannis's agency (The Marketing Dept) and the template he'll resell to other remodeling companies. Build it clean and re-pointable.

---

## 0. DECISIONS TO CONFIRM AT THE START OF THE BUILD SESSION

1. **Project location — RECOMMENDED: a new, separate Claude Code project** (`~/Documents/CRM Ops Assistant/`), NOT inside the Executive Assistant folder. Reasons: different product, different persona, different client data/creds, and a multi-client resale future (one folder per client, each with its own `.mcp.json`). Migration cost is ~15 min (move 2 skills + 1 MCP block).
   - Proposed structure:
     ```
     ~/Documents/CRM Ops Assistant/
       CLAUDE.md                  (persona: CRM ops agent for remodeling cos; active client)
       clients/paley-renovations/
         .mcp.json                (Paley PIT + Location)
         context.md               (Paley business, team, pipeline ontology)
         state/                   (snapshots + nudge dedupe json)
       .claude/skills/            (crm-daily-brief, crm-appointment-nudge, + write-back skills)
     ```
2. **Nazar's communication channel for the write-back loop.** The agentic pipeline-management loop requires the assistant to *converse with Nazar* (text him, read his reply, update the CRM). Options: **SMS via GHL** (`conversations_send-a-new-message`, needs Nazar as a contact/number) · Telegram · the LeadConnector app. The team already uses the **LeadConnector mobile app** (that's where the appointment setter gets call pings). DECIDE before building Chunk C.
3. **Stale thresholds per stage** (defaults proposed below in §2 — confirm).
4. **Read vs write go-live.** v1 skills are read-only. The write-back loop (Chunks C–E) calls `opportunities_update-opportunity`. PIT already has write scope. Confirm Yannis is ready to let the assistant write.

---

## 1. CURRENT STATE (what's already done)

- **GHL official MCP connected** as `gohighlevel-paley` (in `.mcp.json`). Endpoint `https://services.leadconnectorhq.com/mcp/`, auth = PIT bearer + `locationId` header. **Verified working 2026-06-10.**
  - PIT: `pit-23c96984-022c-4e40-bd86-5e4effdbd9b7` · Location: `SBWsCsOvoKci7htWODay`
  - PIT carries **write scopes** (create/update contacts, update opportunities, send messages) — not the originally-planned read-only token. Safe today (v1 only reads); reissue read-only if hard guarantees are ever wanted.
- **Two read-only skills built** (currently in the Executive Assistant project; move them):
  - `crm-daily-brief` — EOD: today's bookings + per-lead conversation summary (text + GHL call transcript) + pipeline buckets → Telegram to Yannis (`8519030231`).
  - `crm-appointment-nudge` — hourly: any deal still in **Appointment Set** 3h+ after appointment start time → Telegram nudge to Yannis.
- **Voice transcription decided: GHL native ("Voice Intelligence").** $0.024/recorded min. **ACTION FOR YANNIS:** enable at *Settings → Phone System → Voice → Call Transcription*, then place a fresh test call (not retroactive). Transcript fetched via REST: `GET /conversations/locations/{loc}/messages/{messageId}/transcription` (Bearer PIT). MCP has no transcript tool, so this is a direct REST call.
- **Pipeline is ~1 year stale** (confirmed via live pull 2026-06-10: 54 in Appointment Set, 44 in New Lead, 0 in estimate/approved stages). **Yannis + Nazar re-haul the pipeline early week of 2026-06-15.** Nothing downstream can be tested until that's done.

---

## 2. TARGET PIPELINE — "Customer Journey" (`zEfi70fS2rNS3wFnYN1a`)

The assistant's job at each stage. (Stage IDs are PRE-rehaul; **re-pull `opportunities_get-pipelines` after the rehaul** and update IDs — they may change.)

| Stage (current ID) | Assistant's responsibility |
|---|---|
| **New Lead** `f284ebf3…` | Monitor for **stale** leads → alert **Yannis** (his stage to own). |
| **Appointment Set** `054ba5a3…` | After the appointment (3h past start), text **Nazar**: did it happen? Capture outcome + details (+ recording/summary attached). Ask **are we pursuing this lead?** If yes, get an **estimated project $**. Then **move** the deal to: **Nurture** (not ready), **Lost** (not pursuing), or **Send out Estimate** (pursuing). |
| **Send out Estimate** `df5552df…` | After **>1 week** in stage, follow up with **Nazar**: was the estimate sent? Confirm the **quote $** (update if needed). If sent → **move to Pending / Estimate sent**. |
| **Pending / Estimate sent** `4adcfcbb…` | Awaiting customer decision. (Stale follow-up TBD.) |
| **Ghosting** `3e7608ea…` | Customers who got an estimate but went silent → **automations** to re-engage (future chunk). |
| **Approved / to be Scheduled** `cb5ccf70…` | After a bit in stage, ping **Nazar** to get them on the calendar. Once scheduled → **move to Scheduled**. |
| **Scheduled** `2ac78707…` | Ask **Nazar** for **start date + expected end date**; update the opportunity. |
| Nurture `8d809805…` · In Progress · Completed · Newsletter · UNQUALIFIED · Cancellation/Reschedule | Supporting states. |

**Proposed stale thresholds (confirm):** New Lead > 24–48h · Appointment Set = 3h post-appointment (built) · Send out Estimate > 7 days (stated) · Approved/to-be-Scheduled > 2–3 days · Pending/Estimate sent > 5–7 days.

**Roads of routing:** Yannis owns New Lead stale alerts; **Nazar (+ other PMs)** own Appointment Set → Scheduled.

---

## 3. BUILD CHUNKS (do in order, one per session-block)

### Chunk A — Post-rehaul re-sync *(do first, after the pipeline rehaul)*
- Re-pull pipelines; update stage IDs in all skills/configs.
- Confirm bucket/stage names didn't drift. Confirm thresholds (§2).

### Chunk B — Role-routed stale monitors *(read-only, low risk)*
- **Yannis monitor:** stale **New Lead** opportunities → daily/role-appropriate alert.
- **Nazar monitor:** **Appointment Set** 3h nudge already built (`crm-appointment-nudge`) — extend to other PMs + route directly to Nazar once his channel is set (§0.2).
- Generalize into one config-driven "stale monitor" (stage → threshold → recipient).

### Chunk C — Appointment-Set write-back loop *(the flagship; first WRITE feature)*
The conversational pipeline updater. Flow:
1. Trigger: deal in Appointment Set, appointment time passed (reuse nudge logic).
2. Assistant messages **Nazar** (channel per §0.2): "Did **[name]**'s appointment happen? Outcome? Are we pursuing? If yes, ballpark project $?"
3. Read Nazar's reply → extract **{happened?, disposition, pursue?, estimated $, scope notes}**.
4. **Write** via `opportunities_update-opportunity`: set monetary value, append notes; **move stage** → Nurture / Lost / Send out Estimate.
5. (Optional) attach call recording + summary to the opportunity.
- Needs: reply-parsing (Claude), a per-deal state machine, and human-readable confirmations back to Nazar ("Got it — moved [name] to Send out Estimate, $32k").

### Chunk D — Send-out-Estimate follow-up *(write)*
- >7 days in stage → ping Nazar: estimate sent? confirm quote $.
- If sent → update $ + **move to Pending / Estimate sent**.

### Chunk E — Approved → Scheduled *(write)*
- After threshold in "Approved / to be Scheduled" → ping Nazar to schedule.
- Once scheduled → **move to Scheduled**, then ask for **start + expected end date**; update opportunity.

### Chunk F — Ghosting re-engagement *(automation)*
- Estimate-sent leads who go silent → re-engagement sequence (likely GHL-native workflow + assistant oversight).

### Chunk G — Unified Speed-to-Lead + Nurture mega-workflow *(GHL-NATIVE; near-future, its own build)*
One workflow in GHL **Automations → Workflows** handling the whole front end. Yannis's spec:
- Lead comes in (e.g. Facebook) → **instant text + instant email**.
- No engagement within **2 min** → **appointment setter gets a LeadConnector app ping to call** (setter expected to call within 2–5 min).
- No answer → another **text ~1h later**, plus a **call**; **text next day**; **text the day after**; setter pinged again.
- Target: **≥4 calls + ≥4 texts in week 1** (exact cadence at builder's discretion).
- If lead stays **unresponsive** → drop into the **Nurture** stage/sequence (assistant or automation handles the move).
- **Architecture note:** this is deterministic timing → build as a **GHL-native Workflow** (Claude designs + builds it via the UI/guidance; the appointment-setter ping is a workflow notification action). Claude oversees/audits; it does NOT sit in the per-message live loop. NOTE: GHL official MCP has limited workflow CRUD — expect to build this in the GHL UI with Claude's step-by-step spec, or use a community MCP server for workflow APIs.

---

## 4. ARCHITECTURE PRINCIPLES

- **Two machines, kept separate:** (1) GHL-native workflows for deterministic cadence (speed-to-lead/nurture/drip, setter pings); (2) Claude-driven agentic loop for conversational pipeline write-back. Don't route live per-message traffic through Claude.
- **Claude Code is poll-based, not a webhook.** Triggers fire on scheduled runs (hourly/daily). For true real-time later, use GHL-native workflow triggers (e.g. the "Transcript Generated" trigger, appointment triggers) to do the time-critical part, with Claude doing the reasoning/write.
- **Write safety:** every stage move is a `opportunities_update-opportunity` call — confirm back to Nazar in plain language; log every write; consider a dry-run mode per chunk before going live.
- **Multi-client from day one:** one folder + one `.mcp.json` (PIT+Location) per client; never a shared master token.

---

## 5. TECHNICAL REFERENCE (so the new session has everything)

**MCP server (`gohighlevel-paley`) tools available (~36):** `opportunities_get-pipelines`, `opportunities_search-opportunity`, `opportunities_get-opportunity`, `opportunities_update-opportunity`, `calendars_get-calendar-events` (requires one of calendarId/userId/groupId + start/end in **millis**), `calendars_get-appointment-notes`, `conversations_search-conversation`, `conversations_get-messages`, `conversations_send-a-new-message`, `contacts_get-contact(s)` / `update` / `upsert` / `add-tags` / `remove-tags`, `locations_get-custom-fields`, `locations_get-location`, payments + social tools (ignore).

**Gotchas learned:**
- `opportunities_search-opportunity` with `getCalendarEvents=true` + `limit=100` returns ~255K chars → **exceeds context; save to file + parse with a script** (don't read raw). Filter server-side by `pipeline_stage_id` to keep payloads small.
- To get appointments you can either use `calendars_get-calendar-events` (needs a calendar/user/group ID — discover these) **or** pull them embedded via `opportunities_search` (`getCalendarEvents=true`) which also ties appointment↔stage in one shot (preferred for the nudge/write-back logic).
- Direct REST works with the PIT for endpoints the MCP lacks (e.g. transcription): responses are **SSE** for the MCP endpoint (keep `data:` lines, payload at `result.content[0].text`); plain JSON for the REST v2 API. Server is stateless (no session id needed).
- **Message type codes:** `1`=CALL · `2`=SMS · `3`=EMAIL · `28`=ACTIVITY_OPPORTUNITY · `31`=ACTIVITY_APPOINTMENT. Speed-to-lead SMS bot = the **Appointwise** app (`meta.marketplace.appName`).

**Pipelines:** Customer Journey `zEfi70fS2rNS3wFnYN1a` (primary) · FB API LEADS `D9FwkFcjYFk9O0D7bLoG` · REACTIVATION `mIlo4sfxc8stU3t8qUja`. **Re-pull after rehaul — IDs may change.**

**Transcription:** GHL Voice Intelligence; enable in settings; fetch `GET https://services.leadconnectorhq.com/conversations/locations/{LOCATION_ID}/messages/{messageId}/transcription` (Bearer PIT, `Version: 2021-04-15` — confirm). Also a GHL **"Transcript Generated" workflow trigger** exists for real-time.

**Telegram:** Yannis = `@Yanix_GL`, id `8519030231` (own id = Saved Messages). Telegram MCP already wired.

---

## 6. SEQUENCING

1. **Now → next week:** Yannis enables call transcription + places a test call; Yannis + Nazar re-haul the pipeline.
2. **After rehaul:** Chunk A (re-sync) → Chunk B (stale monitors) → Chunk C (Appointment-Set write-back) → D → E.
3. **Near future, separate build:** Chunk G (speed-to-lead + nurture mega-workflow).
4. **Later:** Chunk F (ghosting), reactivation pipeline, referral program, then productize to client #2.
