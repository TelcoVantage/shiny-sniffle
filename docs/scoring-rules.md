# Scoring Rules

This document describes exactly how the auditor decides what score a customer gave, and how each
response is classified. All logic lives in [`Invoke-NpsUtteranceAnalysis.ps1`](../Invoke-NpsUtteranceAnalysis.ps1).

The guiding principle: **only explicit numbers count.** The tool never converts sentiment
("great", "terrible", "pretty happy") into a score. If it cannot safely identify one whole number
from 0 to 10, it flags the response for a human instead of guessing.

---

## 1. Normalisation

Before looking for numbers, each utterance is normalised:

| Step | Example |
|---|---|
| Lower-case, trim | `"  NINE  "` -> `nine` |
| Typographic apostrophes, dashes and ellipses converted to ASCII | `I’d` -> `i'd` |
| Digit decimals rewritten | `7.5` -> `7 point 5` |
| Scale references removed so they are not read as scores | `ten out of ten` -> `ten`, `10/10` -> `10`, `from zero to ten, a nine` -> `a nine`, `on a scale of 0-10` -> removed |
| Numeric ranges kept as two numbers | `7-8` -> `7 to 8` |
| Leading minus sign spelled out | `-1` -> `minus 1` |
| Contractions collapsed, punctuation becomes spaces | `i'd give you a nine!` -> `id give you a nine` |

## 2. Recognising numbers

The normalised text is split into words. Each word is checked against:

| Type | Values | Treated as |
|---|---|---|
| Digits | `0` ... `10` | In-range score |
| Written numbers | `zero` (or `nought`), `one` ... `ten` | In-range score |
| Digits above 10 | `11`, `100`, ... | Out-of-range rating |
| Teens | `eleven` ... `nineteen` | Out-of-range rating |
| Tens (+ unit) | `twenty`, `twenty five`, ... `ninety` | Out-of-range rating |
| Multipliers | `one hundred`, `a hundred`, `two thousand` | Out-of-range rating |
| Negatives | `minus one`, `negative five`, `-1` | Out-of-range rating |

Articles and surrounding phrasing are ignored, so all of these are detected as explicit scores:

```
5 | eight | 10/10 | ten out of ten | a ten | I'd give you a nine | I would say eight
probably a seven | probably an 8 | it is a six | make that ten | I rate it four out of ten
```

### Numbers that are *not* scores

Some numbers in an utterance are clearly not ratings. They are ignored:

| Rule | Example | Result |
|---|---|---|
| Number followed by a unit / quantity noun (minutes, hours, days, times, calls, agents, transfers, pounds, dollars, percent ...) | `I waited ten minutes but I'd give you a seven` | Score **7** |
| `one` used as a pronoun or determiner (`no one answered`, `the one thing`, `one of the best`) | `no one answered my question` | No score -> Ambiguous |

## 3. Corrections

When a customer changes their answer, **the last clear score wins**, but only if a correction cue
appears *between* the two numbers.

Correction cues: `actually`, `no`, `nope`, `sorry`, `rather`, `instead`, `correction`, `scratch`,
`wait`, `mean` (as in "I mean"), `make` (as in "make that" / "make it"), `change`, `update`, `correct`.

| Utterance | Expected score |
|---|---|
| `seven, actually make that eight` | 8 |
| `seven... actually make that eight` | 8 |
| `I was going to say six, but make it seven` | 7 |
| `nine... no, ten` | 10 |
| `eleven, sorry, I mean ten` | 10 (the invalid first attempt is replaced) |

If the platform recorded the *first* number, the record becomes a **Score mismatch**, and the reason
notes that the customer self-corrected.

## 4. When the tool refuses to guess

| Situation | Example | Outcome |
|---|---|---|
| No number at all | `yeah it was good`, `not bad`, `pretty happy`, `fantastic` | **Ambiguous response** |
| Several different numbers, no correction cue | `eight or maybe nine`, `7-8`, `between seven and eight` | **Review required** |
| Non-integer | `seven and a half`, `7.5`, `seven point five` | **Review required** |
| Negated number | `not a ten`, `definitely not a five` | **Review required** |
| Different rating scale | `five stars` | **Review required** |
| Final number outside 0-10 | `eleven`, `one hundred`, `minus one`, `twenty five` | **Invalid score response** |

The same number repeated (`nine, nine`) is not a conflict. If *every* number is out of range
(`ninety out of a hundred`) the response is Invalid.

## 5. Recorded score and confidence parsing

| Column | Accepted | Otherwise |
|---|---|---|
| `recordedScore` | Blank, or a whole number 0-10 (`8` and `8.0` both accepted) | `12`, `-1`, `abc`, `7.5` -> **Review required** (data quality issue) |
| `confidence` | Blank ("not reported"), or a decimal between 0 and 1 | `high`, `85`, `0,7` -> **Review required** |
| `participantStatus` | Blank / `Completed` / `Complete` / `Finished` / `Answered` / `Success` | `Timeout`, `Timed out`, `Disconnected`, `Abandoned`, `Hang up`, `Dropped` -> **Abandoned survey**; anything else -> **Review required** |

A blank confidence is common for typed (digital) responses, so the confidence check is skipped and
the reason says so. Confidence exactly equal to the threshold passes.

## 6. Classification order

Rules are evaluated top to bottom; the first match wins, so every record receives exactly one status.

| # | Condition | Audit status | Priority |
|---|---|---|---|
| 1 | Participant status is timeout / disconnect / abandoned | Abandoned survey | High |
| 2 | Participant status unrecognised | Review required | Medium |
| 3 | Recorded score malformed or outside 0-10 | Review required | Medium |
| 4 | Confidence malformed | Review required | Medium |
| 5 | Utterance blank or whitespace | No input | Medium * |
| 6 | Final number outside 0-10 | Invalid score response | High |
| 7 | Numbers present but unresolvable (see section 4) | Review required | Medium |
| 8 | Text present, no explicit number | Ambiguous response | Medium |
| 9 | Clear score, recorded score blank | Likely missed score | High |
| 10 | Clear score, recorded score different | Score mismatch | High |
| 11 | Scores match, confidence below threshold | Low-confidence capture | Medium |
| 12 | Scores match, confidence meets threshold or not reported | Valid | None |

\* "No input" is not assigned a priority in the original specification. This project treats it as
**Medium** so blank responses still appear in the exceptions report.

`RequiresReview` is `True` for every priority other than `None`.

## 7. NPS

| Score | Category |
|---|---|
| 0-6 | Detractor |
| 7-8 | Passive |
| 9-10 | Promoter |

`NPS = % Promoters - % Detractors`

- **Official NPS** uses every record whose `recordedScore` is a valid whole number from 0 to 10,
  regardless of audit status. This mirrors what the survey platform would report.
- **Potentially corrected NPS** uses the `ExpectedScore` identified from utterances. It shows how
  much the missed and mismatched captures could be moving the headline figure. It is an
  **audit estimate only**, not an official NPS result.

## 8. Known limitations

- English only.
- Homophones produced by speech recognition (`for` / `four`, `to` / `two`, `ate` / `eight`) are
  deliberately **not** treated as numbers, because doing so would create far more false positives
  than it fixes.
- The correction cue list is intentionally conservative. `seven but eight` (no recognised cue) is
  flagged for review rather than resolved.
- The rules are heuristic. Treat the audit as a triage aid for human reviewers, not as ground truth.
