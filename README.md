# Genesys NPS Survey Auditor

**Find the NPS scores your survey platform missed, misheard, or mis-recorded.**

A PowerShell tool that audits Genesys Cloud-style Net Promoter Score (NPS) survey responses. It
reads a CSV export, works out which score each customer actually gave, compares it with the score
that was recorded, and produces CSV and HTML reports showing missed scores, mismatches, ambiguous
answers, invalid ratings, low-confidence captures, silence, and abandoned surveys.

- Runs **fully offline** from a CSV file. No API connection, credentials, or internet access.
- **Windows PowerShell 5.1** compatible, and safe under **Constrained Language Mode**
  (AppLocker / WDAC locked-down endpoints). No modules, no `Add-Type`, no .NET static calls.
- Ships with **synthetic sample data only**.

> **Disclaimer:** This is an independent community project. It is not an official Genesys product,
> integration, or endorsement, and is not affiliated with or supported by Genesys.
> "Genesys Cloud-style" describes the shape of the input data only.

---

## Why audit NPS surveys?

Post-call NPS surveys are usually captured by speech recognition or a keypad. When that capture
goes wrong, it goes wrong silently:

- A customer says *"ten out of ten"*, the recogniser rejects it, and **a promoter disappears** from
  the results.
- A customer says *"seven... actually make that eight"*, the platform keeps the first number, and
  the **wrong category** is reported.
- A customer says *"yeah it was good"*, and a score is recorded that **the customer never gave**.

Because NPS is a difference of two percentages, a handful of these errors can move the headline
number by several points and trigger the wrong business decisions. This tool gives support and
quality teams a repeatable way to measure capture accuracy and find the records worth listening to.

## Features

- **Complete 0-10 score detection** in numeric and written forms: `7`, `seven`, `7 out of 10`,
  `seven out of ten`, `10/10`, `a ten`.
- **Natural language:** `I'd give you a nine`, `I would say eight`, `probably a seven`,
  `it is a six`, `make that ten`, `I rate it four out of ten`.
- **Self-corrections:** `nine... no, ten` -> 10; `I was going to say six, but make it seven` -> 7.
- **Never guesses from sentiment.** `great`, `not bad`, `pretty happy` are flagged as ambiguous,
  not converted into numbers.
- **Safe handling of tricky input:** quantities (`I waited ten minutes`), ranges (`eight or nine`),
  decimals (`seven and a half`), negation (`not a ten`), other scales (`five stars`), and
  out-of-range answers (`eleven`, `one hundred`, `minus one`).
- **Nine audit statuses** with High / Medium / None priority.
- **Official NPS** and a separate, clearly labelled **audit-estimated NPS**.
- **Four reports:** detail CSV, exceptions CSV, summary CSV, and a standalone HTML report.
- **157 plain-PowerShell tests** (no Pester required), including an end-to-end run.

## Example report

<!--
  Screenshot placeholder.
  Generate a report from the synthetic sample data, take a screenshot, save it as
  docs/images/report-example.png, and replace this comment with:
  ![Example HTML audit report](docs/images/report-example.png)
  Only ever screenshot reports produced from synthetic data.
-->

> _Screenshot placeholder: an HTML report generated from the synthetic sample data, showing summary
> cards, audit-status breakdown, 0-10 score distribution, channel breakdown, and exception tables._

Console output from the sample data:

```text
=== Genesys NPS Survey Auditor ===
Independent community tool. Use synthetic or sanitised data only.

Input file           : survey-responses.csv
Records found        : 52
Confidence threshold : 0.70

Audit status breakdown
  Valid                       34   [None]
  Likely missed score          1   [High]
  Score mismatch               2   [High]
  Low-confidence capture       1   [Medium]
  Ambiguous response           5   [Medium]
  Invalid score response       3   [High]
  No input                     1   [Medium]
  Abandoned survey             3   [High]
  Review required              2   [Medium]

NPS
  Official NPS            :   -15.4   (39 valid recorded scores: 12 promoters, 9 passives, 18 detractors)
  Potentially corrected   :    -7.7   (39 scores from utterances) - AUDIT ESTIMATE ONLY

Findings
  Exceptions              : 18  (High: 9, Medium: 9)
  - 1 response(s) contain a clear score that was not recorded.
  - 2 response(s) have a recorded score that differs from what the customer said.
```

See [docs/example-findings.md](docs/example-findings.md) for a walkthrough of each finding.

## Quick start

Requirements: Windows PowerShell 5.1 or PowerShell 7+. Nothing else.

```powershell
# 1. Get the code
git clone https://github.com/<your-account>/genesys-nps-survey-auditor.git
cd genesys-nps-survey-auditor

# 2. (If downloaded as a ZIP) remove the internet zone mark
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File

# 3. Run the audit against the synthetic sample data
.\Export-GenesysNpsAudit.ps1 `
  -InputPath ".\sample-data\survey-responses.csv" `
  -OutputPath ".\output" `
  -ExportHtmlReport

# 4. Run the tests
.\tests\Test-NpsScoreDetection.ps1
```

Open the generated `output\nps-audit-report-YYYYMMDD-HHMMSS.html` in any browser.

### More examples

```powershell
# Stricter confidence threshold
.\Export-GenesysNpsAudit.ps1 -InputPath ".\sample-data\survey-responses.csv" -OutputPath ".\output" -ConfidenceThreshold 0.80

# CSV reports only (no HTML)
.\Export-GenesysNpsAudit.ps1 -InputPath ".\sample-data\survey-responses.csv" -OutputPath ".\output"

# Defaults: sample data in, .\output out
.\Export-GenesysNpsAudit.ps1 -ExportHtmlReport

# Unit tests only (skip the end-to-end run)
.\tests\Test-NpsScoreDetection.ps1 -SkipIntegration

# Audit a single utterance interactively
. .\Invoke-NpsUtteranceAnalysis.ps1
Invoke-NpsUtteranceAnalysis -Utterance "seven, actually make that eight" -RecordedScore 7 -Confidence 0.82
```

If your execution policy blocks unsigned scripts, follow your organisation's process (for example,
signing the scripts). Do not bypass policy on managed devices.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Audit completed. Exceptions found in the data are findings, not failures. |
| `1` | Unexpected script error. |
| `2` | Input problem: file missing, empty, unreadable, or required columns missing. |

## Input schema

A CSV with a header row containing these columns (extra columns are ignored; order does not matter):

| Column | Description | Example |
|---|---|---|
| `surveyId` | Survey response identifier | `nps-1001` |
| `conversationId` | Conversation identifier | `sample-conv-0001` |
| `completedAt` | Completion timestamp (ISO 8601) | `2026-09-20T09:12:00Z` |
| `channel` | `Voice`, `Digital`, ... | `Voice` |
| `question` | Survey question text | `How likely are you to recommend us from zero to ten?` |
| `utterance` | What the customer said or typed | `ten out of ten` |
| `recordedScore` | Score stored by the platform (blank if none) | *(blank)* |
| `confidence` | Recognition confidence 0.0-1.0 (blank if not reported) | `0.58` |
| `participantStatus` | `Completed`, `Timeout`, `Disconnected`, `Abandoned` | `Completed` |

```csv
surveyId,conversationId,completedAt,channel,question,utterance,recordedScore,confidence,participantStatus
nps-1001,sample-conv-0001,2026-09-20T09:12:00Z,Voice,How likely are you to recommend us from zero to ten?,ten out of ten,,0.58,Completed
```

## Audit statuses

Every record receives exactly one status.

| Audit status | Rule | Priority |
|---|---|---|
| Valid | Expected and recorded score match, and confidence meets the threshold (or is not reported) | None |
| Likely missed score | A clear expected score exists, but the recorded score is blank | High |
| Score mismatch | Expected and recorded scores are both present but differ | High |
| Invalid score response | The response attempts a rating outside 0-10 | High |
| Abandoned survey | Participant status indicates timeout, disconnect, or abandonment | High |
| Low-confidence capture | Scores match, but confidence is below the threshold (default 0.70) | Medium |
| Ambiguous response | Meaningful text exists, but no explicit 0-10 score can be safely inferred | Medium |
| Review required | Complex or uncertain scenario (multiple numbers, decimals, negation, malformed data) | Medium |
| No input | Utterance is blank or whitespace | Medium |

Full detection and precedence rules: [docs/scoring-rules.md](docs/scoring-rules.md).

## Output

Each run writes timestamped files to the output folder:

```text
output/
├── nps-audit-detail-YYYYMMDD-HHMMSS.csv       every record + audit result
├── nps-audit-exceptions-YYYYMMDD-HHMMSS.csv   High and Medium priority only
├── nps-audit-summary-YYYYMMDD-HHMMSS.csv      counts, distributions, NPS
└── nps-audit-report-YYYYMMDD-HHMMSS.html      with -ExportHtmlReport
```

**Detail / exceptions columns:** `SurveyId, ConversationId, CompletedAt, Channel, Question,
Utterance, RecordedScore, ExpectedScore, Confidence, ParticipantStatus, AuditStatus, Priority,
Reason, NpsCategoryRecorded, NpsCategoryExpected, RequiresReview`

**Summary** (`Section, Metric, Value, Notes`): total records, counts by audit status, priority and
channel, recorded and expected score distributions (0-10), promoters / passives / detractors,
official NPS, potentially corrected NPS, and high-priority exception count.

**HTML report:** summary cards, NPS breakdown, audit-status and channel tables, 0-10 distribution
with bars, high- and medium-priority exception tables, status definitions, and a privacy notice.
Self-contained: embedded CSS, no JavaScript, no CDNs, no external resources.

## How NPS is calculated

| Score | Category |
|---|---|
| 0-6 | Detractor |
| 7-8 | Passive |
| 9-10 | Promoter |

```
NPS = % Promoters - % Detractors        (range -100 to +100)
```

- **Official NPS** uses only valid recorded scores (whole numbers 0-10 in `recordedScore`). This is
  what the platform would report.
- **Potentially corrected NPS** uses the scores identified from customer utterances. It estimates
  what NPS would be if capture were perfect. **It is an audit estimate only, not an official NPS
  result**, and should be used to size the capture problem, not to report performance.

## Security and privacy

- Use **synthetic or sanitised data only** in public repositories, demos, and screenshots.
- **Never commit** production exports, recordings, transcripts, ANI/DNIS, customer or employee
  details, real conversation IDs, tokens, OAuth secrets, tenant URLs, or queue names.
- Generated reports are git-ignored by default because they contain utterances.
- The tool is offline-only; the summary records the input file name, never the full local path.

Read [docs/privacy-and-security.md](docs/privacy-and-security.md) before using real data.

## Constrained Language Mode compatibility

The scripts are written for locked-down Windows endpoints:

- No .NET static method calls (`[Math]::`, `[Convert]::`, `[regex]::` ...), no `::new()`
- No `Add-Type`, PowerShell classes, or external modules
- Objects built with `New-Object PSObject -Property`, with `Select-Object` fixing column order
- Culture-independent number formatting without `CultureInfo`
- HTML encoding with string `.Replace()` instead of `System.Web`
- Script files are pure ASCII, so Windows PowerShell 5.1 reads them identically without a BOM

The full test suite passes with `$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'`.

## Repository structure

```text
genesys-nps-survey-auditor/
├── README.md
├── LICENSE
├── .gitignore
├── Export-GenesysNpsAudit.ps1          main entry script: import, analyse, report
├── Invoke-NpsUtteranceAnalysis.ps1     reusable detection and classification functions
├── sample-data/
│   └── survey-responses.csv            52 synthetic survey responses
├── output/
│   └── .gitkeep                        generated reports land here (git-ignored)
├── tests/
│   └── Test-NpsScoreDetection.ps1      plain-PowerShell test suite
└── docs/
    ├── scoring-rules.md
    ├── privacy-and-security.md
    └── example-findings.md
```

## Roadmap

- [ ] Optional Genesys Cloud API connector for survey and conversation data, reading credentials
      from environment variables or an approved secret store (never hard-coded)
- [ ] Date-range and channel filters
- [ ] Trend comparison between two audit runs
- [ ] Configurable correction cues and quantity words via a local JSON file
- [ ] Additional languages for written numbers
- [ ] Per-question audits for multi-question surveys
- [ ] Optional script signing guidance for AppLocker / WDAC allow-listing

## Contributing

Issues and pull requests are welcome. Please:

1. Use synthetic data only in examples, tests, and issue reports.
2. Keep all code Windows PowerShell 5.1 and Constrained Language Mode compatible.
3. Add a test in `tests/Test-NpsScoreDetection.ps1` for every new detection rule, and make sure
   the full suite passes.

## License

[MIT](LICENSE)

---

*Genesys and Genesys Cloud are trademarks of their respective owner. They are referenced only to
describe data compatibility. This project is not affiliated with, sponsored by, or endorsed by Genesys.*
