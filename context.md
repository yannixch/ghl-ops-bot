# Client Context — Paley Renovations

## Business
- **Type:** Kitchen & bath remodeling company.
- **Relationship:** Flagship client of Yannis's agency (The Marketing Dept), which runs Paley's entire marketing dept — leads + CRM. Whatever is built here becomes the template resold to other remodeling clients.
- **Lead sources:** Paid ads (Facebook/Google) + organic/referral.
- **Speed-to-lead:** an AI SMS bot (**Appointwise**, `meta.marketplace.appName`) texts new leads automatically.
- **Calling:** an **appointment setter is being hired** to call leads (calls placed through GHL's dialer; recorded). Until hired, **Yannis plays the setter**.

## Team
- **Yannis** — runs marketing + CRM. Telegram `@Yanix_GL`, id `8519030231`. Owns **New Lead** stale alerts.
- **Nazar** — **estimator + project manager**; attends the in-home kitchen/bath appointments and manages jobs. Primary consumer of summaries + pipeline nudges. Owns **Appointment Set → Scheduled**.
- Other PMs may join later (route Appointment-Set nudges to them too).

## Pipeline — "Customer Journey" (`zEfi70fS2rNS3wFnYN1a`)
> ⚠️ **Pipeline is being re-hauled ~week of 2026-06-15.** Stage IDs below are PRE-rehaul and WILL change — re-pull `opportunities_get-pipelines` after the rehaul and update everywhere. As of 2026-06-10 the pipeline was ~1yr stale (54 in Appointment Set, 44 in New Lead, 0 in estimate/approved stages).

| Stage | ID (pre-rehaul) | Assistant's job |
|-------|-----------------|-----------------|
| Nurture | `8d809805-5e66-4f46-99ad-f722b33ff08b` | Holding for not-ready leads |
| New Lead | `f284ebf3-b7ce-44cd-af9b-2018cfecb704` | **Stale monitor → Yannis** |
| Cancellation / Reschedule | `59f217ce-83c1-4b5d-b39b-f4509539686e` | — |
| **Appointment Set** | `054ba5a3-70d4-42f4-b7fe-08dce954c6df` | 3h post-appt → ask Nazar: happened? outcome? pursue? est. $ → move to Nurture / Lost / Send out Estimate |
| **Send out Estimate** | `df5552df-2227-4b16-94a0-98cb19bfdc5e` | >7d → confirm estimate sent + quote $ → move to Pending/Estimate sent |
| **Pending / Estimate sent** | `4adcfcbb-2ad1-4bb0-b735-c9734d60a850` | Awaiting decision |
| Ghosting | `3e7608ea-39d0-4fbf-96e8-a3ce3476d785` | Re-engagement automations (future) |
| **Approved / to be Scheduled** | `cb5ccf70-9738-47fb-80bc-06c3c3623c97` | Ping Nazar to schedule → move to Scheduled |
| Scheduled | `2ac78707-4d68-43b8-9d1b-dfac1485fa1b` | Get start + expected end date → update opportunity |
| In Progress | `1b290a07-0030-4dab-978d-9f90cef3caf1` | — |
| Completed | `a334ca6d-9084-475e-814b-1a4b3783cc2a` | — |
| Newsletter | `69ba401f-c601-4401-8191-5da2f721daba` | — |
| UNQUALIFIED | `f5b211cd-33b7-4594-90ad-6cc2482a6430` | — |

**Other pipelines:** FB API LEADS `D9FwkFcjYFk9O0D7bLoG` · REACTIVATION `mIlo4sfxc8stU3t8qUja`.

## Connection
- Location ID: `SBWsCsOvoKci7htWODay` · PIT in `.mcp.json`.
- Message-type codes: `1`=CALL · `2`=SMS · `3`=EMAIL · `28`=ACTIVITY_OPPORTUNITY · `31`=ACTIVITY_APPOINTMENT.

## Open decisions (see handoff)
1. **Nazar's channel** for the write-back loop (SMS via GHL vs LeadConnector app vs Telegram). The team already uses the LeadConnector mobile app.
2. Stale thresholds per stage.
3. When to flip on writes (`opportunities_update-opportunity`).
