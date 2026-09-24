# Genesys Cloud API Connector (optional)

`Get-GenesysNpsSurveyData.ps1` downloads the **last 7 days** of survey responses from
Genesys Cloud (the **Australia** region by default) and, with `-RunAudit`, audits them in one step.

```powershell
.\Get-GenesysNpsSurveyData.ps1 -RunAudit -ExportHtmlReport
```

You don't type the client ID or secret on each run. Either embed them once at the top of the
script, or set them once as environment variables.

> Independent community project. Not an official Genesys product, integration, or endorsement.
> The connector has been tested against a mocked API only. Validate it against a non-production org first.

---

## 1. Create a least-privilege OAuth client (one-time, Genesys Cloud admin)

1. In Genesys Cloud **Admin > Roles / Permissions**, create a role (for example
   `NPS Audit Read Only`) with only this permission:
   - **Analytics > Conversation Detail > View**
2. In **Admin > Integrations > OAuth**, add a client:
   - Grant type: **Client Credentials**
   - Role: the read-only role above (scoped to the divisions you need)
3. Note the Client ID and Client Secret. Treat the secret like a password.

## 2. Provide the credentials (one-time)

Choose **one** of the two options below. Embedded values take precedence when both are filled in.

### Option A: embed them in the script (simplest, you accept the risk)

Open `Get-GenesysNpsSurveyData.ps1`. Near the top, fill in:

```powershell
$EmbeddedClientId     = 'your-client-id'
$EmbeddedClientSecret = 'your-client-secret'
```

Then, in the repository folder, run this **once** so Git never picks up your edit:

```powershell
git update-index --skip-worktree Get-GenesysNpsSurveyData.ps1
```

- Anyone who can read the file can use the credentials. Keep the file on your machine only, and
  use the read-only OAuth client from step 1.
- Fill in both values or neither. If only one is filled in, the script stops with a clear error.
- The console shows a yellow warning and the masked client ID: `****ab12 (from embedded in script)`.
- The test suite checks that the committed copy has **empty** values, so it fails if real
  credentials are ever committed.
- To pull script updates later: run `git update-index --no-skip-worktree Get-GenesysNpsSurveyData.ps1`,
  stash your edit, pull, re-apply your edit, then run the `--skip-worktree` command again.

### Option B: environment variables (recommended for shared or managed machines)

Leave the embedded values empty and set these instead:

| Variable | Required | Value |
|---|---|---|
| `GENESYS_CLIENT_ID` | Yes | OAuth client ID |
| `GENESYS_CLIENT_SECRET` | Yes | OAuth client secret |
| `GENESYS_REGION` | No | Overrides the region. Default: `mypurecloud.com.au` (Australia) |

Choose the option that fits your environment, from most to least preferred:

- **Managed by IT or a secret manager.** Your vault, deployment tool, Intune or GPO, or scheduled-task
  runner injects the variables into the process. Nothing is stored on the user profile.
- **Per-user environment variables through the Windows UI.** Run
  `rundll32 sysdm.cpl,EditEnvironmentVariables`, add both variables under *User variables*, and
  open a new PowerShell window. Using the UI keeps the secret out of PowerShell command history.

Avoid typing the secret on a PowerShell command line (`setx ...`, `$env:... = ...`). PSReadLine
saves command history to disk.

> Per-user environment variables are stored unencrypted in the user's registry profile, which only
> that user (and administrators) can read. Use them only with the read-only OAuth client from
> step 1. Where policy requires encryption at rest, use a secret manager that injects the variables.

The script:

- never prompts for credentials
- refuses to run if `config/genesys-connector.json` contains anything that looks like a credential
- prints only the last 4 characters of the client ID
- never writes the secret or the access token to the console, CSV, or report
- clears credential and token variables as soon as they are no longer needed

## 3. Automatic survey detection (nothing to configure)

You don't supply conversation IDs or attribute names. The connector scans **every conversation**
in the date range and works out for itself which ones contain an NPS survey.

**a) Flow-based voice or bot surveys (participant data).** Architect survey flows store their
results as participant data. Any participant-data key matching
`survey | nps | csat | post-call | feedback` (case-insensitive) is treated as survey data. Its
role is then inferred from the rest of the key name:

| Role | Recognised when the key contains | Examples |
|---|---|---|
| Utterance | utterance, transcript, verbatim, speech, spoken, said, response text; or `answer` with a text value | `Survey.Utterance`, `PostCall_NPS_Transcript`, `NPS.Answer` = "ten out of ten" |
| Score | score, rating, value, `nps`; or `answer` / `result` with a numeric value | `Survey.Score`, `NPS_Score`, `NPS`, `CSAT.Rating` |
| Confidence | confidence | `Survey.Confidence`, `NPS.ASRConfidence` |
| Status | status, state, result, outcome, disposition, completed, finished | `Survey.Status`, `PostCall_NPS_Result` |
| Opt-in | opt in / opt out, consent, accept, offered | `Survey.OptIn` |
| Question / Survey ID | question, prompt / survey id | `Survey.Question`, `Survey.Id` |

Keys that hold counters, timestamps or flow bookkeeping (`AttemptCount`, `StartTime`,
`FlowVersion`, ...) are ignored. So are keys that don't match the pattern, such as `LeadScore`
or `Customer.Tier`, so other scores in your org are not mistaken for NPS.

**b) Genesys Cloud native web surveys.** Conversations whose `surveys` array has a survey with
status `Finished` and a `surveyPromoterScore` are included, with channel `Web survey`. The
customer selected the score directly, so the selected value is used as the answer.

**Completed or not?** Each detected survey is classified:

| Detected state | How | In the export |
|---|---|---|
| Completed | Status such as Completed, Finished, Success, Answered, Submitted; or no status but a score or utterance exists. A `NoInput` / `NoMatch` status also counts as completed, and the audit reports it as No input or Ambiguous response | Yes |
| Incomplete | Status such as Timeout, Disconnected, HangUp, Abandoned, Expired, Partial; or survey data exists but nothing was answered | Yes, as audit findings. Excluded with `-CompletedOnly` |
| Declined | Status such as Declined, OptOut, Refused, Skipped; or an opt-in of No/False with no answer | No (not a response) |
| Unknown | Any other status value | Yes; the audit flags it as Review required |

The console shows what was detected, so you can check it at a glance:

```text
Survey detection
  Conversations scanned : 1840
  Surveys detected      : 226
    Completed           : 212
    Incomplete          : 11  (timeout / disconnect / abandoned)
    Declined (excluded) : 3
  Keys recognised:
    Score=PostCall_NPS_Score                         214 conversation(s)
    Utterance=PostCall_NPS_Transcript                214 conversation(s)
    Confidence=PostCall_NPS_Confidence               209 conversation(s)
    Status=PostCall_NPS_Result                       226 conversation(s)
```

**Tuning (only if needed).** If your flow's keys don't contain any of the survey keywords, copy
`config/genesys-connector.example.json` to `config/genesys-connector.json` (git-ignored). Then
either change `surveyKeyPattern`, or pin exact key names under `attributes` (leave a value empty
to keep auto-detecting it). Pinned keys are used even if they don't match the pattern.

## 4. Run it

```powershell
# Last 7 days, Australia, download + audit + HTML report
.\Get-GenesysNpsSurveyData.ps1 -RunAudit -ExportHtmlReport

# Download only (audit later)
.\Get-GenesysNpsSurveyData.ps1

# Only surveys the customer completed (leave out timeouts / disconnects)
.\Get-GenesysNpsSurveyData.ps1 -CompletedOnly -RunAudit

# Restrict to specific queues
.\Get-GenesysNpsSurveyData.ps1 -QueueId "<queue-guid-1>","<queue-guid-2>" -RunAudit

# A different look-back window (1-31 days)
.\Get-GenesysNpsSurveyData.ps1 -Days 14 -RunAudit
```

How it works:

1. `POST https://login.mypurecloud.com.au/oauth/token` (client credentials; Basic auth header
   built with a pure-PowerShell Base64 encoder, so it is CLM-safe). The response is checked for an
   `access_token` before continuing.
2. The last 7 days are split into seven one-day UTC intervals, ending at the current minute.
3. `POST https://api.mypurecloud.com.au/api/v2/analytics/conversations/details/query` runs for each
   day, 100 conversations per page, following pagination.
4. Rate limits (HTTP 429) and transient 5xx errors are retried with backoff. A 401 or 403 stops
   the run with a clear message.
5. Every conversation is checked for survey data (section 3). Detected surveys, minus declined
   ones, are written to `output/genesys-survey-export-YYYYMMDD-HHMMSS.csv`.
6. With `-RunAudit`, `Export-GenesysNpsAudit.ps1` runs on that file.

Example console output (fictional):

```text
Region               : mypurecloud.com.au  (from default (Australia))
OAuth client         : ****9f2c  (from GENESYS_CLIENT_ID)
Date range (UTC)     : 2026-09-16T10:15:00.000Z  ->  2026-09-23T10:15:00.000Z  (7 day(s))

Authenticated.
  2026-09-16  conversations:   1840   survey responses:   212
  ...
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected error |
| 2 | Configuration error: missing environment variable, credential found in the config file, invalid config or region |
| 3 | Authentication or API error |
| other | Passed through from the audit when `-RunAudit` is used |

## Troubleshooting

| Symptom | Check |
|---|---|
| `Missing environment variable(s)` | Open a **new** PowerShell window after setting the variables |
| HTTP 401 | Client ID/secret, the Client Credentials grant type, and the region |
| HTTP 403 | The role has **Analytics > Conversation Detail > View** for the right divisions |
| `No surveys detected` | Your flow's participant-data keys may not contain survey/nps/csat/post-call/feedback. Set `surveyKeyPattern`, or pin `attributes` in the config |
| A key is detected in the wrong role | Pin the correct key under `attributes` in the config |
| TLS or "could not create SSL/TLS secure channel" on Windows PowerShell 5.1 | Ask IT to enable strong cryptography for .NET (`SchUseStrongCrypto`). The script does not change `ServicePointManager`, because that is a .NET static call blocked in CLM |
| Very large orgs | Use `-QueueId` to narrow the query. The query stops at 500 pages per day with a warning |

## Data handling

The downloaded CSV and the reports contain **real customer data**. They are written to `output/`,
which is git-ignored. Delete them when you are finished, and never attach them to issues or pull
requests. See [privacy-and-security.md](privacy-and-security.md).
