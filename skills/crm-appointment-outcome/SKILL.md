---
name: crm-appointment-outcome
description: Use when Yannis or Nazar replies to an appointment nudge. Conducts a short conversational interview to collect appointment outcome, pursuit decision, and project estimate, then writes the result back to GHL.
user-invocable: true
allowed-tools: [Read, Write, Bash]
metadata:
  version: 0.1.0
  domains: [crm, pipeline-hygiene, gohighlevel, write-back]
  type: utility
  client: paley-renovations
  inputs: [gohighlevel-mcp, telegram-mcp]
  outputs: [telegram-message, ghl-opportunity-update]
  status: DRAFT
---

# CRM Appointment Outcome — Paley Renovations

**Purpose:** write-back companion to `crm-appointment-nudge`. When Yannis replies to a nudge, this skill conducts a short conversational interview, collects three data points, and updates the opportunity in GHL — so the pipeline advances itself without anyone logging in.

**Trigger:** Yannis replies to an appointment nudge message via Telegram (or invokes this skill manually).

**Cadence:** on-demand. **Write-enabled** — updates opportunity stage, status, and monetary value in GHL.

---

## Constants (verified live 2026-06-21)

```
GHL_MCP                     = gohighlevel-paley
LOCATION_ID                 = SBWsCsOvoKci7htWODay
PIPELINE                    = Customer Journey  (id zEfi70fS2rNS3wFnYN1a)
APPT_SET_STAGE_ID           = 054ba5a3-70d4-42f4-b7fe-08dce954c6df   ← "Appointment Set"
SEND_ESTIMATE_STAGE_ID      = df5552df-2227-4b16-94a0-98cb19bfdc5e   ← "Send out Estimate"
NURTURE_STAGE_ID            = 8d809805-5e66-4f46-99ad-f722b33ff08b   ← "Nurture"
CANCEL_RESCHEDULE_STAGE_ID  = 59f217ce-83c1-4b5d-b39b-f4509539686e  ← "Cancellation/Reschedule"
TELEGRAM_TARGET             = 8519030231   (Yannis / @Yanix_GL — Nazar NOT on Telegram yet)
STATE                       = state/outcome-conversations.json   (project root; gitignored)
FOLLOWUP_INTERVAL_HOURS     = 3     ← hours between follow-ups when no reply received
MAX_FOLLOWUP_HOURS          = 48    ← total window from original nudge before dropping silently
```

---

## State schema

Each active outcome conversation is tracked in `STATE` as an object keyed by opportunityId:

```json
{
  "opportunityId": "...",
  "contactName": "...",
  "nudgeSentAt": "ISO timestamp",
  "followUpCount": 0,
  "lastFollowUpAt": "ISO timestamp or null",
  "conversationState": "awaiting_outcome | awaiting_pursuing | awaiting_estimate | awaiting_reschedule | awaiting_lost_nurture | complete"
}
```

Remove entry when `conversationState = complete` or when `now - nudgeSentAt > MAX_FOLLOWUP_HOURS`.

---

## Logic

### Phase 0 — Bootstrap
1. Confirm `gohighlevel-paley` + `telegram` MCP servers available. If GHL missing → stop with a clear error.
2. Load `STATE`. If file doesn't exist, initialize as `{}`.
3. Identify the opportunity this reply pertains to:
   - If invoked by Hermes after a nudge reply: opportunityId and contactName are available from the nudge context.
   - If invoked manually: ask Yannis which lead this is about, then `opportunities_search-opportunity` to confirm before proceeding.
   - If ambiguous (Yannis names a contact but multiple matches): list them and ask which one.

### Phase 1 — Determine conversation state
1. Look up the state entry for this opportunityId.
2. If no entry exists (first reply after nudge), create one with `conversationState = awaiting_outcome` and `nudgeSentAt = now`.
3. Route to the appropriate handler based on `conversationState`.

### Phase 2 — Conversational interview

**Use LLM reasoning to parse intent from plain English. No rigid syntax required. If a reply is ambiguous, ask one clarifying follow-up — never guess, never interrogate repeatedly.**

#### State: `awaiting_outcome`
Ask:
```
Did [Contact name]'s appointment happen?
```
Parse reply:
- Yes (showed up, it happened, he came, etc.) → set `conversationState = awaiting_pursuing`, send pursuing question immediately
- No (no-show, cancelled, they bailed, didn't show, etc.) → set `conversationState = awaiting_reschedule`, send reschedule question immediately
- Ambiguous → one clarifying follow-up

#### State: `awaiting_pursuing`
Ask:
```
Are we pursuing [Contact name]?
```
Parse reply:
- Yes (pursuing, let's go, yes, absolutely, she wants to move forward, etc.) → set `conversationState = awaiting_estimate`, send estimate question immediately
- No / passing (not worth it, drop it, passing, not interested, etc.) → set `conversationState = awaiting_lost_nurture`, send lost/nurture question immediately
- Maybe / not sure → treat as pursuing (better to track than drop), proceed to estimate question
- Ambiguous → one clarifying follow-up

#### State: `awaiting_estimate`
Ask:
```
Rough estimate on the project? (just a number is fine)
```
Parse reply — extract dollar amount from plain English:
- "~22k" → 22000
- "about 15 thousand" → 15000
- "probably 30" → 30000
- "not sure yet" / "TBD" / "no idea" → proceed without monetary value

**Write to GHL:**
`opportunities_update-opportunity` → `pipelineStageId = SEND_ESTIMATE_STAGE_ID`, `status = open`, `monetaryValue = parsed amount` (omit if TBD)

**Telegram confirmation:**
```
Got it — moved [Contact name] to Send out Estimate[, $X]. ✓
```
Set `conversationState = complete`, remove entry from STATE.

#### State: `awaiting_reschedule`
Ask:
```
Did they already reschedule, should I move it to reschedule, or are we dropping it?
```
Parse reply:
- Already rescheduled / they rescheduled themselves → **Write:** move to `CANCEL_RESCHEDULE_STAGE_ID`, add tag `rescheduled` → **Telegram:** "Got it — moved [Contact name] to Cancellation/Reschedule (tagged rescheduled). ✓" → complete
- Move it / reschedule it → **Write:** move to `CANCEL_RESCHEDULE_STAGE_ID` (no extra tag; automations on that stage handle outreach) → **Telegram:** "Got it — moved [Contact name] to Cancellation/Reschedule. Automation will handle the rest. ✓" → complete
- Drop / lost / not worth it → set `conversationState = awaiting_lost_nurture`, send lost/nurture question immediately
- Ambiguous → one clarifying follow-up

#### State: `awaiting_lost_nurture`
Ask:
```
Lost or nurture?
```
Parse reply:
- Lost (dead, close it, gone, not happening, etc.) → **Write:** `opportunities_update-opportunity` → `status = lost` → **Telegram:** "Got it — marked [Contact name] as lost. ✓" → complete
- Nurture (keep warm, follow up later, not now, nurture, etc.) → **Write:** `opportunities_update-opportunity` → `pipelineStageId = NURTURE_STAGE_ID`, `status = open` → **Telegram:** "Got it — moved [Contact name] to Nurture. ✓" → complete
- Ambiguous → one clarifying follow-up

### Phase 3 — Follow-up cadence (no response received)
Run this check when invoked without a fresh reply (Hermes cron mode):
1. Load `STATE`, find entries where `conversationState != complete`.
2. For each entry:
   - If `now - nudgeSentAt > MAX_FOLLOWUP_HOURS`: remove entry silently. Do not ping Yannis.
   - Else if `now - lastFollowUpAt >= FOLLOWUP_INTERVAL_HOURS` (or `lastFollowUpAt` is null and `now - nudgeSentAt >= FOLLOWUP_INTERVAL_HOURS`):
     - Send brief follow-up via Telegram:
       ```
       Still waiting on [Contact name]'s appointment outcome — what happened?
       ```
     - Increment `followUpCount`, set `lastFollowUpAt = now`.

---

## GHL Write Reference

| Outcome | pipelineStageId | status | monetaryValue | tag |
|---------|----------------|--------|---------------|-----|
| Pursuing + estimate | `df5552df-2227-4b16-94a0-98cb19bfdc5e` | open | parsed $ | — |
| Not pursuing → lost | — | lost | — | — |
| Not pursuing → nurture | `8d809805-5e66-4f46-99ad-f722b33ff08b` | open | — | — |
| No-show, already rescheduled | `59f217ce-83c1-4b5d-b39b-f4509539686e` | open | — | `rescheduled` |
| No-show, reschedule it | `59f217ce-83c1-4b5d-b39b-f4509539686e` | open | — | — |
| No-show → lost | — | lost | — | — |
| No-show → nurture | `8d809805-5e66-4f46-99ad-f722b33ff08b` | open | — | — |

---

## Safety

- Always confirm opportunity ID before writing. If context is ambiguous, search and confirm first.
- If GHL update fails, log error in STATE entry and tell Yannis via Telegram what went wrong. Do not silently swallow errors.
- Never update an opportunity not in STATE as an active conversation.
- The 48-hour window is measured from `nudgeSentAt`, not from the last follow-up.
- Yannis is the only recipient. Nazar is NOT on Telegram yet — do not attempt to contact him directly.

---

## Notes

- **Write-enabled** — unlike the nudge skill, this makes live GHL updates. Double-check opportunity ID before every write.
- **LLM-native parsing** — no regex required. Parse intent from plain English. One clarifying question max per ambiguity.
- **Shares stage IDs** with `crm-appointment-nudge` and `crm-daily-brief`. Keep in sync if pipeline is restructured.
- **Future:** when Nazar joins Telegram, add him as `TELEGRAM_TARGET_NAZAR` in the constants block, not hardcoded in message logic.
