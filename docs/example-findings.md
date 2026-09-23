# Example Findings

The examples below come from running the auditor against the **synthetic** sample file
`sample-data/survey-responses.csv`. All identifiers, timestamps, and utterances are fictional.

```powershell
.\Export-GenesysNpsAudit.ps1 -InputPath ".\sample-data\survey-responses.csv" -OutputPath ".\output" -ExportHtmlReport
```

## Headline result

| Measure | Value |
|---|---|
| Records analysed | 52 |
| Exceptions (High + Medium) | 18 |
| High-priority exceptions | 9 |
| Official NPS (39 valid recorded scores) | **-15.4** |
| Potentially corrected NPS (39 scores from utterances) | **-7.7** (audit estimate only) |

A gap of almost 8 points between the official and audit-estimated NPS is the kind of signal that
justifies looking at the speech-recognition or survey flow configuration.

---

## 1. Likely missed score

The customer gave an unambiguous top score, but nothing was stored. The response silently drops
out of the official NPS, and a promoter is lost.

| SurveyId | Utterance | Recorded | Expected | Confidence | Priority |
|---|---|---|---|---|---|
| nps-1034 | ten out of ten | *(blank)* | 10 | 0.58 | High |

> **Reason:** Customer gave a clear score of 10 but no score was recorded (confidence 0.58).

**Typical causes:** the recogniser rejected the input below its own confidence floor; the grammar
did not include the "out of ten" phrasing; the flow timed out waiting for DTMF.

## 2. Score mismatch

The stored score disagrees with what the customer said. These directly distort the official NPS,
often moving a customer between categories.

| SurveyId | Utterance | Recorded | Expected | Confidence | Effect |
|---|---|---|---|---|---|
| nps-1035 | I'd say a 9 | 6 | 9 | 0.71 | Promoter recorded as Detractor |
| nps-1033 | I was going to say six, but make it seven | 6 | 7 | 0.74 | Passive recorded as Detractor |

> **Reason (nps-1033):** Utterance indicates 7 but 6 was recorded. The customer self-corrected;
> the platform may have kept the first number.

**Typical causes:** the platform captured the first number in a correction; misrecognition of
similar-sounding words; a keypad entry that disagreed with the spoken answer.

## 3. Low-confidence capture

The recorded score matches the utterance, but recognition confidence is below the threshold
(default 0.70). The data is probably correct but should be spot-checked.

| SurveyId | Utterance | Recorded | Expected | Confidence | Priority |
|---|---|---|---|---|---|
| nps-1036 | eight | 8 | 8 | 0.52 | Medium |

> **Reason:** Recorded score 8 matches the utterance, but confidence 0.52 is below the 0.70 threshold.

Raise or lower the bar with `-ConfidenceThreshold`, for example `-ConfidenceThreshold 0.80`.

## 4. Abandoned surveys

The participant left before the survey completed. These are always High priority because they
reveal drop-off in the survey flow itself.

| SurveyId | Channel | Utterance | Status | Notes |
|---|---|---|---|---|
| nps-1044 | Voice | *(blank)* | Timeout | No response before the flow timed out |
| nps-1045 | Voice | seven | Disconnected | A score of 7 was heard before the call ended |
| nps-1046 | Digital | *(blank)* | Abandoned | Customer closed the survey |

> **Reason (nps-1045):** Participant status 'Disconnected' indicates the survey was not completed.
> A score of 7 was heard before the survey ended.

## 5. Other findings in the sample

| SurveyId | Utterance | Audit status | Why |
|---|---|---|---|
| nps-1037 | yeah it was good | Ambiguous response | Positive sentiment, but no number |
| nps-1052 | fantastic service | Ambiguous response | Platform recorded 9, but the customer never said a number |
| nps-1040 | eleven | Invalid score response | Outside 0-10 |
| nps-1041 | one hundred | Invalid score response | Outside 0-10 |
| nps-1042 | minus one | Invalid score response | Outside 0-10 |
| nps-1043 | *(blank)* | No input | Completed survey with no utterance |
| nps-1050 | eight or maybe nine | Review required | Two different numbers, no correction |
| nps-1051 | about seven and a half | Review required | Non-integer answer |

## 6. Correctly handled edge cases (Valid)

These look tricky but are resolved safely and marked Valid:

| SurveyId | Utterance | Recorded | Expected |
|---|---|---|---|
| nps-1031 | seven... actually make that eight | 8 | 8 |
| nps-1032 | nine, no, ten | 10 | 10 |
| nps-1049 | I waited ten minutes but I'd give you a seven | 7 | 7 |
| nps-1027 | 10/10 | 10 | 10 |
| nps-1011 | I rate it four out of ten | 4 | 4 |
