---
name: crm-estimate-followup
description: Use when following up on estimates that haven't been sent or acknowledged after 8 days. Handles two scenarios — estimate not yet sent (still in Send out Estimate) and estimate sent but no decision (Pending/Estimate Sent). Conducts conversational follow-up with Yannis and writes result back to GHL.
user-invocable: true
allowed-tools: [Read, Write, Bash]
metadata:
  version: 0.2.0
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
  "conversationState": "awaiting_sent | awaiting_amount | awaiting_decision | awaiting_ghosting_action | awaiting_lost_nurture | awaiting_snooze_date | snoozed | complete",
  "snoozedUntil": "ISO timestamp or null"
}
```

Remove entry when `conversationState = complete` or when `now - triggerDate > MAX_FOLLOWUP_HOURS`.
**Snoozed entries (`conversationState = snoozed`) are exempt from the MAX_FOLLOWUP_HOURS drop** — they re-trigger on `snoozedUntil` instead.

---

## Logic

### Phase 0 — Bootstrap
1. Confirm `gohighlevel-paley` + `telegram` MCP servers available. If GHL missing → stop with clear error.
2. Load `STATE`. If file doesn't exist, initialize as `{}`.

### Phase 1 — Scan for stale opportunities (daily cron mode)

**First, check snoozed entries before scanning GHL:**
- For each entry where `conversationState = snoozed`:
  - If `now >= snoozedUntil`: reset `conversationState` to the pre-snooze state for that scenario (`awaiting_sent` for Scenario A, `awaiting_decision` for Scenario B), clear `snoozedUntil`, and re-send the original trigger message.
  - Otherwise: skip (still sleeping).

**Then scan GHL for new candidates:**

1. `opportunities_search-opportunity` filtering by `pipelineId = PIPELINE_ID` and `pipelineStageId = SEND_ESTIMATE_STAGE_ID`. For each result:
   - If `now - lastStageChangeAt >= DAYS_THRESHOLD days` AND opportunityId not already in STATE → create STATE entry with `scenario = A`, `conversationState = awaiting_sent`, `snoozedUntil = null`, send Scenario A message.

2. Repeat for `pipelineStageId = PENDING_ESTIMATE_STAGE_ID`:
   - If `now - lastStageChangeAt >= DAYS_THRESHOLD days` AND not in STATE → create entry with `scenario = B`, `conversationState = awaiting_decision`, `snoozedUntil = null`, send Scenario B message.

**Scenario A message (Send out Estimate — estimate not sent):**
```
Hey — [Contact name]'s estimate hasn't gone out yet (they've been in this stage for [N] days).
Has it been sent?
```

**Scenario B message (Pending / Estimate Sent — awaiting decision):**
```
[Contact name]'s estimate has been out for [N] days, any update on the estimate?
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
  - "will handle / on it / sending soon / I'll do it" → set `conversationState = awaiting_snooze_date`, ask immediately:
    ```
    Got it — when should I check back in on this?
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
- **Follow up / reach out** → set `conversationState = awaiting_snooze_date`, ask immediately:
  ```
  Got it — when should I check back in on this?
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

#### Shared state: `awaiting_snooze_date`

Waiting for: when to check back in.

Parse reply as a future date/time from plain English:
- "in 3 days" → now + 3 days
- "next Tuesday" → upcoming Tuesday at 10am Pacific
- "a week" / "give me a week" → now + 7 days
- "end of the week" → upcoming Friday at 10am Pacific
- "tomorrow" → tomorrow at 10am Pacific
- "never / forget it / drop it" → treat as intent to abandon; ask "Lost or nurture?" instead

If parsed successfully:
- Set `snoozedUntil = resolved ISO timestamp`, `conversationState = snoozed`
- Confirm:
  ```
  Got it — I'll check back on [Contact name] on [date]. ✓
  ```
- Do NOT remove from STATE (entry stays to re-trigger on `snoozedUntil`).

If reply is ambiguous or unparseable → one clarifying follow-up:
```
When exactly should I follow up? (e.g. "in 3 days", "next Tuesday")
```

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
1. Load `STATE`, find entries where `conversationState != complete` AND `conversationState != snoozed`.
2. For each entry:
   - If `now - triggerDate > MAX_FOLLOWUP_HOURS`: remove entry silently. Do not ping Yannis.
   - Else if `now - lastFollowUpAt >= FOLLOWUP_INTERVAL_HOURS` (or `lastFollowUpAt` is null and `now - triggerDate >= FOLLOWUP_INTERVAL_HOURS`):
     - Send brief follow-up via Telegram based on scenario:
       - Scenario A: `Still waiting — did [Contact name]'s estimate go out?`
       - Scenario B: `Still waiting — any update on [Contact name]'s estimate?`
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
- The 48-hour drop window is measured from `triggerDate` and does NOT apply to snoozed entries.
- Yannis is the only recipient. Nazar is NOT on Telegram yet.
- Skip an opportunity in STATE if it already has `conversationState = complete` — do not re-trigger.
- When a snoozed entry re-triggers, reset `triggerDate = now` so the 48-hour drop window is fresh.

---

## Notes

- **Write-enabled** — makes live GHL updates. Double-check opportunity ID before every write.
- **LLM-native parsing** — no regex required. Parse intent from plain English. One clarifying question max per ambiguity.
- **Runs daily** (not hourly — 8-day threshold checks don't need hourly cadence). Suggested: separate cron at 10am Pacific, or append to daily brief cron.
- **Snooze re-trigger resets the drop window** — `triggerDate` is updated on wake-up so the 48h cadence is measured from the new conversation, not the original.
- **Shares stage IDs** with `crm-appointment-nudge`, `crm-appointment-outcome`, and `crm-daily-brief`. Keep in sync if pipeline is restructured.
- **Future:** when Nazar joins Telegram, add him as `TELEGRAM_TARGET_NAZAR` in constants, not hardcoded in message logic.
