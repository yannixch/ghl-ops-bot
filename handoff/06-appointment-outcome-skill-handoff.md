# Handoff — Build `crm-appointment-outcome` Skill

**Created:** 2026-06-23 · **Owner:** Yannis Choglo · **Client:** Paliy Renovations Inc  
**Execute via:** Claude Code (this project)

---

## Context

The existing `crm-appointment-nudge` skill fires 50 minutes after an appointment start time and sends Yannis a Telegram nudge if the deal is still in "Appointment Set." That skill is read-only — it asks but never closes the loop.

This skill (`crm-appointment-outcome`) is the write-back companion. It handles the conversational reply from Yannis (and eventually Nazar), collects the three required data points, and updates GHL accordingly.

**For now, Yannis is the only recipient.** Nazar is NOT on Telegram yet. Yannis will test this himself until it's working perfectly, then we'll add Nazar directly.

---

## Also do in this session: update `crm-appointment-nudge`

Before building the new skill, update the nudge skill threshold:

- **File:** `.claude/skills/crm-appointment-nudge/SKILL.md` AND `skills/crm-appointment-nudge/SKILL.md`
- **Change:** `NUDGE_AFTER_HOURS = 3` → `NUDGE_AFTER_MINUTES = 50`
- **Also update:** the nudge message template — change "3h+ ago" to "50 minutes ago"
- **Also update:** the skill description and purpose text to reflect 50 minutes
- After updating both files, push to GitHub and tell Yannis to run `hermes skills update` in the Hermes CLI.

---

## Skill Spec — `crm-appointment-outcome`

### What it does
Conducts a short conversational interview via Telegram after each appointment, collects 3 data points, and updates the opportunity in GHL.

### Conversation flow

**Trigger:** Yannis replies to a nudge message (or Hermes detects an inbound message referencing an appointment outcome).

**Three data points to collect (in order):**

1. **Did the appointment happen?**
2. **Are we pursuing this lead?** (only asked if yes to #1)
3. **Rough project estimate ($)?** (only asked if pursuing)

---

### Branch: Appointment happened

```
Hermes: Did it happen?
Yannis: yes / yeah / he showed up / etc.

Hermes: Are we pursuing it?
Yannis: yes / no / maybe / not sure

  If NO / passing:
    Hermes: Got it — lost or nurture?
    Yannis: lost / nurture / drop it / etc.
    → GHL: mark lost OR move to Nurture stage
    → Done.

  If YES / pursuing:
    Hermes: Rough estimate on the project?
    Yannis: ~22k / about 15 thousand / "probably 30" / etc.
    → GHL: move to "Send out Estimate" + set monetaryValue
    → Done.
```

### Branch: Appointment did NOT happen

```
Hermes: Did it happen?
Yannis: no / no-show / they cancelled / etc.

Hermes: Did they already reschedule, do you want me to move it to reschedule, or are we dropping it?
Yannis: [one of three answers]

  "Already rescheduled" / they rescheduled themselves:
    → GHL: move to Cancellation/Reschedule stage + add tag "rescheduled"
    → Done.

  "Move it to reschedule" / reschedule it:
    → GHL: move to Cancellation/Reschedule stage (automations on that stage handle the rest — Hermes does NOT book a new appointment)
    → Done.

  "Drop it" / not worth it / lost / etc.:
    Hermes: Lost or nurture?
    Yannis: lost / nurture
    → GHL: mark lost OR move to Nurture stage
    → Done.
```

### Natural language
Yannis and Nazar can reply in plain English. Hermes uses LLM reasoning to parse intent — no specific syntax required. If the reply is ambiguous, Hermes asks a single clarifying follow-up rather than guessing.

---

## GHL Actions (write operations)

All writes use `opportunities_update-opportunity` via the `gohighlevel-paley` MCP.

| Outcome | pipelineStageId | status | monetaryValue | tag |
|---------|----------------|--------|---------------|-----|
| Pursuing + estimate | `df5552df-2227-4b16-94a0-98cb19bfdc5e` (Send out Estimate) | open | parsed $ amount | — |
| Not pursuing → lost | — | lost | — | — |
| Not pursuing → nurture | `8d809805-5e66-4f46-99ad-f722b33ff08b` (Nurture) | open | — | — |
| No-show, already rescheduled | `59f217ce-83c1-4b5d-b39b-f4509539686e` (Cancellation/Reschedule) | open | — | `rescheduled` |
| No-show, reschedule it | `59f217ce-83c1-4b5d-b39b-f4509539686e` (Cancellation/Reschedule) | open | — | — |
| No-show → lost | — | lost | — | — |
| No-show → nurture | `8d809805-5e66-4f46-99ad-f722b33ff08b` (Nurture) | open | — | — |

Pipeline ID (Customer Journey): `zEfi70fS2rNS3wFnYN1a`  
Location ID: `SBWsCsOvoKci7htWODay`

---

## Follow-up cadence (no response)

- If no reply received: follow up every **3 hours**
- Stop after **48 hours** (16 follow-ups max), then drop silently — no flagging to Yannis
- Follow-up message should be brief: just a reminder that the question is still open, referencing the lead name
- State file tracks: opportunity ID, nudge timestamp, follow-up count, conversation state

---

## State management

The skill needs a state file to track active outcome conversations. Suggested: `state/outcome-conversations.json`

Each entry:
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

Remove entry from state when conversation reaches `complete` or when 48-hour window expires.

---

## Skill file locations

Write the skill to BOTH locations (they must be identical):
1. `.claude/skills/crm-appointment-outcome/SKILL.md` — for Claude Code
2. `skills/crm-appointment-outcome/SKILL.md` — for GitHub tap (Hermes deployment)

After writing both files, push to GitHub and tell Yannis:
> "Skill written. Run these in the Hermes CLI to deploy:
> `hermes skills update` (if tap already added)
> or `hermes skills install crm-appointment-outcome` (if first install)"

---

## Skill metadata to use

```yaml
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
```

---

## Reference — existing skill structure

Model the structure after `crm-appointment-nudge/SKILL.md` — same constants block, same phase structure. Key difference: this skill has write operations where the nudge is read-only.

Constants block should include all stage IDs from the GHL actions table above.

---

## Safety notes

- Always confirm the opportunity ID before writing. If the conversation context is ambiguous (Yannis mentions a name but there are multiple contacts), search and confirm before updating.
- If GHL update fails, log the error in the state file and tell Yannis in Telegram what went wrong. Do not silently swallow errors.
- Do not update any opportunity not associated with an active outcome conversation in state.
- The 48-hour window applies from the time of the original nudge, not from the last follow-up.
