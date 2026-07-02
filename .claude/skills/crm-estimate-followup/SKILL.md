---
name: crm-estimate-followup
description: Use when following up on estimates that haven't been sent or acknowledged after 8 days. Handles two scenarios — estimate not yet sent (still in Send out Estimate) and estimate sent but no decision (Pending/Estimate Sent). Conducts conversational follow-up with Yannis and writes result back to GHL.
user-invocable: true
allowed-tools: [Read, Write, Bash]
metadata:
  version: 0.3.0
  domains: [crm, pipeline-hygiene, gohighlevel, write-back]
  type: utility
  client: paley-renovations
  inputs: [gohighlevel-mcp, telegram-mcp]
  outputs: [telegram-message, ghl-opportunity-update]
  status: active
---

# CRM Estimate Follow-Up — Paley Renovations

**Purpose:** Catches estimates stuck unsent or unacknowledged and asks Yannis what's going on. Writes the result back to GHL — no dashboard login needed.

**Scenario A** (Send out Estimate stage): checked daily — estimate not sent is urgent.
**Scenario B** (Pending / Estimate Sent stage): checked weekly — one consolidated Telegram message, numbered list, Yannis replies with statuses.

**Trigger:** Daily cron (10am Pacific). Also triggered when Yannis replies to a follow-up message.

**Write-enabled.**

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
STATE                      = state/estimate-followup.json
DAYS_THRESHOLD             = 8
SCENARIO_B_SWEEP_DAYS      = 7   ← minimum days between Scenario B consolidated messages
SCENARIO_A_MAX_FOLLOWUP_H  = 48  ← drop Scenario A entry if no reply after 48h
SCENARIO_A_INTERVAL_H      = 3   ← re-ping Scenario A every 3h until replied or dropped
```

---

## State schema

```json
{
  "_meta": {
    "lastScenarioBSweepAt": "ISO timestamp or null",
    "scenarioBList": ["oppId1", "oppId2", ...]
  },
  "<opportunityId>": {
    "opportunityId": "...",
    "contactName": "...",
    "monetaryValue": 0,
    "scenario": "A | B",
    "triggerDate": "ISO timestamp",
    "followUpCount": 0,
    "lastFollowUpAt": "ISO timestamp or null",
    "conversationState": "awaiting_sent | awaiting_amount | awaiting_decision | awaiting_ghosting_action | awaiting_lost_nurture | awaiting_snooze_date | snoozed | complete",
    "snoozedUntil": "ISO timestamp or null"
  }
}
```

`_meta.scenarioBList` is the ordered array used for the current consolidated message. Index 0 = lead #1, index 1 = lead #2, etc. Rebuilt each time a new sweep message is sent.

Remove an opportunity entry when `conversationState = complete`. Snoozed entries stay in STATE and re-trigger on `snoozedUntil`.

---

## Logic

### Phase 0 — Bootstrap
1. Confirm `gohighlevel-paley` + `telegram` MCP servers available. If GHL missing → stop with clear error.
2. Load `STATE`. If file doesn't exist, initialize as `{ "_meta": { "lastScenarioBSweepAt": null, "scenarioBList": [] } }`.

---

### Phase 1 — Scan (cron mode, no incoming reply)

#### Step 1a — Wake up snoozed Scenario A entries
For each STATE entry where `scenario = A` and `conversationState = snoozed`:
- If `now >= snoozedUntil`: reset `conversationState = awaiting_sent`, clear `snoozedUntil`, reset `triggerDate = now`, send the Scenario A trigger message for that lead.
- Otherwise: skip.

#### Step 1b — Scan GHL for new Scenario A candidates
`opportunities_search-opportunity` where `pipelineStageId = SEND_ESTIMATE_STAGE_ID`:
- For each result where `now - lastStageChangeAt >= DAYS_THRESHOLD` AND opportunityId not in STATE:
  - Add STATE entry: `scenario = A`, `conversationState = awaiting_sent`, `triggerDate = now`.
  - Send Scenario A trigger message immediately (one per lead — these are urgent).

**Scenario A trigger message:**
```
[Contact name]'s estimate hasn't gone out yet ([N] days in Send out Estimate). Has it been sent?
```

#### Step 1c — Scenario B sweep (weekly gate)
Check `_meta.lastScenarioBSweepAt`. If `now - lastScenarioBSweepAt < SCENARIO_B_SWEEP_DAYS`: skip steps 1c and 1d entirely.

#### Step 1d — Collect Scenario B candidates
Collect into a single list (do not send individual messages):

1. Snoozed Scenario B entries where `now >= snoozedUntil`:
   - Reset `conversationState = awaiting_decision`, clear `snoozedUntil`, reset `triggerDate = now`.
   - Include in this week's list.

2. GHL scan — `opportunities_search-opportunity` where `pipelineStageId = PENDING_ESTIMATE_STAGE_ID`:
   - For each result where `now - lastStageChangeAt >= DAYS_THRESHOLD` AND opportunityId not in STATE:
     - Add STATE entry: `scenario = B`, `conversationState = awaiting_decision`, `triggerDate = now`, `monetaryValue = monetaryValue from GHL (0 if unset)`.
     - Include in this week's list.

If the list is empty: skip. Do not send a message.

If the list has entries:
- Build `_meta.scenarioBList` from the collected opportunity IDs (in order).
- Set `_meta.lastScenarioBSweepAt = now`.
- Send ONE consolidated Telegram message (see format below).

**Scenario B consolidated message format:**
```
Estimate check-in — any updates? ([N] leads)

1. [Name] — $[Xk] ([D]d)
2. [Name] — $[Xk] ([D]d)
...

Reply: [#] approved / lost / nurture / ghosting / snooze [time]
Skip any you're not sure on — I'll check back next week.
```

Format rules:
- Monetary value: round to nearest $1k, display as `$Xk` (e.g. `$49k`). If 0 or unset, omit the amount.
- Days: `lastStageChangeAt` to today, rounded down.
- Numbers are 1-indexed. Pad list with leading numbers only (no extra punctuation).

---

### Phase 2 — Handle Yannis's reply

Determine mode from context:
- If there are active Scenario A entries in STATE with `conversationState != snoozed AND != complete` → reply is for Scenario A (per-lead conversation, see Section A below).
- If `_meta.scenarioBList` is non-empty and there are active Scenario B entries → reply is for Scenario B (batch parse, see Section B below).
- If both are active: parse which scenario the reply addresses from context (numbered reply = Scenario B; name-based reply = Scenario A).

---

#### Section A — Scenario A per-lead conversation

One active conversation at a time. Use the contact name from STATE to anchor context.

##### `awaiting_sent`
- **Yes, sent** → set `conversationState = awaiting_amount`, ask: `What's the estimate amount?`
- **No, not sent / still working on it** → ask: `Got it — when should I check back on this?` → `conversationState = awaiting_snooze_date`
- **Lost / drop it** → `conversationState = awaiting_lost_nurture`, ask: `Lost or nurture?`
- Ambiguous → one clarifying question.

##### `awaiting_amount`
Parse dollar amount from plain English (`~22k` → 22000, `about 15 thousand` → 15000, `TBD / not sure` → omit).

**Write to GHL:** `pipelineStageId = PENDING_ESTIMATE_STAGE_ID`, `status = open`, `monetaryValue` if known.

**Confirm:** `Got it — moved [Name] to Pending / Estimate Sent[$Xk]. ✓`
→ `conversationState = complete`, remove from STATE.

---

#### Section B — Scenario B batch reply

Parse one or more numbered statuses from the reply. Examples:
- `1 approved` → lead #1 approved
- `3 lost, 5 snooze 2 weeks, 7 ghosting` → three updates in one message
- `2 nurture` → lead #2 to nurture

For each parsed update, look up the opportunity via `_meta.scenarioBList[index - 1]`.

**Status actions:**

| Reply | GHL write | Confirm |
|-------|-----------|---------|
| approved | `pipelineStageId = APPROVED_STAGE_ID`, `status = open` | `[Name] → Approved ✓` |
| lost | `status = lost` | `[Name] → Lost ✓` |
| nurture | `pipelineStageId = NURTURE_STAGE_ID`, `status = open` | `[Name] → Nurture ✓` |
| ghosting | `pipelineStageId = GHOSTING_STAGE_ID`, `status = open` | `[Name] → Ghosting ✓` |
| snooze [time] | parse date, set `snoozedUntil`, `conversationState = snoozed` | `[Name] → snoozed until [date] ✓` |

Send ONE confirmation message covering all updates processed in the reply:
```
Done —
- Tina Rice → Approved ✓
- Pat Lords → Ghosting ✓
- Colby Johnson → snoozed until Jul 13 ✓
```

Entries not mentioned: leave as-is (`conversationState = awaiting_decision`). They'll be included in next week's sweep if still unresolved.

**Snooze date parsing:**
- "in 3 days" → now + 3 days
- "next Tuesday" → upcoming Tuesday at 10am Pacific
- "a week / give me a week" → now + 7 days
- "end of the week" → upcoming Friday at 10am Pacific
- "tomorrow" → tomorrow at 10am Pacific
- Unparseable → one clarifying question: `When should I check back on [Name]? (e.g. "in 3 days", "next Tuesday")`

If a snooze entry re-triggers: reset `triggerDate = now` so state is fresh.

---

### Phase 3 — Scenario A follow-up cadence (no reply received)

Only applies to Scenario A entries. Run during daily cron after Phase 1:

1. Find Scenario A entries where `conversationState != complete AND != snoozed`.
2. For each:
   - If `now - triggerDate > SCENARIO_A_MAX_FOLLOWUP_H`: remove entry silently. Do not ping Yannis.
   - Else if `now - lastFollowUpAt >= SCENARIO_A_INTERVAL_H` (or `lastFollowUpAt` is null and `now - triggerDate >= SCENARIO_A_INTERVAL_H`):
     - Send: `Still waiting — did [Name]'s estimate go out?`
     - Increment `followUpCount`, set `lastFollowUpAt = now`.

Scenario B entries do NOT get follow-up pings between weekly sweeps. They wait for the next sweep.

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

- Always confirm opportunity ID via `_meta.scenarioBList` before writing. Never write based on name alone.
- If a GHL update fails: log error in STATE entry, tell Yannis via Telegram what failed and which lead. Never swallow errors silently.
- Never update an opportunity not in STATE.
- Yannis is the only recipient. Nazar is NOT on Telegram yet.
- Scenario B entries do NOT have a `MAX_FOLLOWUP_HOURS` drop window — they persist in STATE until resolved or snoozed.

---

## Notes

- **Write-enabled** — makes live GHL updates.
- **LLM-native parsing** — no regex. Parse intent from plain English. One clarifying question max per ambiguity.
- **Scenario B is weekly, Scenario A is daily** — the daily cron runs both, but the skill gates Scenario B behind the 7-day check.
- **Batch reply is the primary UX for Scenario B** — Yannis sees one message, replies once, everything gets written. Unlisted leads wait for next week.
- **Future:** when Nazar joins Telegram, add him as `TELEGRAM_TARGET_NAZAR`. Do not hardcode in message logic.
