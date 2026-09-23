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
      7. Genesys Cloud connector with a mocked API (no network, no real credentials).

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
# 6. Genesys Cloud connector (offline - Invoke-RestMethod is mocked, no network calls)
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Genesys Cloud connector (offline, mocked API)' -ForegroundColor Cyan

. (Join-Path $repoRoot 'GenesysCloudApi.ps1')

# Base64 (RFC 4648 test vectors + a classic Basic-auth example)
Assert-Equal -Name 'Base64 ""' -Actual (ConvertTo-GcBase64 -Text '') -Expected ''
Assert-Equal -Name 'Base64 "f"' -Actual (ConvertTo-GcBase64 -Text 'f') -Expected 'Zg=='
Assert-Equal -Name 'Base64 "fo"' -Actual (ConvertTo-GcBase64 -Text 'fo') -Expected 'Zm8='
Assert-Equal -Name 'Base64 "foo"' -Actual (ConvertTo-GcBase64 -Text 'foo') -Expected 'Zm9v'
Assert-Equal -Name 'Base64 "foobar"' -Actual (ConvertTo-GcBase64 -Text 'foobar') -Expected 'Zm9vYmFy'
Assert-Equal -Name 'Base64 "Aladdin:open sesame"' -Actual (ConvertTo-GcBase64 -Text 'Aladdin:open sesame') -Expected 'QWxhZGRpbjpvcGVuIHNlc2FtZQ=='
Assert-Equal -Name 'Base64 UTF-8 "e-acute"' -Actual (ConvertTo-GcBase64 -Text ([string][char]0x00E9)) -Expected 'w6k='

# Regions
Assert-Equal -Name 'Region "Australia"' -Actual (Get-GcRegionDomain -Region 'Australia') -Expected 'mypurecloud.com.au'
Assert-Equal -Name 'Region "ap-southeast-2"' -Actual (Get-GcRegionDomain -Region 'ap-southeast-2') -Expected 'mypurecloud.com.au'
Assert-Equal -Name 'Region "https://api.mypurecloud.com.au/"' -Actual (Get-GcRegionDomain -Region 'https://api.mypurecloud.com.au/') -Expected 'mypurecloud.com.au'
$regionRejected = $false
try { Get-GcRegionDomain -Region 'evil.example.com' | Out-Null } catch { $regionRejected = $true }
Write-TestResult -Name 'Unknown region domain is rejected' -Passed $regionRejected -Detail 'accepted'

# Date range: 7 contiguous one-day UTC intervals ending at the supplied time
$fixedEnd = Get-Date -Date '2026-09-23T10:15:42'
$intervals = @(Get-GcDailyIntervals -Days 7 -EndUtc $fixedEnd)
Assert-Equal -Name 'Last 7 days = 7 intervals' -Actual $intervals.Count -Expected 7
Assert-Equal -Name 'First interval starts 7 days back' -Actual (($intervals[0] -split '/')[0]) -Expected '2026-09-16T10:15:00.000Z'
Assert-Equal -Name 'Last interval ends now (to the minute)' -Actual (($intervals[6] -split '/')[1]) -Expected '2026-09-23T10:15:00.000Z'
$contiguous = $true
for ($i = 1; $i -lt $intervals.Count; $i++) {
    if ((($intervals[$i - 1] -split '/')[1]) -ne (($intervals[$i] -split '/')[0])) { $contiguous = $false }
}
Write-TestResult -Name 'Intervals are contiguous' -Passed $contiguous -Detail 'gap or overlap'

# Credentials come only from the environment
$savedId = $env:GENESYS_CLIENT_ID
$savedSecret = $env:GENESYS_CLIENT_SECRET
$savedRegion = $env:GENESYS_REGION
$env:GENESYS_CLIENT_ID = ''
$env:GENESYS_CLIENT_SECRET = ''
$env:GENESYS_REGION = ''
$missingThrows = $false
try { Get-GcCredentialFromEnvironment | Out-Null } catch { $missingThrows = ($_.Exception.Message -match 'GENESYS_CLIENT_ID') }
Write-TestResult -Name 'Missing credential environment variables give a clear error' -Passed $missingThrows -Detail 'no error'
Assert-Equal -Name 'Masked client id shows last 4 only' -Actual (Get-GcMaskedValue 'abcdef123456') -Expected '****3456'

# Mapping a conversation to the auditor schema (fictional IDs)
$fixtureJson = @'
{
  "totalHits": 8,
  "conversations": [
    { "conversationId": "sample-conv-9001", "conversationStart": "2026-09-20T01:00:00.000Z", "conversationEnd": "2026-09-20T01:06:00.000Z",
      "participants": [
        { "purpose": "customer", "sessions": [ { "mediaType": "voice" } ],
          "attributes": { "Survey.Utterance": "ten out of ten", "Survey.Score": "", "Survey.Confidence": "0.58" } } ] },
    { "conversationId": "sample-conv-9002", "conversationStart": "2026-09-20T02:00:00.000Z", "conversationEnd": "2026-09-20T02:04:00.000Z",
      "participants": [
        { "purpose": "customer", "sessions": [ { "mediaType": "message" } ],
          "attributes": { "Survey.Utterance": "9", "Survey.Score": "9" } } ] },
    { "conversationId": "sample-conv-9003", "conversationStart": "2026-09-20T03:00:00.000Z", "conversationEnd": "2026-09-20T03:02:00.000Z",
      "participants": [ { "purpose": "customer", "sessions": [ { "mediaType": "voice" } ] } ] },
    { "conversationId": "sample-conv-9004", "conversationStart": "2026-09-20T04:00:00.000Z", "conversationEnd": "2026-09-20T04:01:00.000Z",
      "participants": [
        { "purpose": "customer", "sessions": [ { "mediaType": "voice" } ] },
        { "purpose": "ivr", "sessions": [ { "mediaType": "voice" } ], "attributes": { "Survey.Status": "Timeout" } } ] },
    { "conversationId": "sample-conv-9005", "conversationStart": "2026-09-20T05:00:00.000Z", "conversationEnd": "2026-09-20T05:05:00.000Z",
      "participants": [
        { "purpose": "customer", "sessions": [ { "mediaType": "voice" } ],
          "attributes": { "PostCall_NPS_Transcript": "I'd say a 9", "PostCall_NPS_Score": "6", "PostCall_NPS_Confidence": "0.71",
                          "PostCall_NPS_Result": "Finished", "Customer.Tier": "Gold", "LeadScore": "88" } } ] },
    { "conversationId": "sample-conv-9006", "conversationStart": "2026-09-20T06:00:00.000Z", "conversationEnd": "2026-09-20T06:03:00.000Z",
      "participants": [
        { "purpose": "customer", "sessions": [ { "mediaType": "voice" } ], "attributes": { "Survey.OptIn": "No" } } ] },
    { "conversationId": "sample-conv-9007", "conversationStart": "2026-09-20T07:00:00.000Z", "conversationEnd": "2026-09-20T07:10:00.000Z",
      "participants": [ { "purpose": "customer", "sessions": [ { "mediaType": "message" } ] } ],
      "surveys": [ { "surveyId": "sample-websurvey-0001", "surveyStatus": "Finished", "surveyPromoterScore": 10,
                     "surveyFormName": "Sample NPS Form", "surveyCompletedDate": "2026-09-20T08:00:00.000Z" } ] },
    { "conversationId": "sample-conv-9008", "conversationStart": "2026-09-20T08:00:00.000Z", "conversationEnd": "2026-09-20T08:03:00.000Z",
      "participants": [
        { "purpose": "customer", "sessions": [ { "mediaType": "voice" } ], "attributes": { "LeadScore": "7", "Intent.Result": "Billing" } } ] }
  ]
}
'@
$fixture = $fixtureJson | ConvertFrom-Json
$global:NpsMockFixture = $fixture
# No attribute names or conversation IDs are supplied: surveys are detected automatically.
$r1 = ConvertFrom-GcConversation -Conversation $fixture.conversations[0]
$r2 = ConvertFrom-GcConversation -Conversation $fixture.conversations[1]
$r3 = ConvertFrom-GcConversation -Conversation $fixture.conversations[2]
$r4 = ConvertFrom-GcConversation -Conversation $fixture.conversations[3]
$r5 = ConvertFrom-GcConversation -Conversation $fixture.conversations[4]
$r6 = ConvertFrom-GcConversation -Conversation $fixture.conversations[5]
$r7 = ConvertFrom-GcConversation -Conversation $fixture.conversations[6]
$r8 = ConvertFrom-GcConversation -Conversation $fixture.conversations[7]
Assert-Equal -Name 'Mapped voice survey: utterance' -Actual $r1.utterance -Expected 'ten out of ten'
Assert-Equal -Name 'Mapped voice survey: channel Voice' -Actual $r1.channel -Expected 'Voice'
Assert-Equal -Name 'Mapped voice survey: completedAt = conversationEnd' -Actual $r1.completedAt -Expected '2026-09-20T01:06:00.000Z'
Assert-Equal -Name 'Mapped voice survey: inferred status Completed' -Actual $r1.participantStatus -Expected 'Completed'
Assert-Equal -Name 'Mapped messaging survey: channel Digital' -Actual $r2.channel -Expected 'Digital'
Write-TestResult -Name 'Conversation without survey attributes is skipped' -Passed ($null -eq $r3) -Detail 'row returned'
Assert-Equal -Name 'Survey status attribute on another participant is used' -Actual $r4.participantStatus -Expected 'Timeout'
Assert-Equal -Name 'Timeout survey detected as Incomplete' -Actual $r4.DetectedState -Expected 'Incomplete'
Assert-Equal -Name 'Auto-detect: custom key names - utterance' -Actual $r5.utterance -Expected "I'd say a 9"
Assert-Equal -Name 'Auto-detect: custom key names - score' -Actual $r5.recordedScore -Expected '6'
Assert-Equal -Name 'Auto-detect: custom key names - confidence' -Actual $r5.confidence -Expected '0.71'
Assert-Equal -Name 'Auto-detect: "Finished" result = Completed' -Actual $r5.DetectedState -Expected 'Completed'
Write-TestResult -Name 'Auto-detect: non-survey keys (LeadScore, Customer.Tier) ignored' -Passed ($r5.DetectedKeys -notmatch 'LeadScore|Tier') -Detail $r5.DetectedKeys
Assert-Equal -Name 'Survey opt-in "No" detected as Declined' -Actual $r6.DetectedState -Expected 'Declined'
Assert-Equal -Name 'Native web survey detected' -Actual $r7.DetectedSource -Expected 'Native web survey'
Assert-Equal -Name 'Native web survey score' -Actual $r7.recordedScore -Expected '10'
Assert-Equal -Name 'Native web survey channel' -Actual $r7.channel -Expected 'Web survey'
Write-TestResult -Name 'Conversation with only non-survey attributes is skipped' -Passed ($null -eq $r8) -Detail 'row returned'

# Key role and status classification
Assert-Equal -Name 'Key role: Survey.Utterance' -Actual (Get-GcSurveyKeyRole -Key 'Survey.Utterance') -Expected 'Utterance'
Assert-Equal -Name 'Key role: NPS_Score' -Actual (Get-GcSurveyKeyRole -Key 'NPS_Score') -Expected 'Score'
Assert-Equal -Name 'Key role: NPS' -Actual (Get-GcSurveyKeyRole -Key 'NPS') -Expected 'Score'
Assert-Equal -Name 'Key role: Survey.ASRConfidence' -Actual (Get-GcSurveyKeyRole -Key 'Survey.ASRConfidence') -Expected 'Confidence'
Assert-Equal -Name 'Key role: Survey.Answer with text = Utterance' -Actual (Get-GcSurveyKeyRole -Key 'Survey.Answer' -Value 'ten out of ten') -Expected 'Utterance'
Assert-Equal -Name 'Key role: Survey.Answer with number = Score' -Actual (Get-GcSurveyKeyRole -Key 'Survey.Answer' -Value '8') -Expected 'Score'
Assert-Equal -Name 'Key role: Survey.AttemptCount ignored' -Actual (Get-GcSurveyKeyRole -Key 'Survey.AttemptCount' -Value '2') -Expected ''
Assert-Equal -Name 'Key role: Survey.StartTime ignored' -Actual (Get-GcSurveyKeyRole -Key 'Survey.StartTime') -Expected ''
Assert-Equal -Name 'Status "Completed"' -Actual (ConvertTo-GcSurveyState -RawStatus 'Completed' -HasAnswer $true).State -Expected 'Completed'
Assert-Equal -Name 'Status "NoInput" is a completed survey (audited as No input)' -Actual (ConvertTo-GcSurveyState -RawStatus 'NoInput').Status -Expected 'Completed'
Assert-Equal -Name 'Status "timed_out" = Timeout' -Actual (ConvertTo-GcSurveyState -RawStatus 'timed_out').Status -Expected 'Timeout'
Assert-Equal -Name 'Status "CustomerHangUp" = Disconnected' -Actual (ConvertTo-GcSurveyState -RawStatus 'CustomerHangUp').Status -Expected 'Disconnected'
Assert-Equal -Name 'Status "OptOut" = Declined' -Actual (ConvertTo-GcSurveyState -RawStatus 'OptOut').State -Expected 'Declined'
Assert-Equal -Name 'No status, no answer = Incomplete' -Actual (ConvertTo-GcSurveyState -RawStatus '' -HasAnswer $false).State -Expected 'Incomplete'
$pinned = ConvertFrom-GcConversation -Conversation ('{"conversationId":"sample-conv-9010","participants":[{"purpose":"customer","sessions":[{"mediaType":"voice"}],"attributes":{"Cx.Heard":"seven","Cx.Captured":"7"}}]}' | ConvertFrom-Json) `
    -AttributeMap @{ Utterance = 'Cx.Heard'; Score = 'Cx.Captured' }
Assert-Equal -Name 'Pinned keys from config are used even without survey keywords' -Actual ($pinned.utterance + '/' + $pinned.recordedScore) -Expected 'seven/7'

# Mocked API: this function shadows the Invoke-RestMethod cmdlet for the rest of the test run.
$global:NpsMockCalls = @()
$global:NpsMockFail401 = $false
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, [switch]$UseBasicParsing, $ErrorAction)
    $global:NpsMockCalls += @{ Method = $Method; Uri = [string]$Uri; Auth = [string]$Headers.Authorization; Body = [string]$Body }
    if ($Uri -like '*/oauth/token') {
        if ($global:NpsMockFail401) { throw 'The remote server returned an error: (401) Unauthorized.' }
        return (New-Object PSObject -Property @{ access_token = 'mock-access-token'; token_type = 'bearer'; expires_in = 86400 })
    }
    if ($Uri -like '*/api/v2/analytics/conversations/details/query') {
        # Validate the request body the connector sends.
        $q = $Body | ConvertFrom-Json
        if ([string]$q.interval -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.000Z/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.000Z$') { throw ('Bad interval in mock: ' + $q.interval) }
        if ([int]$q.paging.pageSize -ne 100) { throw 'Bad page size in mock' }
        if ([string]$Headers.Authorization -ne 'Bearer mock-access-token') { throw 'Bad bearer token in mock' }
        # Return the fixture for the first day only; other days are empty.
        if (@($global:NpsMockCalls | Where-Object { $_.Uri -like '*details/query' }).Count -eq 1) { return $global:NpsMockFixture }
        return (New-Object PSObject -Property @{ totalHits = 0 })
    }
    throw ('Unexpected URI in mock: ' + $Uri)
}

$env:GENESYS_CLIENT_ID = 'test-client-id-0000'
$env:GENESYS_CLIENT_SECRET = 'test-secret-do-not-print'

$token = Get-GcAccessToken -LoginBaseUri 'https://login.mypurecloud.com.au' -ClientId 'test-client-id-0000' -ClientSecret 'test-secret-do-not-print'
Assert-Equal -Name 'Access token returned from mocked OAuth' -Actual $token -Expected 'mock-access-token'
Assert-Equal -Name 'Token request uses Australia login host' -Actual $global:NpsMockCalls[0].Uri -Expected 'https://login.mypurecloud.com.au/oauth/token'
Assert-Equal -Name 'Token request sends Basic auth (pure PowerShell Base64)' -Actual $global:NpsMockCalls[0].Auth `
    -Expected ('Basic ' + (ConvertTo-GcBase64 -Text 'test-client-id-0000:test-secret-do-not-print'))

$global:NpsMockFail401 = $true
$authError = ''
try { Get-GcAccessToken -LoginBaseUri 'https://login.mypurecloud.com.au' -ClientId 'x' -ClientSecret 'y' | Out-Null } catch { $authError = $_.Exception.Message }
Write-TestResult -Name 'HTTP 401 gives a clear authentication error' -Passed ($authError -match '401') -Detail $authError
$global:NpsMockFail401 = $false

if (-not $SkipIntegration) {
    $connectorScript = Join-Path $repoRoot 'Get-GenesysNpsSurveyData.ps1'
    $connectorOut = Join-Path (Join-Path $repoRoot 'output') ('_test-connector-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    $noConfig = Join-Path $connectorOut 'no-config.json'

    $global:NpsMockCalls = @()
    $console = (& $connectorScript -OutputPath $connectorOut -ConfigPath $noConfig -RunAudit *>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { Write-Host $console }
    Assert-Equal -Name 'Connector + audit exit code 0' -Actual $LASTEXITCODE -Expected 0
    Assert-Equal -Name 'Connector queries 7 daily intervals by default' -Actual @($global:NpsMockCalls | Where-Object { $_.Uri -like '*details/query' }).Count -Expected 7
    Write-TestResult -Name 'Connector uses Australia API host by default' -Passed (@($global:NpsMockCalls | Where-Object { $_.Uri -like 'https://api.mypurecloud.com.au/*' }).Count -eq 7) -Detail 'wrong host'
    Write-TestResult -Name 'Client secret never printed to console' -Passed ($console -notmatch 'test-secret-do-not-print') -Detail 'secret found in output'
    Write-TestResult -Name 'Access token never printed to console' -Passed ($console -notmatch 'mock-access-token') -Detail 'token found in output'

    $export = @(Get-ChildItem -LiteralPath $connectorOut -Filter 'genesys-survey-export-*.csv')
    Write-TestResult -Name 'Connector writes export CSV' -Passed ($export.Count -eq 1) -Detail ('found ' + $export.Count)
    if ($export.Count -eq 1) {
        $exportText = Get-Content -LiteralPath $export[0].FullName -Raw
        $exportRows = @(Import-Csv -LiteralPath $export[0].FullName)
        Assert-Equal -Name 'Export contains 5 surveys (declined and non-survey excluded)' -Actual $exportRows.Count -Expected 5
        Write-TestResult -Name 'Export has exactly the auditor schema columns' -Passed ((@($exportRows[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -eq 'surveyId,conversationId,completedAt,channel,question,utterance,recordedScore,confidence,participantStatus') -Detail 'column mismatch'
        Write-TestResult -Name 'Export CSV contains no credentials' -Passed ($exportText -notmatch 'test-secret|mock-access-token') -Detail 'credential in file'
    }
    $auditDetail = @(Get-ChildItem -LiteralPath $connectorOut -Filter 'nps-audit-detail-*.csv')
    if ($auditDetail.Count -eq 1) {
        $auditRows = @(Import-Csv -LiteralPath $auditDetail[0].FullName)
        $missed = @($auditRows | Where-Object { $_.ConversationId -eq 'sample-conv-9001' })[0]
        Assert-Equal -Name 'Audit on API data flags the missed score' -Actual $missed.AuditStatus -Expected 'Likely missed score'
        $mismatch = @($auditRows | Where-Object { $_.ConversationId -eq 'sample-conv-9005' })[0]
        Assert-Equal -Name 'Audit on auto-detected survey flags the mismatch' -Actual $mismatch.AuditStatus -Expected 'Score mismatch'
    }
    else { Write-TestResult -Name 'Audit ran on API data' -Passed $false -Detail 'no detail report' }

    # -CompletedOnly keeps completed surveys only
    $completedOut = Join-Path $connectorOut 'completed-only'
    $global:NpsMockCalls = @()
    & $connectorScript -OutputPath $completedOut -ConfigPath $noConfig -CompletedOnly *> $null
    $completedExport = @(Get-ChildItem -LiteralPath $completedOut -Filter 'genesys-survey-export-*.csv' -ErrorAction SilentlyContinue)
    $completedRows = @()
    if ($completedExport.Count -eq 1) { $completedRows = @(Import-Csv -LiteralPath $completedExport[0].FullName) }
    Assert-Equal -Name '-CompletedOnly exports the 4 completed surveys' -Actual $completedRows.Count -Expected 4

    # Missing credentials -> exit 2, and no API call is made
    $env:GENESYS_CLIENT_SECRET = ''
    $global:NpsMockCalls = @()
    & $connectorScript -OutputPath $connectorOut -ConfigPath $noConfig *> $null
    Assert-Equal -Name 'Missing GENESYS_CLIENT_SECRET returns exit code 2' -Actual $LASTEXITCODE -Expected 2
    Assert-Equal -Name 'No API call made without credentials' -Actual $global:NpsMockCalls.Count -Expected 0
    $env:GENESYS_CLIENT_SECRET = 'test-secret-do-not-print'

    # A config file holding a secret is refused
    $badConfig = Join-Path $connectorOut 'bad-config.json'
    Set-Content -LiteralPath $badConfig -Value '{ "region": "mypurecloud.com.au", "clientSecret": "oops" }' -Encoding UTF8
    & $connectorScript -OutputPath $connectorOut -ConfigPath $badConfig *> $null
    Assert-Equal -Name 'Config containing a secret is refused (exit code 2)' -Actual $LASTEXITCODE -Expected 2

    # Auth failure -> exit 3
    $global:NpsMockFail401 = $true
    & $connectorScript -OutputPath $connectorOut -ConfigPath $noConfig *> $null
    Assert-Equal -Name 'Authentication failure returns exit code 3' -Actual $LASTEXITCODE -Expected 3
    $global:NpsMockFail401 = $false

    Remove-Item -LiteralPath $connectorOut -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -Path Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
Remove-Variable -Name NpsMockCalls, NpsMockFail401, NpsMockFixture -Scope Global -ErrorAction SilentlyContinue
$env:GENESYS_CLIENT_ID = $savedId
$env:GENESYS_CLIENT_SECRET = $savedSecret
$env:GENESYS_REGION = $savedRegion

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
