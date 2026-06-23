---
name: crm-estimate-followup
description: Use when following up on estimates that haven't been sent or acknowledged after 8 days. Handles two scenarios — estimate not yet sent (still in Send out Estimate) and estimate sent but no decision (Pending/Estimate Sent). Conducts conversational follow-up with Yannis and writes result back to GHL.
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

# CRM Estimate Follow-Up — Paley Renovations

**Purpose:** Daily watchdog that catches estimates stuck unsent or unacknowledged for 8+ days and asks Yannis what's going on. Writes the result back to GHL — no dashboard login needed.

**Trigger:** Runs daily (10am Pacific suggested). Also triggered when Yannis replies to a follow-up message.

**Cadence:** daily scan + on-demand write-back. **Write-enabled.**

---

## Constants (verified 2026-06-23)

```
GHL_MCP                    = gohighlevel-paley
LOCATION_ID                = SBWsCsOvoKci7htWODay
PIPELINE_ID                = zEfi70fS2rNS3wFnYN1a   (Customer Journey)
SEND_ESTIMATE_STAGE_ID     = df5552df-2227-4b16-94a0-98cb19bfdc5e   ← "Send out Estimate"
PENDING_ESTIMATE_STAGE_ID  = 4adcfcbb-2ad1-4bb0-b735-c9734d60a850   ← "Pending / Estimate Sent"
APPROVED_STAGE_ID          = cb5ccf70-9738-47fb-80bc-06c3c3623c97   ← "Approved / to be Scheduled"
GHOSTING_STAGE_ID          = 3e7608ea-39d0-4fbf-96e8-a3ce3476d785   ← "Ghosting"
NURTURE_STAGE_ID           = 8d809805-5e66-4f46-99ad-f722b33ff08b   ← "Nurture"
TELEGRAM_TARGET            = 8519030231   (Yannis / @Yanix_GL — Nazar NOT on Telegram yet)
STATE                      = state/estimate-followup.json   (project root; gitignored)
DAYS_THRESHOLD             = 8
FOLLOWUP_INTERVAL_HOURS    = 3
MAX_FOLLOWUP_HOURS         = 48
```

---

## State schema

Each active conversation is tracked in `STATE` keyed by opportunityId:

```json
{
  "opportunityId": "...",
  "contactName": "...",
  "scenario": "A | B",
  "triggerDate": "ISO timestamp",
  "followUpCount": 0,
  "lastFollowUpAt": "ISO timestamp or null",
  "conversationState": "awaiting_sent | awaiting_amount | awaiting_decision | awaiting_ghosting_action | awaiting_lost_nurture | complete"
}
```

Remove entry when `conversationState = complete` or when `now - triggerDate > MAX_FOLLOWUP_HOURS`.

---

## Logic

### Phase 0 — Bootstrap
1. Confirm `gohighlevel-paley` + `telegram` MCP servers available. If GHL missing → stop with clear error.
2. Load `STATE`. If file doesn't exist, initialize as `{}`.

### Phase 1 — Scan for stale opportunities (daily cron mode)

1. `opportunities_search-opportunity` filtering by `pipelineId = PIPELINE_ID` and `pipelineStageId = SEND_ESTIMATE_STAGE_ID`. For each result:
   - If `now - lastStageChangeAt >= DAYS_THRESHOLD days` AND opportunityId not already in STATE → create STATE entry with `scenario = A`, `conversationState = awaiting_sent`, send Scenario A message.

2. Repeat for `pipelineStageId = PENDING_ESTIMATE_STAGE_ID`:
   - If `now - lastStageChangeAt >= DAYS_THRESHOLD days` AND not in STATE → create entry with `scenario = B`, `conversationState = awaiting_decision`, send Scenario B message.

**Scenario A message (Send out Estimate — estimate not sent):**
```
Hey — [Contact name]'s estimate hasn't gone out yet (they've been in this stage for [N] days).
Has it been sent?
```

**Scenario B message (Pending / Estimate Sent — awaiting decision):**
```
[Contact name]'s estimate has been out for [N] days — any word from them?
```

### Phase 2 — Conversational interview

**Parse intent from plain English. One clarifying question max per ambiguity. Never guess.**

---

#### Scenario A — Estimate not yet sent

##### State: `awaiting_sent`
Waiting for: did the estimate go out?

Parse reply:
- **Yes, sent** (sent it, went out, yep, she has it, etc.) → set `conversationState = awaiting_amount`, ask amount immediately:
  ```
  What's the estimate amount?
  ```
- **No, not sent** (not yet, still working on it, haven't sent, etc.) → ask:
  ```
  Want me to flag this, or is it being handled?
  ```
  Parse:
  - "will handle / on it / sending soon / I'll do it" → log note in STATE, no GHL change, `conversationState = complete`, confirm:
    ```
    Got it — I'll leave it and check again in a few days.
    ```
  - "drop it / not happening / lost / not pursuing" → set `conversationState = awaiting_lost_nurture`, ask immediately:
    ```
    Lost or nurture?
    ```
  - Ambiguous → one clarifying follow-up
- **Lost / not pursuing** (dead, forget it, move on) → set `conversationState = awaiting_lost_nurture`, ask lost/nurture
- Ambiguous → one clarifying follow-up

##### State: `awaiting_amount`
Parse dollar amount from plain English:
- "~22k" → 22000
- "about 15 thousand" → 15000
- "probably 30" → 30000
- "not sure yet / TBD / no idea" → proceed without monetary value

**Write to GHL:**
`opportunities_update-opportunity` → `pipelineStageId = PENDING_ESTIMATE_STAGE_ID`, `status = open`, `monetaryValue = parsed amount` (omit if TBD)

**Telegram confirmation:**
```
Got it — moved [Contact name] to Pending / Estimate Sent[, $X]. ✓
```
`conversationState = complete`, remove from STATE.

---

#### Scenario B — Estimate sent, awaiting decision

##### State: `awaiting_decision`
Waiting for: did they respond?

Parse reply:
- **Approved / moving forward** (yes, they approved, she wants to go, let's do it, approved, moving forward, etc.) → ask:
  ```
  Move them to Approved?
  ```
  - "yes / yep / do it" → **Write:** `pipelineStageId = APPROVED_STAGE_ID`, `status = open` → confirm:
    ```
    Got it — moved [Contact name] to Approved / to be Scheduled. ✓
    ```
    → `conversationState = complete`
  - Ambiguous → one clarifying follow-up

- **No response / ghosting** (no word, nothing, ghosting, silent, no reply) → ask:
  ```
  Want to follow up with them, move to Ghosting, or drop it?
  ```
  → set `conversationState = awaiting_ghosting_action`

- **Lost / not pursuing** (dead, not happening, passed, not interested) → set `conversationState = awaiting_lost_nurture`, ask lost/nurture immediately

- Ambiguous → one clarifying follow-up

##### State: `awaiting_ghosting_action`
Parse reply:
- **Follow up / reach out** → log note in STATE, no GHL change, `conversationState = complete`, confirm:
  ```
  Got it — I'll leave it for now. Let me know if anything changes.
  ```
- **Ghosting / move to ghosting** → **Write:** `pipelineStageId = GHOSTING_STAGE_ID`, `status = open` → confirm:
  ```
  Got it — moved [Contact name] to Ghosting. ✓
  ```
  → `conversationState = complete`
- **Drop / lost / not happening** → set `conversationState = awaiting_lost_nurture`, ask:
  ```
  Lost or nurture?
  ```
- Ambiguous → one clarifying follow-up

---

#### Shared state: `awaiting_lost_nurture`

Ask:
```
Lost or nurture?
```
Parse reply:
- Lost (dead, close it, gone, not happening, etc.) → **Write:** `status = lost` → confirm:
  ```
  Got it — marked [Contact name] as lost. ✓
  ```
  → `conversationState = complete`
- Nurture (keep warm, follow up later, nurture, not now, etc.) → **Write:** `pipelineStageId = NURTURE_STAGE_ID`, `status = open` → confirm:
  ```
  Got it — moved [Contact name] to Nurture. ✓
  ```
  → `conversationState = complete`
- Ambiguous → one clarifying follow-up

---

### Phase 3 — Follow-up cadence (no response received)

Run this check when invoked without a fresh reply (Hermes cron mode):
1. Load `STATE`, find entries where `conversationState != complete`.
2. For each entry:
   - If `now - triggerDate > MAX_FOLLOWUP_HOURS`: remove entry silently. Do not ping Yannis.
   - Else if `now - lastFollowUpAt >= FOLLOWUP_INTERVAL_HOURS` (or `lastFollowUpAt` is null and `now - triggerDate >= FOLLOWUP_INTERVAL_HOURS`):
     - Send brief follow-up via Telegram based on scenario:
       - Scenario A: `Still waiting — did [Contact name]'s estimate go out?`
       - Scenario B: `Still waiting — any word back from [Contact name]?`
     - Increment `followUpCount`, set `lastFollowUpAt = now`.

---

## GHL Write Reference

| Outcome | pipelineStageId | status | monetaryValue |
|---------|----------------|--------|---------------|
| Estimate sent → pending | `4adcfcbb-2ad1-4bb0-b735-c9734d60a850` | open | parsed $ |
| Approved | `cb5ccf70-9738-47fb-80bc-06c3c3623c97` | open | — |
| Ghosting | `3e7608ea-39d0-4fbf-96e8-a3ce3476d785` | open | — |
| Lost | — | lost | — |
| Nurture | `8d809805-5e66-4f46-99ad-f722b33ff08b` | open | — |

---

## Safety

- Always confirm opportunity ID before writing. Search + confirm if context is ambiguous.
- If GHL update fails, log error in STATE and tell Yannis via Telegram what went wrong. Never swallow errors silently.
- Never update an opportunity not in STATE as an active conversation.
- The 48-hour window is measured from `triggerDate`, not from the last follow-up.
- Yannis is the only recipient. Nazar is NOT on Telegram yet.
- Skip an opportunity in STATE if it already has `conversationState = complete` — do not re-trigger.

---

## Notes

- **Write-enabled** — makes live GHL updates. Double-check opportunity ID before every write.
- **LLM-native parsing** — no regex required. Parse intent from plain English. One clarifying question max per ambiguity.
- **Runs daily** (not hourly — 8-day threshold checks don't need hourly cadence). Suggested: separate cron at 10am Pacific, or append to daily brief cron.
- **Shares stage IDs** with `crm-appointment-nudge`, `crm-appointment-outcome`, and `crm-daily-brief`. Keep in sync if pipeline is restructured.
- **Future:** when Nazar joins Telegram, add him as `TELEGRAM_TARGET_NAZAR` in constants, not hardcoded in message logic.
