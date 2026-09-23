<#
.SYNOPSIS
    Plain-PowerShell tests for the Genesys NPS Survey Auditor (no Pester or external modules).

.DESCRIPTION
    Covers:
      1. Score detection for every value 0-10 in numeric, written, and "out of ten" forms.
      2. Natural-language phrasing and self-corrections.
      3. Ambiguous, invalid, blank, and uncertain responses.
      4. Audit classification (mismatch, missed score, low confidence, abandoned, etc.).
      5. NPS calculation.
      6. End-to-end run of Export-GenesysNpsAudit.ps1 against the synthetic sample data.

    Prints PASS/FAIL per test and exits with code 1 if any test fails.
    CLM-safe: runs under Constrained Language Mode on Windows PowerShell 5.1.

.EXAMPLE
    .\tests\Test-NpsScoreDetection.ps1

.EXAMPLE
    .\tests\Test-NpsScoreDetection.ps1 -SkipIntegration
#>
[CmdletBinding()]
param(
    [switch]$SkipIntegration
)

$ErrorActionPreference = 'Stop'

$testRoot = $PSScriptRoot
if (-not $testRoot) { $testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $testRoot

. (Join-Path $repoRoot 'Invoke-NpsUtteranceAnalysis.ps1')

$script:PassCount = 0
$script:FailCount = 0
$script:Failures = @()

# ---------------------------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------------------------

function Write-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    if ($Passed) {
        $script:PassCount++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    }
    else {
        $script:FailCount++
        $script:Failures += ($Name + ' -> ' + $Detail)
        Write-Host ('  FAIL  ' + $Name + ' -> ' + $Detail) -ForegroundColor Red
    }
}

function Assert-ExpectedScore {
    # Asserts the utterance yields a clear expected score.
    param([AllowEmptyString()][string]$Utterance, [int]$Expected)
    $r = Get-NpsExpectedScore -Utterance $Utterance
    $ok = ($r.Outcome -eq 'Score' -and $null -ne $r.ExpectedScore -and $r.ExpectedScore -eq $Expected)
    Write-TestResult -Name ('"' + $Utterance + '" => ' + $Expected) -Passed $ok `
        -Detail ('got outcome ' + $r.Outcome + ', score ' + [string]$r.ExpectedScore)
}

function Assert-AuditStatus {
    # Asserts the full audit classification for a response.
    param(
        [string]$Name,
        [AllowEmptyString()][string]$Utterance,
        [AllowEmptyString()][string]$RecordedScore = '',
        [AllowEmptyString()][string]$Confidence = '0.90',
        [AllowEmptyString()][string]$ParticipantStatus = 'Completed',
        [string]$ExpectedStatus,
        [string]$ExpectedPriority = ''
    )
    $r = Invoke-NpsUtteranceAnalysis -Utterance $Utterance -RecordedScore $RecordedScore -Confidence $Confidence `
        -ParticipantStatus $ParticipantStatus -ConfidenceThreshold 0.70
    $ok = ($r.AuditStatus -eq $ExpectedStatus)
    if ($ExpectedPriority -ne '') { $ok = $ok -and ($r.Priority -eq $ExpectedPriority) }
    Write-TestResult -Name ($Name + ' => ' + $ExpectedStatus) -Passed $ok `
        -Detail ('got ' + $r.AuditStatus + ' / ' + $r.Priority + ' (' + $r.Reason + ')')
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    Write-TestResult -Name $Name -Passed ([string]$Actual -eq [string]$Expected) -Detail ('expected ' + [string]$Expected + ', got ' + [string]$Actual)
}

# ---------------------------------------------------------------------------------------------
# 1. Every score 0-10 in every basic form
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Score detection: full 0-10 range' -ForegroundColor Cyan
$words = @('zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten')
for ($n = 0; $n -le 10; $n++) {
    $w = $words[$n]
    $article = 'a'
    if ($w -eq 'eight') { $article = 'an' }
    Assert-ExpectedScore -Utterance ([string]$n) -Expected $n
    Assert-ExpectedScore -Utterance $w -Expected $n
    Assert-ExpectedScore -Utterance ("$n out of 10") -Expected $n
    Assert-ExpectedScore -Utterance ("$w out of ten") -Expected $n
    Assert-ExpectedScore -Utterance ("$n/10") -Expected $n
    Assert-ExpectedScore -Utterance ("I'd give you $article $w") -Expected $n
}

# ---------------------------------------------------------------------------------------------
# 2. Required examples, natural language, and corrections
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Score detection: required examples and natural language' -ForegroundColor Cyan
Assert-ExpectedScore -Utterance 'zero' -Expected 0
Assert-ExpectedScore -Utterance 'one' -Expected 1
Assert-ExpectedScore -Utterance 'five' -Expected 5
Assert-ExpectedScore -Utterance 'ten' -Expected 10
Assert-ExpectedScore -Utterance 'a ten' -Expected 10
Assert-ExpectedScore -Utterance '10/10' -Expected 10
Assert-ExpectedScore -Utterance 'ten out of ten' -Expected 10
Assert-ExpectedScore -Utterance "I'd give you a nine" -Expected 9
Assert-ExpectedScore -Utterance ('I' + [char]0x2019 + 'd give you a nine') -Expected 9
Assert-ExpectedScore -Utterance 'probably an 8' -Expected 8
Assert-ExpectedScore -Utterance 'I would say eight' -Expected 8
Assert-ExpectedScore -Utterance 'probably a seven' -Expected 7
Assert-ExpectedScore -Utterance 'it is a six' -Expected 6
Assert-ExpectedScore -Utterance 'make that ten' -Expected 10
Assert-ExpectedScore -Utterance 'I rate it four out of ten' -Expected 4
Assert-ExpectedScore -Utterance 'Ten.' -Expected 10
Assert-ExpectedScore -Utterance '  NINE  ' -Expected 9
Assert-ExpectedScore -Utterance 'on a scale of zero to ten I would say a 9' -Expected 9
Assert-ExpectedScore -Utterance 'I waited ten minutes but I would give you a seven' -Expected 7

Write-Host ''
Write-Host 'Score detection: corrections (last clear score wins)' -ForegroundColor Cyan
Assert-ExpectedScore -Utterance 'seven, actually make that eight' -Expected 8
Assert-ExpectedScore -Utterance 'seven... actually make that eight' -Expected 8
Assert-ExpectedScore -Utterance 'I was going to say six, but make it seven' -Expected 7
Assert-ExpectedScore -Utterance 'nine... no, ten' -Expected 10
Assert-ExpectedScore -Utterance 'nine, no, ten' -Expected 10
Assert-ExpectedScore -Utterance 'eleven, sorry, I mean ten' -Expected 10

# ---------------------------------------------------------------------------------------------
# 3. Audit classification
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Audit classification' -ForegroundColor Cyan
Assert-AuditStatus -Name '"yeah it was good"' -Utterance 'yeah it was good' -ExpectedStatus 'Ambiguous response' -ExpectedPriority 'Medium'
Assert-AuditStatus -Name '"not bad"' -Utterance 'not bad' -ExpectedStatus 'Ambiguous response'
Assert-AuditStatus -Name '"pretty happy"' -Utterance 'pretty happy' -ExpectedStatus 'Ambiguous response'
Assert-AuditStatus -Name '"fantastic" with recorded 9' -Utterance 'fantastic' -RecordedScore '9' -ExpectedStatus 'Ambiguous response'
Assert-AuditStatus -Name '"no one answered my question"' -Utterance 'no one answered my question' -ExpectedStatus 'Ambiguous response'
Assert-AuditStatus -Name '"eleven"' -Utterance 'eleven' -ExpectedStatus 'Invalid score response' -ExpectedPriority 'High'
Assert-AuditStatus -Name '"one hundred"' -Utterance 'one hundred' -ExpectedStatus 'Invalid score response'
Assert-AuditStatus -Name '"minus one"' -Utterance 'minus one' -ExpectedStatus 'Invalid score response'
Assert-AuditStatus -Name '"-1"' -Utterance '-1' -ExpectedStatus 'Invalid score response'
Assert-AuditStatus -Name '"twenty five"' -Utterance 'twenty five' -ExpectedStatus 'Invalid score response'
Assert-AuditStatus -Name 'blank utterance' -Utterance '' -ExpectedStatus 'No input' -ExpectedPriority 'Medium'
Assert-AuditStatus -Name 'whitespace utterance' -Utterance '   ' -ExpectedStatus 'No input'
Assert-AuditStatus -Name 'expected 9, recorded 6' -Utterance 'nine' -RecordedScore '6' -ExpectedStatus 'Score mismatch' -ExpectedPriority 'High'
Assert-AuditStatus -Name 'expected 10, recorded blank' -Utterance 'ten out of ten' -RecordedScore '' -Confidence '0.58' -ExpectedStatus 'Likely missed score' -ExpectedPriority 'High'
Assert-AuditStatus -Name 'expected 8, recorded 8, confidence 0.52' -Utterance 'eight' -RecordedScore '8' -Confidence '0.52' -ExpectedStatus 'Low-confidence capture' -ExpectedPriority 'Medium'
Assert-AuditStatus -Name 'expected 8, recorded 8, confidence 0.70 (at threshold)' -Utterance 'eight' -RecordedScore '8' -Confidence '0.70' -ExpectedStatus 'Valid' -ExpectedPriority 'None'
Assert-AuditStatus -Name 'expected 8, recorded 8, confidence not reported' -Utterance 'eight' -RecordedScore '8' -Confidence '' -ExpectedStatus 'Valid'
Assert-AuditStatus -Name 'correction recorded correctly' -Utterance 'nine... no, ten' -RecordedScore '10' -ExpectedStatus 'Valid'
Assert-AuditStatus -Name 'correction recorded as first number' -Utterance 'seven, actually make that eight' -RecordedScore '7' -ExpectedStatus 'Score mismatch'
Assert-AuditStatus -Name 'status Timeout' -Utterance '' -ParticipantStatus 'Timeout' -ExpectedStatus 'Abandoned survey' -ExpectedPriority 'High'
Assert-AuditStatus -Name 'status Disconnected with score' -Utterance 'seven' -ParticipantStatus 'Disconnected' -ExpectedStatus 'Abandoned survey'
Assert-AuditStatus -Name 'status Abandoned' -Utterance '' -ParticipantStatus 'Abandoned' -ExpectedStatus 'Abandoned survey'
Assert-AuditStatus -Name '"eight or maybe nine"' -Utterance 'eight or maybe nine' -ExpectedStatus 'Review required' -ExpectedPriority 'Medium'
Assert-AuditStatus -Name '"seven and a half"' -Utterance 'seven and a half' -ExpectedStatus 'Review required'
Assert-AuditStatus -Name '"7.5"' -Utterance '7.5' -ExpectedStatus 'Review required'
Assert-AuditStatus -Name '"not a ten"' -Utterance 'not a ten' -ExpectedStatus 'Review required'
Assert-AuditStatus -Name '"five stars"' -Utterance 'five stars' -ExpectedStatus 'Review required'
Assert-AuditStatus -Name 'malformed recorded score "abc"' -Utterance 'eight' -RecordedScore 'abc' -ExpectedStatus 'Review required'
Assert-AuditStatus -Name 'out-of-range recorded score "12"' -Utterance 'eight' -RecordedScore '12' -ExpectedStatus 'Review required'
Assert-AuditStatus -Name 'malformed confidence "high"' -Utterance 'eight' -RecordedScore '8' -Confidence 'high' -ExpectedStatus 'Review required'
Assert-AuditStatus -Name 'unrecognised participant status' -Utterance 'eight' -RecordedScore '8' -ParticipantStatus 'Mystery' -ExpectedStatus 'Review required'
Assert-AuditStatus -Name 'null inputs' -Utterance $null -RecordedScore $null -Confidence $null -ParticipantStatus $null -ExpectedStatus 'No input'

# ---------------------------------------------------------------------------------------------
# 4. Categories and NPS calculation
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'NPS categories and calculation' -ForegroundColor Cyan
Assert-Equal -Name 'Category 0 = Detractor' -Actual (Get-NpsCategory -Score 0) -Expected 'Detractor'
Assert-Equal -Name 'Category 6 = Detractor' -Actual (Get-NpsCategory -Score 6) -Expected 'Detractor'
Assert-Equal -Name 'Category 7 = Passive' -Actual (Get-NpsCategory -Score 7) -Expected 'Passive'
Assert-Equal -Name 'Category 8 = Passive' -Actual (Get-NpsCategory -Score 8) -Expected 'Passive'
Assert-Equal -Name 'Category 9 = Promoter' -Actual (Get-NpsCategory -Score 9) -Expected 'Promoter'
Assert-Equal -Name 'Category 10 = Promoter' -Actual (Get-NpsCategory -Score 10) -Expected 'Promoter'
Assert-Equal -Name 'Category blank = empty' -Actual (Get-NpsCategory -Score $null) -Expected ''

# 4 promoters, 2 passives, 2 detractors => 50% - 25% = +25
$summary = Get-NpsScoreSummary -Scores @(10, 9, 9, 10, 7, 8, 3, 6)
Assert-Equal -Name 'NPS promoters' -Actual $summary.Promoters -Expected 4
Assert-Equal -Name 'NPS passives' -Actual $summary.Passives -Expected 2
Assert-Equal -Name 'NPS detractors' -Actual $summary.Detractors -Expected 2
Assert-Equal -Name 'NPS = 25.0' -Actual (Format-NpsNumber -Value $summary.Nps -Decimals 1) -Expected '25.0'
$empty = Get-NpsScoreSummary -Scores @()
Assert-Equal -Name 'NPS with no scores is null' -Actual ($null -eq $empty.Nps) -Expected $true

# ---------------------------------------------------------------------------------------------
# 5. End-to-end run against the synthetic sample data
# ---------------------------------------------------------------------------------------------

if (-not $SkipIntegration) {
    Write-Host ''
    Write-Host 'End-to-end: Export-GenesysNpsAudit.ps1 with sample data' -ForegroundColor Cyan

    $exportScript = Join-Path $repoRoot 'Export-GenesysNpsAudit.ps1'
    $sampleCsv = Join-Path (Join-Path $repoRoot 'sample-data') 'survey-responses.csv'
    $testOutput = Join-Path (Join-Path $repoRoot 'output') ('_test-run-' + (Get-Date -Format 'yyyyMMddHHmmss'))

    & $exportScript -InputPath $sampleCsv -OutputPath $testOutput -ExportHtmlReport *> $null
    Assert-Equal -Name 'Exit code 0 on sample data' -Actual $LASTEXITCODE -Expected 0

    foreach ($prefix in @('nps-audit-detail-', 'nps-audit-exceptions-', 'nps-audit-summary-', 'nps-audit-report-')) {
        $found = @(Get-ChildItem -LiteralPath $testOutput -Filter ($prefix + '*') -ErrorAction SilentlyContinue)
        Write-TestResult -Name ('Output file created: ' + $prefix + '*') -Passed ($found.Count -eq 1) -Detail ('found ' + $found.Count)
    }

    $sampleRows = @(Import-Csv -LiteralPath $sampleCsv)
    $detailFile = @(Get-ChildItem -LiteralPath $testOutput -Filter 'nps-audit-detail-*.csv')
    if ($detailFile.Count -eq 1) {
        $detailRows = @(Import-Csv -LiteralPath $detailFile[0].FullName)
        Assert-Equal -Name 'Detail row count matches input' -Actual $detailRows.Count -Expected $sampleRows.Count
        Write-TestResult -Name 'Sample data has at least 35 records' -Passed ($sampleRows.Count -ge 35) -Detail ('found ' + $sampleRows.Count)
        foreach ($s in @(Get-NpsAuditStatusList)) {
            $c = @($detailRows | Where-Object { $_.AuditStatus -eq $s.Status }).Count
            Write-TestResult -Name ('Sample data exercises "' + $s.Status + '"') -Passed ($c -gt 0) -Detail 'no records'
        }
        $exceptionFile = @(Get-ChildItem -LiteralPath $testOutput -Filter 'nps-audit-exceptions-*.csv')
        $exceptionRows = @(Import-Csv -LiteralPath $exceptionFile[0].FullName)
        $expectedExceptions = @($detailRows | Where-Object { $_.Priority -eq 'High' -or $_.Priority -eq 'Medium' }).Count
        Assert-Equal -Name 'Exceptions file contains only High/Medium records' -Actual $exceptionRows.Count -Expected $expectedExceptions
    }

    $html = @(Get-ChildItem -LiteralPath $testOutput -Filter 'nps-audit-report-*.html')
    if ($html.Count -eq 1) {
        $content = Get-Content -LiteralPath $html[0].FullName -Raw
        Write-TestResult -Name 'HTML report has no remote dependencies' -Passed ($content -notmatch '(src|href)\s*=\s*"(https?:)?//') -Detail 'remote URL found'
        Write-TestResult -Name 'HTML report has no script tags' -Passed ($content -notmatch '<script') -Detail '<script> found'
        Write-TestResult -Name 'HTML report includes privacy notice' -Passed ($content -match 'Privacy notice') -Detail 'missing'
    }

    # Input validation returns exit code 2 (not a crash, not 0).
    & $exportScript -InputPath (Join-Path $testOutput 'does-not-exist.csv') -OutputPath $testOutput *> $null
    Assert-Equal -Name 'Missing input file returns exit code 2' -Actual $LASTEXITCODE -Expected 2

    $badCsv = Join-Path $testOutput 'bad-columns.csv'
    Set-Content -LiteralPath $badCsv -Value @('surveyId,utterance', 'nps-9999,ten') -Encoding UTF8
    & $exportScript -InputPath $badCsv -OutputPath $testOutput *> $null
    Assert-Equal -Name 'Missing required columns returns exit code 2' -Actual $LASTEXITCODE -Expected 2

    Remove-Item -LiteralPath $testOutput -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host ('Language mode: ' + $ExecutionContext.SessionState.LanguageMode) -ForegroundColor DarkGray
$total = $script:PassCount + $script:FailCount
if ($script:FailCount -eq 0) {
    Write-Host ("All $total tests passed.") -ForegroundColor Green
    exit 0
}
Write-Host ("$($script:FailCount) of $total tests FAILED:") -ForegroundColor Red
foreach ($f in $script:Failures) { Write-Host ('  - ' + $f) -ForegroundColor Red }
exit 1
