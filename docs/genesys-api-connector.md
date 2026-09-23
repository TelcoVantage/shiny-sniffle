# Genesys Cloud API Connector (optional)

`Get-GenesysNpsSurveyData.ps1` downloads the **last 7 days** of survey responses from
Genesys Cloud (the **Australia** region by default) and, with `-RunAudit`, audits them in one step.

```powershell
.\Get-GenesysNpsSurveyData.ps1 -RunAudit -ExportHtmlReport
```

You never type or embed a client ID or secret. The script reads them from environment variables
that are set once, outside the code.

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

## 2. Provide the credentials as environment variables (one-time)

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

## 3. (Optional) Map your survey flow's participant data

Voice NPS surveys are normally built in an Architect flow that stores the result in **participant
data**. The connector reads these attributes from each conversation:

| Auditor column | Default attribute name |
|---|---|
| `utterance` | `Survey.Utterance` |
| `recordedScore` | `Survey.Score` |
| `confidence` | `Survey.Confidence` |
| `participantStatus` | `Survey.Status` |
| `question` | `Survey.Question` |
| `surveyId` | `Survey.Id` |

If your flow uses different names, copy `config/genesys-connector.example.json` to
`config/genesys-connector.json` (git-ignored) and edit the `attributes` section. The file holds
**non-secret settings only**: region, days, queue IDs, default question, and attribute names.

Mapping rules:

- Conversations with none of the mapped attributes are not surveys and are skipped.
- `channel` is `Voice` for voice and callback media, and `Digital` for everything else.
- `completedAt` is the conversation end time (UTC).
- With no status attribute, the status is `Completed` if a score or utterance exists, and
  `Disconnected` otherwise (the survey started but no answer was captured).
- `surveyId` falls back to the conversation ID.

## 4. Run it

```powershell
# Last 7 days, Australia, download + audit + HTML report
.\Get-GenesysNpsSurveyData.ps1 -RunAudit -ExportHtmlReport

# Download only (audit later)
.\Get-GenesysNpsSurveyData.ps1

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
5. Matching conversations are written to `output/genesys-survey-export-YYYYMMDD-HHMMSS.csv`.
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
| `0 survey responses` | Attribute names in `config/genesys-connector.json` match the survey flow's participant data |
| TLS or "could not create SSL/TLS secure channel" on Windows PowerShell 5.1 | Ask IT to enable strong cryptography for .NET (`SchUseStrongCrypto`). The script does not change `ServicePointManager`, because that is a .NET static call blocked in CLM |
| Very large orgs | Use `-QueueId` to narrow the query. The query stops at 500 pages per day with a warning |

## Data handling

The downloaded CSV and the reports contain **real customer data**. They are written to `output/`,
which is git-ignored. Delete them when you are finished, and never attach them to issues or pull
requests. See [privacy-and-security.md](privacy-and-security.md).
