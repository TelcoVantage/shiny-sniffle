<#
.SYNOPSIS
    Audits Genesys Cloud-style NPS survey responses from a CSV export and produces audit reports.

.DESCRIPTION
    Reads a survey-response CSV, analyses every utterance, and classifies each response as
    Valid, Likely missed score, Score mismatch, Low-confidence capture, Ambiguous response,
    Invalid score response, No input, Abandoned survey, or Review required.

    Produces (timestamped):
        nps-audit-detail-YYYYMMDD-HHMMSS.csv      every record with its audit result
        nps-audit-exceptions-YYYYMMDD-HHMMSS.csv  High and Medium priority records only
        nps-audit-summary-YYYYMMDD-HHMMSS.csv     counts, distributions and NPS
        nps-audit-report-YYYYMMDD-HHMMSS.html     optional offline HTML report (-ExportHtmlReport)

    Works fully offline. No API connection, credentials, or internet access is needed.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+, including Constrained Language
    Mode (AppLocker / WDAC): no .NET static calls, no Add-Type, no classes, no external modules.

    Exit codes:
        0  Audit completed (data exceptions found in the survey data are NOT failures)
        1  Unexpected script error
        2  Input validation error (missing file, missing columns, unreadable CSV)

.PARAMETER InputPath
    Path to the survey-response CSV. Defaults to .\sample-data\survey-responses.csv next to this script.

.PARAMETER OutputPath
    Folder for generated reports. Created if missing. Defaults to .\output next to this script.

.PARAMETER ConfidenceThreshold
    Minimum acceptable recognition confidence (0.0 - 1.0). Default 0.70.

.PARAMETER ExportHtmlReport
    Also generate a standalone HTML report.

.EXAMPLE
    .\Export-GenesysNpsAudit.ps1 -InputPath ".\sample-data\survey-responses.csv" -OutputPath ".\output" -ExportHtmlReport

.EXAMPLE
    .\Export-GenesysNpsAudit.ps1 -InputPath ".\sample-data\survey-responses.csv" -ConfidenceThreshold 0.80

.NOTES
    Project : Genesys NPS Survey Auditor
    This is an independent community project. It is not an official Genesys product,
    integration, or endorsement. Use synthetic or sanitised data only in public demonstrations.
#>
[CmdletBinding()]
param(
    [string]$InputPath,
    [string]$OutputPath,
    [ValidateRange(0.0, 1.0)][double]$ConfidenceThreshold = 0.70,
    [switch]$ExportHtmlReport
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------------------------

$RequiredColumns = @('surveyId', 'conversationId', 'completedAt', 'channel', 'question',
                     'utterance', 'recordedScore', 'confidence', 'participantStatus')

# Column order for the detail and exceptions reports.
$DetailColumns = @('SurveyId', 'ConversationId', 'CompletedAt', 'Channel', 'Question', 'Utterance',
                   'RecordedScore', 'ExpectedScore', 'Confidence', 'ParticipantStatus', 'AuditStatus',
                   'Priority', 'Reason', 'NpsCategoryRecorded', 'NpsCategoryExpected', 'RequiresReview')

# ---------------------------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------------------------

function Write-AuditFailure {
    # Writes a clear failure message. Write-Host is used rather than Write-Error so the
    # message is not turned into a terminating error by $ErrorActionPreference = 'Stop'.
    param([string]$Message)
    Write-Host ''
    Write-Host ('ERROR: ' + $Message) -ForegroundColor Red
}

function ConvertTo-HtmlText {
    # Minimal HTML encoding without System.Web / WebUtility (CLM-safe).
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function Format-NpsDisplay {
    # Returns a signed NPS string such as "+12.5", "-4.0", or "N/A".
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'N/A' }
    $text = Format-NpsNumber -Value $Value -Decimals 1
    if ($Value -gt 0) { $text = '+' + $text }
    return $text
}

function Format-Percent {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'N/A' }
    return (Format-NpsNumber -Value $Value -Decimals 1) + '%'
}

function New-SummaryRow {
    param([string]$Section, [string]$Metric, $Value, [string]$Notes = '')
    $row = New-Object PSObject -Property @{
        Section = $Section
        Metric  = $Metric
        Value   = [string]$Value
        Notes   = $Notes
    }
    return ($row | Select-Object Section, Metric, Value, Notes)
}

function Get-CountWhere {
    # Counts items in $Items whose property $Property equals $Equals.
    param([object[]]$Items, [string]$Property, $Equals)
    return @($Items | Where-Object { $_.$Property -eq $Equals }).Count
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

try {
    $scriptRoot = $PSScriptRoot
    if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

    $libraryPath = Join-Path $scriptRoot 'Invoke-NpsUtteranceAnalysis.ps1'
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        Write-AuditFailure "Required library not found: $libraryPath"
        exit 1
    }
    . $libraryPath

    if (-not $InputPath)  { $InputPath = Join-Path (Join-Path $scriptRoot 'sample-data') 'survey-responses.csv' }
    if (-not $OutputPath) { $OutputPath = Join-Path $scriptRoot 'output' }

    Write-Host ''
    Write-Host '=== Genesys NPS Survey Auditor ===' -ForegroundColor Cyan
    Write-Host 'Independent community tool. Use synthetic or sanitised data only.' -ForegroundColor DarkGray
    Write-Host ''

    # ---- Validate input -------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
        Write-AuditFailure "Input file not found: $InputPath"
        exit 2
    }
    $resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
    $inputFileName = Split-Path -Leaf $resolvedInput

    $headerLine = Get-Content -LiteralPath $resolvedInput -TotalCount 1
    if ($null -eq $headerLine -or ([string]$headerLine).Trim() -eq '') {
        Write-AuditFailure "Input file is empty or has no header row: $inputFileName"
        exit 2
    }
    $headers = @(([string]$headerLine) -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim() })
    $missing = @($RequiredColumns | Where-Object { $headers -notcontains $_ })
    if ($missing.Count -gt 0) {
        Write-AuditFailure ('Input file is missing required column(s): ' + ($missing -join ', '))
        Write-Host ('Required columns: ' + ($RequiredColumns -join ',')) -ForegroundColor Yellow
        exit 2
    }

    try {
        $rows = @(Import-Csv -LiteralPath $resolvedInput)
    }
    catch {
        Write-AuditFailure ("Could not read CSV '$inputFileName': " + $_.Exception.Message)
        exit 2
    }

    Write-Host ("Input file           : $inputFileName")
    Write-Host ("Records found        : " + $rows.Count)
    Write-Host ("Confidence threshold : " + (Format-NpsNumber -Value $ConfidenceThreshold -Decimals 2))
    if ($rows.Count -eq 0) {
        Write-Host 'Warning: the input file contains a header but no data rows. Empty reports will be produced.' -ForegroundColor Yellow
    }

    # ---- Prepare output -------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $resolvedOutput = (Resolve-Path -LiteralPath $OutputPath).Path
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $detailFile     = Join-Path $resolvedOutput "nps-audit-detail-$stamp.csv"
    $exceptionsFile = Join-Path $resolvedOutput "nps-audit-exceptions-$stamp.csv"
    $summaryFile    = Join-Path $resolvedOutput "nps-audit-summary-$stamp.csv"
    $htmlFile       = Join-Path $resolvedOutput "nps-audit-report-$stamp.html"

    # ---- Analyse every record -------------------------------------------------------------
    $detail = @()
    foreach ($row in $rows) {
        $utterance = [string]$row.utterance
        $recordedRaw = ([string]$row.recordedScore).Trim()
        $confidenceRaw = ([string]$row.confidence).Trim()
        $participantRaw = ([string]$row.participantStatus).Trim()
        $channel = ([string]$row.channel).Trim()
        if ($channel -eq '') { $channel = 'Unknown' }

        $analysis = Invoke-NpsUtteranceAnalysis -Utterance $utterance -RecordedScore $recordedRaw `
            -Confidence $confidenceRaw -ParticipantStatus $participantRaw -ConfidenceThreshold $ConfidenceThreshold

        $record = New-Object PSObject -Property @{
            SurveyId            = ([string]$row.surveyId).Trim()
            ConversationId      = ([string]$row.conversationId).Trim()
            CompletedAt         = ([string]$row.completedAt).Trim()
            Channel             = $channel
            Question            = ([string]$row.question).Trim()
            Utterance           = $utterance.Trim()
            RecordedScore       = $recordedRaw
            ExpectedScore       = $analysis.ExpectedScore
            Confidence          = $confidenceRaw
            ParticipantStatus   = $participantRaw
            AuditStatus         = $analysis.AuditStatus
            Priority            = $analysis.Priority
            Reason              = $analysis.Reason
            NpsCategoryRecorded = $analysis.NpsCategoryRecorded
            NpsCategoryExpected = $analysis.NpsCategoryExpected
            RequiresReview      = $analysis.RequiresReview
            # Internal fields used for the summary; not exported.
            RecordedScoreValue  = $analysis.RecordedScoreValue
        }
        $detail += $record
    }

    $exceptions = @($detail | Where-Object { $_.Priority -eq 'High' -or $_.Priority -eq 'Medium' })
    $highPriority = @($detail | Where-Object { $_.Priority -eq 'High' })
    $mediumPriority = @($detail | Where-Object { $_.Priority -eq 'Medium' })

    # ---- NPS calculations -----------------------------------------------------------------
    # Official NPS: only recorded scores that are valid whole numbers from 0 to 10.
    $recordedScores = @($detail | Where-Object { $null -ne $_.RecordedScoreValue } | ForEach-Object { $_.RecordedScoreValue })
    # Potentially corrected NPS (audit estimate): scores identified from utterances.
    $expectedScores = @($detail | Where-Object { $null -ne $_.ExpectedScore } | ForEach-Object { $_.ExpectedScore })

    $official = Get-NpsScoreSummary -Scores $recordedScores
    $corrected = Get-NpsScoreSummary -Scores $expectedScores

    # ---- Breakdowns -----------------------------------------------------------------------
    $statusList = @(Get-NpsAuditStatusList)
    $statusCounts = @()
    foreach ($s in $statusList) {
        $statusCounts += New-Object PSObject -Property @{
            Status      = $s.Status
            Description = $s.Description
            Priority    = (Get-NpsAuditPriority -AuditStatus $s.Status)
            Count       = (Get-CountWhere -Items $detail -Property 'AuditStatus' -Equals $s.Status)
        }
    }

    $distribution = @()
    for ($score = 0; $score -le 10; $score++) {
        $distribution += New-Object PSObject -Property @{
            Score    = $score
            Category = (Get-NpsCategory -Score $score)
            Recorded = @($recordedScores | Where-Object { $_ -eq $score }).Count
            Expected = @($expectedScores | Where-Object { $_ -eq $score }).Count
        }
    }
    $notRecorded = $detail.Count - $recordedScores.Count
    $notIdentified = $detail.Count - $expectedScores.Count

    $channelStats = @()
    foreach ($group in @($detail | Group-Object -Property Channel | Sort-Object -Property Name)) {
        $items = @($group.Group)
        $channelRecorded = @($items | Where-Object { $null -ne $_.RecordedScoreValue } | ForEach-Object { $_.RecordedScoreValue })
        $channelNps = Get-NpsScoreSummary -Scores $channelRecorded
        $channelStats += New-Object PSObject -Property @{
            Channel      = $group.Name
            Records      = $items.Count
            Valid        = (Get-CountWhere -Items $items -Property 'AuditStatus' -Equals 'Valid')
            Exceptions   = @($items | Where-Object { $_.Priority -ne 'None' }).Count
            HighPriority = (Get-CountWhere -Items $items -Property 'Priority' -Equals 'High')
            OfficialNps  = $channelNps.Nps
        }
    }

    # ---- Detail and exceptions CSV --------------------------------------------------------
    $detail | Select-Object -Property $DetailColumns |
        Export-Csv -LiteralPath $detailFile -NoTypeInformation -Encoding UTF8
    $exceptions | Select-Object -Property $DetailColumns |
        Export-Csv -LiteralPath $exceptionsFile -NoTypeInformation -Encoding UTF8
    # Export-Csv writes nothing for an empty collection; always leave a file with headers.
    if ($exceptions.Count -eq 0) {
        Set-Content -LiteralPath $exceptionsFile -Value ('"' + ($DetailColumns -join '","') + '"') -Encoding UTF8
    }
    if ($detail.Count -eq 0) {
        Set-Content -LiteralPath $detailFile -Value ('"' + ($DetailColumns -join '","') + '"') -Encoding UTF8
    }

    # ---- Summary CSV ----------------------------------------------------------------------
    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $thresholdText = Format-NpsNumber -Value $ConfidenceThreshold -Decimals 2
    $summary = @()
    $summary += New-SummaryRow 'Run' 'GeneratedAt' $generatedAt 'Local time'
    $summary += New-SummaryRow 'Run' 'InputFile' $inputFileName 'File name only; full path intentionally omitted'
    $summary += New-SummaryRow 'Run' 'ConfidenceThreshold' $thresholdText

    $summary += New-SummaryRow 'Overview' 'TotalRecords' $detail.Count
    $summary += New-SummaryRow 'Overview' 'ExceptionCount' $exceptions.Count 'High + Medium priority'
    $summary += New-SummaryRow 'Overview' 'HighPriorityExceptions' $highPriority.Count
    $summary += New-SummaryRow 'Overview' 'MediumPriorityExceptions' $mediumPriority.Count

    foreach ($s in $statusCounts) { $summary += New-SummaryRow 'AuditStatus' $s.Status $s.Count ('Priority: ' + $s.Priority) }
    foreach ($p in @('High', 'Medium', 'None')) {
        $summary += New-SummaryRow 'Priority' $p (Get-CountWhere -Items $detail -Property 'Priority' -Equals $p)
    }
    foreach ($c in $channelStats) {
        $summary += New-SummaryRow 'Channel' $c.Channel $c.Records ("Valid: $($c.Valid); Exceptions: $($c.Exceptions); High: $($c.HighPriority); Official NPS: " + (Format-NpsDisplay $c.OfficialNps))
    }
    foreach ($d in $distribution) { $summary += New-SummaryRow 'RecordedScoreDistribution' ([string]$d.Score) $d.Recorded $d.Category }
    $summary += New-SummaryRow 'RecordedScoreDistribution' 'NotRecordedOrInvalid' $notRecorded
    foreach ($d in $distribution) { $summary += New-SummaryRow 'ExpectedScoreDistribution' ([string]$d.Score) $d.Expected $d.Category }
    $summary += New-SummaryRow 'ExpectedScoreDistribution' 'NotIdentified' $notIdentified

    $officialNote = 'Uses valid recorded scores (0-10) only'
    $summary += New-SummaryRow 'OfficialNps' 'ValidScoredResponses' $official.ScoredResponses $officialNote
    $summary += New-SummaryRow 'OfficialNps' 'Promoters' $official.Promoters '9-10'
    $summary += New-SummaryRow 'OfficialNps' 'Passives' $official.Passives '7-8'
    $summary += New-SummaryRow 'OfficialNps' 'Detractors' $official.Detractors '0-6'
    $summary += New-SummaryRow 'OfficialNps' 'PromoterPercent' (Format-Percent $official.PromoterPercent)
    $summary += New-SummaryRow 'OfficialNps' 'DetractorPercent' (Format-Percent $official.DetractorPercent)
    $summary += New-SummaryRow 'OfficialNps' 'NPS' (Format-NpsDisplay $official.Nps) '% Promoters - % Detractors'

    $estimateNote = 'AUDIT ESTIMATE ONLY - not an official NPS result'
    $summary += New-SummaryRow 'PotentiallyCorrectedNps' 'ScoredResponses' $corrected.ScoredResponses 'Uses expected scores identified from utterances'
    $summary += New-SummaryRow 'PotentiallyCorrectedNps' 'Promoters' $corrected.Promoters $estimateNote
    $summary += New-SummaryRow 'PotentiallyCorrectedNps' 'Passives' $corrected.Passives $estimateNote
    $summary += New-SummaryRow 'PotentiallyCorrectedNps' 'Detractors' $corrected.Detractors $estimateNote
    $summary += New-SummaryRow 'PotentiallyCorrectedNps' 'PromoterPercent' (Format-Percent $corrected.PromoterPercent) $estimateNote
    $summary += New-SummaryRow 'PotentiallyCorrectedNps' 'DetractorPercent' (Format-Percent $corrected.DetractorPercent) $estimateNote
    $summary += New-SummaryRow 'PotentiallyCorrectedNps' 'NPS' (Format-NpsDisplay $corrected.Nps) $estimateNote

    $summary | Export-Csv -LiteralPath $summaryFile -NoTypeInformation -Encoding UTF8

    # ---- Optional HTML report -------------------------------------------------------------
    if ($ExportHtmlReport) {
        $maxDist = 1
        foreach ($d in $distribution) {
            if ($d.Recorded -gt $maxDist) { $maxDist = $d.Recorded }
            if ($d.Expected -gt $maxDist) { $maxDist = $d.Expected }
        }

        $statusRowsHtml = ''
        foreach ($s in $statusCounts) {
            $pClass = 'p-' + $s.Priority.ToLower()
            $statusRowsHtml += '<tr><td>' + (ConvertTo-HtmlText $s.Status) + '</td><td class="num">' + $s.Count +
                '</td><td><span class="badge ' + $pClass + '">' + $s.Priority + '</span></td></tr>' + "`n"
        }

        $distRowsHtml = ''
        foreach ($d in $distribution) {
            $recWidth = [int](($d.Recorded / $maxDist) * 100)
            $expWidth = [int](($d.Expected / $maxDist) * 100)
            $catClass = 'cat-' + $d.Category.ToLower()
            $distRowsHtml += '<tr><td class="num">' + $d.Score + '</td><td><span class="' + $catClass + '">' + $d.Category + '</span></td>' +
                '<td class="num">' + $d.Recorded + '</td><td><div class="bar rec" style="width:' + $recWidth + '%"></div></td>' +
                '<td class="num">' + $d.Expected + '</td><td><div class="bar exp" style="width:' + $expWidth + '%"></div></td></tr>' + "`n"
        }
        $distRowsHtml += '<tr class="muted"><td colspan="2">Not recorded / not identified</td><td class="num">' + $notRecorded +
            '</td><td></td><td class="num">' + $notIdentified + '</td><td></td></tr>' + "`n"

        $channelRowsHtml = ''
        foreach ($c in $channelStats) {
            $channelRowsHtml += '<tr><td>' + (ConvertTo-HtmlText $c.Channel) + '</td><td class="num">' + $c.Records + '</td><td class="num">' + $c.Valid +
                '</td><td class="num">' + $c.Exceptions + '</td><td class="num">' + $c.HighPriority + '</td><td class="num">' + (Format-NpsDisplay $c.OfficialNps) + '</td></tr>' + "`n"
        }

        $exceptionTable = {
            param($Items)
            if (@($Items).Count -eq 0) { return '<p class="muted">None found.</p>' }
            $html = '<div class="table-wrap"><table><thead><tr><th>Survey ID</th><th>Channel</th><th>Utterance</th><th class="num">Recorded</th>' +
                '<th class="num">Expected</th><th class="num">Confidence</th><th>Status</th><th>Reason</th></tr></thead><tbody>' + "`n"
            foreach ($e in @($Items)) {
                $utt = $e.Utterance
                if ($utt -eq '') { $utt = '(blank)' }
                $html += '<tr><td class="mono">' + (ConvertTo-HtmlText $e.SurveyId) + '</td><td>' + (ConvertTo-HtmlText $e.Channel) +
                    '</td><td>' + (ConvertTo-HtmlText $utt) + '</td><td class="num">' + (ConvertTo-HtmlText $e.RecordedScore) +
                    '</td><td class="num">' + (ConvertTo-HtmlText $e.ExpectedScore) + '</td><td class="num">' + (ConvertTo-HtmlText $e.Confidence) +
                    '</td><td>' + (ConvertTo-HtmlText $e.AuditStatus) + '</td><td>' + (ConvertTo-HtmlText $e.Reason) + '</td></tr>' + "`n"
            }
            $html += '</tbody></table></div>'
            return $html
        }
        $highTableHtml = & $exceptionTable $highPriority
        $mediumTableHtml = & $exceptionTable $mediumPriority

        $legendHtml = ''
        foreach ($s in $statusList) {
            $legendHtml += '<dt>' + (ConvertTo-HtmlText $s.Status) + '</dt><dd>' + (ConvertTo-HtmlText $s.Description) + '</dd>' + "`n"
        }

        $officialNpsText = Format-NpsDisplay $official.Nps
        $correctedNpsText = Format-NpsDisplay $corrected.Nps

        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NPS Survey Audit Report</title>
<style>
  :root { --ink:#1f2933; --muted:#616e7c; --line:#e4e7eb; --bg:#f5f7fa; --card:#ffffff;
          --accent:#2f6f9f; --high:#b42318; --medium:#b54708; --none:#067647;
          --promoter:#067647; --passive:#8a6d00; --detractor:#b42318; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:"Segoe UI", Roboto, Helvetica, Arial, sans-serif; color:var(--ink); background:var(--bg); line-height:1.45; }
  header { background:#1f3a52; color:#fff; padding:28px 32px; }
  header h1 { margin:0 0 4px; font-size:24px; font-weight:600; }
  header p { margin:0; color:#c9d6e2; font-size:14px; }
  main { max-width:1200px; margin:0 auto; padding:24px 32px 48px; }
  h2 { font-size:18px; margin:32px 0 12px; padding-bottom:6px; border-bottom:2px solid var(--line); }
  .cards { display:grid; grid-template-columns:repeat(auto-fit, minmax(190px, 1fr)); gap:14px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:16px 18px; }
  .card .label { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); }
  .card .value { font-size:30px; font-weight:600; margin-top:4px; }
  .card .hint { font-size:12px; color:var(--muted); margin-top:2px; }
  .card.high .value { color:var(--high); }
  .grid-2 { display:grid; grid-template-columns:repeat(auto-fit, minmax(420px, 1fr)); gap:24px; }
  .table-wrap { overflow-x:auto; }
  table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--line); font-size:14px; }
  th, td { padding:8px 10px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top; }
  th { background:#eef2f6; font-weight:600; font-size:13px; }
  td.num, th.num { text-align:right; white-space:nowrap; }
  .mono { font-family:Consolas, "Courier New", monospace; font-size:13px; white-space:nowrap; }
  .muted, tr.muted td { color:var(--muted); }
  .badge { display:inline-block; padding:1px 8px; border-radius:10px; font-size:12px; font-weight:600; color:#fff; }
  .p-high { background:var(--high); } .p-medium { background:var(--medium); } .p-none { background:var(--none); }
  .cat-promoter { color:var(--promoter); font-weight:600; } .cat-passive { color:var(--passive); font-weight:600; } .cat-detractor { color:var(--detractor); font-weight:600; }
  .bar { height:12px; border-radius:3px; min-width:2px; }
  .bar.rec { background:var(--accent); } .bar.exp { background:#8fb3cf; }
  dl { display:grid; grid-template-columns:220px 1fr; gap:6px 16px; background:var(--card); border:1px solid var(--line); border-radius:8px; padding:16px; margin:0; font-size:14px; }
  dt { font-weight:600; } dd { margin:0; color:var(--muted); }
  .note { font-size:13px; color:var(--muted); }
  .disclaimer { margin-top:32px; background:#fff8e6; border:1px solid #f3d9a4; border-radius:8px; padding:14px 18px; font-size:13px; }
  footer { text-align:center; color:var(--muted); font-size:12px; padding:16px; }
  @media (max-width:600px) { main { padding:16px; } header { padding:20px 16px; } dl { grid-template-columns:1fr; } .grid-2 { grid-template-columns:1fr; } }
</style>
</head>
<body>
<header>
  <h1>NPS Survey Audit Report</h1>
  <p>Generated $(ConvertTo-HtmlText $generatedAt) &middot; Input: $(ConvertTo-HtmlText $inputFileName) &middot; Confidence threshold: $thresholdText</p>
</header>
<main>
  <section class="cards">
    <div class="card"><div class="label">Total records</div><div class="value">$($detail.Count)</div><div class="hint">Survey responses analysed</div></div>
    <div class="card"><div class="label">Exceptions</div><div class="value">$($exceptions.Count)</div><div class="hint">High + Medium priority</div></div>
    <div class="card high"><div class="label">High-priority exceptions</div><div class="value">$($highPriority.Count)</div><div class="hint">Missed, mismatched, invalid, abandoned</div></div>
    <div class="card"><div class="label">Official NPS</div><div class="value">$officialNpsText</div><div class="hint">$($official.ScoredResponses) valid recorded scores</div></div>
    <div class="card"><div class="label">Audit-estimated NPS</div><div class="value">$correctedNpsText</div><div class="hint">Estimate only &middot; $($corrected.ScoredResponses) scores from utterances</div></div>
  </section>

  <h2>NPS breakdown</h2>
  <div class="table-wrap"><table>
    <thead><tr><th>Measure</th><th class="num">Promoters (9-10)</th><th class="num">Passives (7-8)</th><th class="num">Detractors (0-6)</th><th class="num">% Promoters</th><th class="num">% Detractors</th><th class="num">NPS</th></tr></thead>
    <tbody>
      <tr><td>Official (recorded scores)</td><td class="num">$($official.Promoters)</td><td class="num">$($official.Passives)</td><td class="num">$($official.Detractors)</td><td class="num">$(Format-Percent $official.PromoterPercent)</td><td class="num">$(Format-Percent $official.DetractorPercent)</td><td class="num"><strong>$officialNpsText</strong></td></tr>
      <tr><td>Potentially corrected (audit estimate)</td><td class="num">$($corrected.Promoters)</td><td class="num">$($corrected.Passives)</td><td class="num">$($corrected.Detractors)</td><td class="num">$(Format-Percent $corrected.PromoterPercent)</td><td class="num">$(Format-Percent $corrected.DetractorPercent)</td><td class="num"><strong>$correctedNpsText</strong></td></tr>
    </tbody>
  </table></div>
  <p class="note">NPS = % Promoters &minus; % Detractors. The potentially corrected NPS uses scores identified from customer utterances and is an audit estimate only, not an official NPS result.</p>

  <div class="grid-2">
    <div>
      <h2>Audit status breakdown</h2>
      <table><thead><tr><th>Audit status</th><th class="num">Records</th><th>Priority</th></tr></thead>
      <tbody>
$statusRowsHtml      </tbody></table>
    </div>
    <div>
      <h2>Channel breakdown</h2>
      <table><thead><tr><th>Channel</th><th class="num">Records</th><th class="num">Valid</th><th class="num">Exceptions</th><th class="num">High</th><th class="num">Official NPS</th></tr></thead>
      <tbody>
$channelRowsHtml      </tbody></table>
    </div>
  </div>

  <h2>Score distribution (0-10)</h2>
  <div class="table-wrap"><table>
    <thead><tr><th class="num">Score</th><th>Category</th><th class="num">Recorded</th><th style="width:28%"></th><th class="num">Expected</th><th style="width:28%"></th></tr></thead>
    <tbody>
$distRowsHtml    </tbody>
  </table></div>

  <h2>High-priority exceptions ($($highPriority.Count))</h2>
  $highTableHtml

  <h2>Medium-priority exceptions ($($mediumPriority.Count))</h2>
  $mediumTableHtml

  <h2>Audit status definitions</h2>
  <dl>
$legendHtml  </dl>

  <div class="disclaimer">
    <strong>Privacy notice.</strong> This report may contain customer utterances. Data used in public demonstrations,
    portfolios, or repositories must be synthetic or fully sanitised: no real customer data, ANI/DNIS, conversation IDs,
    recordings, transcripts, credentials, or internal configuration. Do not commit generated reports to source control.
  </div>
</main>
<footer>Genesys NPS Survey Auditor &middot; Independent community project &middot; Not an official Genesys product, integration, or endorsement.</footer>
</body>
</html>
"@
        Set-Content -LiteralPath $htmlFile -Value $html -Encoding UTF8
    }

    # ---- Console summary ------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Audit status breakdown' -ForegroundColor Cyan
    foreach ($s in $statusCounts) {
        $colour = 'Gray'
        if ($s.Count -gt 0 -and $s.Priority -eq 'High') { $colour = 'Red' }
        elseif ($s.Count -gt 0 -and $s.Priority -eq 'Medium') { $colour = 'Yellow' }
        elseif ($s.Count -gt 0) { $colour = 'Green' }
        Write-Host ('  {0,-24} {1,5}   [{2}]' -f $s.Status, $s.Count, $s.Priority) -ForegroundColor $colour
    }

    Write-Host ''
    Write-Host 'NPS' -ForegroundColor Cyan
    Write-Host ('  Official NPS            : {0,7}   ({1} valid recorded scores: {2} promoters, {3} passives, {4} detractors)' -f `
        (Format-NpsDisplay $official.Nps), $official.ScoredResponses, $official.Promoters, $official.Passives, $official.Detractors)
    Write-Host ('  Potentially corrected   : {0,7}   ({1} scores from utterances) - AUDIT ESTIMATE ONLY' -f `
        (Format-NpsDisplay $corrected.Nps), $corrected.ScoredResponses)

    Write-Host ''
    Write-Host 'Findings' -ForegroundColor Cyan
    Write-Host ('  Exceptions              : {0}  (High: {1}, Medium: {2})' -f $exceptions.Count, $highPriority.Count, $mediumPriority.Count)
    $missed = Get-CountWhere -Items $detail -Property 'AuditStatus' -Equals 'Likely missed score'
    $mismatch = Get-CountWhere -Items $detail -Property 'AuditStatus' -Equals 'Score mismatch'
    if ($missed -gt 0)   { Write-Host "  - $missed response(s) contain a clear score that was not recorded." -ForegroundColor Red }
    if ($mismatch -gt 0) { Write-Host "  - $mismatch response(s) have a recorded score that differs from what the customer said." -ForegroundColor Red }
    if ($exceptions.Count -eq 0) { Write-Host '  No exceptions found.' -ForegroundColor Green }

    Write-Host ''
    Write-Host 'Reports written' -ForegroundColor Cyan
    Write-Host "  Detail     : $detailFile"
    Write-Host "  Exceptions : $exceptionsFile"
    Write-Host "  Summary    : $summaryFile"
    if ($ExportHtmlReport) { Write-Host "  HTML       : $htmlFile" }
    Write-Host ''
    Write-Host 'Reminder: generated reports may contain customer data. Do not commit them to source control.' -ForegroundColor DarkGray
    Write-Host ''

    exit 0
}
catch {
    Write-AuditFailure ('Unexpected error: ' + $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }
    exit 1
}
