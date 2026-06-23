# Handoff — Build `crm-estimate-followup` Skill

**Created:** 2026-06-23 · **Owner:** Yannis Choglo · **Client:** Paliy Renovations Inc  
**Execute via:** Claude Code (this project)

---

## Context

This is a companion skill to `crm-appointment-outcome`. After an appointment happens and the lead moves to "Send out Estimate," someone needs to actually send the estimate — and then follow up to get a decision. In practice, estimates sit unsent or unacknowledged for days. This skill closes that loop automatically.

**The trigger:** 8 days after the appointment date, if the opportunity is still in "Send out Estimate" OR "Pending / Estimate Sent" without a recorded monetary value or recent activity, Hermes reaches out to Yannis (Nazar later) and asks what's going on.

**For now, Yannis is the only recipient.** Nazar is NOT on Telegram yet.

---

## Skill overview

**Name:** `crm-estimate-followup`

**What it does:** 8 days after an appointment, Hermes checks whether the estimate has been sent (stage = "Send out Estimate" means not sent yet; stage = "Pending / Estimate Sent" means sent but awaiting decision). It reaches out to Yannis to get a status update and writes the result back to GHL.

**Two scenarios this skill handles:**

### Scenario A — Estimate not yet sent (still in "Send out Estimate")

Trigger: deal has been in "Send out Estimate" for 8+ days since the appointment date.

```
Hermes: Hey — [Contact name]'s estimate hasn't gone out yet (appointment was [date], 8 days ago).
        Has it been sent?

  YES, sent:
    Hermes: What's the estimate amount?
    Yannis: $X
    → GHL: move to "Pending / Estimate Sent", set monetaryValue = $X
    → Done.

  NO, not sent yet:
    Hermes: Want me to flag this, or is it being handled?
    Yannis: [free text — will handle / remind me / drop it]
    → Parse intent:
      "will handle / on it / sending soon" → log note, no GHL change, stop
      "drop it / not happening / lost" → Hermes: "Lost or nurture?"
        lost → mark lost
        nurture → move to Nurture
    → Done.

  LOST / not pursuing:
    Hermes: Lost or nurture?
    → mark lost OR move to Nurture
    → Done.
```

### Scenario B — Estimate sent, awaiting decision (in "Pending / Estimate Sent")

Trigger: deal has been in "Pending / Estimate Sent" for 8+ days since the estimate was sent (use `lastStageChangeAt` as proxy if no sent-date field exists).

```
Hermes: [Contact name]'s estimate has been out for 8+ days — any word from them?

  YES, they approved / moving forward:
    Hermes: Move them to Approved?
    Yannis: yes / yep / do it
    → GHL: move to "Approved / to be Scheduled"
    → Done.

  NO, no response / ghosting:
    Hermes: Want to follow up with them, move to Ghosting, or drop it?
    Yannis: [one of three]
      "follow up / reach out" → log note, no GHL change, stop
      "ghosting / move to ghosting" → move to Ghosting stage
      "drop / lost / not happening" → Hermes: "Lost or nurture?" → mark accordingly
    → Done.

  LOST / not pursuing:
    Hermes: Lost or nurture?
    → mark lost OR move to Nurture
    → Done.
```

---

## GHL constants (verified 2026-06-23)

```
PIPELINE_ID              = zEfi70fS2rNS3wFnYN1a   (Customer Journey)
SEND_ESTIMATE_STAGE_ID   = df5552df-2227-4b16-94a0-98cb19bfdc5e
PENDING_ESTIMATE_STAGE_ID = 4adcfcbb-2ad1-4bb0-b735-c9734d60a850
APPROVED_STAGE_ID        = cb5ccf70-9738-47fb-80bc-06c3c3623c97
GHOSTING_STAGE_ID        = 3e7608ea-39d0-4fbf-96e8-a3ce3476d785
NURTURE_STAGE_ID         = 8d809805-5e66-4f46-99ad-f722b33ff08b
LOCATION_ID              = SBWsCsOvoKci7htWODay
TELEGRAM_TARGET          = 8519030231   (Yannis)
DAYS_THRESHOLD           = 8
STATE                    = state/estimate-followup.json
FOLLOWUP_INTERVAL_HOURS  = 3
MAX_FOLLOWUP_HOURS       = 48
```

---

## GHL write reference

| Outcome | pipelineStageId | status | monetaryValue |
|---------|----------------|--------|---------------|
| Estimate sent → pending | `4adcfcbb-2ad1-4bb0-b735-c9734d60a850` | open | parsed $ |
| Approved | `cb5ccf70-9738-47fb-80bc-06c3c3623c97` | open | — |
| Ghosting | `3e7608ea-39d0-4fbf-96e8-a3ce3476d785` | open | — |
| Lost | — | lost | — |
| Nurture | `8d809805-5e66-4f46-99ad-f722b33ff08b` | open | — |

---

## Follow-up cadence (same as appointment-outcome)

- If no reply: follow up every **3 hours**
- Stop after **48 hours**, then drop silently — no flagging to Yannis

---

## State schema

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

---

## How to determine the 8-day trigger

**Scenario A (Send out Estimate stage):**
Use `lastStageChangeAt` on the opportunity — if it's been in this stage for 8+ days, trigger.

**Scenario B (Pending / Estimate Sent stage):**
Use `lastStageChangeAt` — if it's been in this stage for 8+ days, trigger.

Both use the same field; the scenario just depends on which stage they're currently in.

---

## Cadence / cron

This skill should run **daily** (not hourly — checking 8-day thresholds hourly is wasteful). Suggested: run it as part of the daily brief cron, or as a separate daily cron at a different time (e.g. 10am Pacific).

---

## Skill file locations

Write to BOTH:
1. `.claude/skills/crm-estimate-followup/SKILL.md`
2. `skills/crm-estimate-followup/SKILL.md`

After writing, push to GitHub and tell Yannis:
> "Run `hermes skills install crm-estimate-followup` in the Hermes CLI."

---

## Skill metadata

```yaml
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
```

---

## Reference

Model structure after `crm-appointment-outcome/SKILL.md` — same phase structure (Bootstrap → Find candidates → Conversational interview → Write-back → Follow-up cadence). Key difference: this runs daily on a timer, not triggered by a Telegram reply.

Natural language parsing rules same as `crm-appointment-outcome`: plain English, one clarifying question max per ambiguity, never guess.
