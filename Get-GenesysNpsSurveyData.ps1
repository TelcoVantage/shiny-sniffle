<#
.SYNOPSIS
    Downloads the last 7 days of NPS survey responses from Genesys Cloud (Australia region by
    default) and optionally runs the audit on them.

.DESCRIPTION
    Optional API connector for the Genesys NPS Survey Auditor.

      1. Reads OAuth client credentials from environment variables GENESYS_CLIENT_ID and
         GENESYS_CLIENT_SECRET. Nothing is prompted for, and no credential is stored in code,
         config files, output files, or console output.
      2. Gets an access token (client credentials grant) from login.<region>.
      3. Queries analytics conversation details for the last N days (default 7), one day at a time.
      4. Detects surveys automatically - no conversation IDs or attribute names are needed:
           - flow-based voice/bot surveys, by discovering survey keys in participant data
             (anything matching survey|nps|csat|post-call|feedback), and
           - Genesys Cloud native web surveys with status Finished.
         Works out whether each survey was completed, incomplete, or declined, and writes the
         surveys to a git-ignored CSV in the auditor's input schema.
      5. With -RunAudit, runs Export-GenesysNpsAudit.ps1 on that CSV.

    Region precedence : -Region  >  $env:GENESYS_REGION  >  config file  >  mypurecloud.com.au (Australia)
    Days precedence   : -Days    >  config file  >  7

    Compatible with Windows PowerShell 5.1 and PowerShell 7+, including Constrained Language Mode.

    Exit codes:
        0  Success
        1  Unexpected error
        2  Configuration error (missing environment variables, invalid config or region)
        3  Genesys Cloud authentication or API error
        Any other non-zero code is passed through from the audit when -RunAudit is used.

.PARAMETER Region
    Genesys Cloud region domain or code. Default: mypurecloud.com.au (Australia / ap-southeast-2).

.PARAMETER Days
    Number of days to look back from now. Default 7.

.PARAMETER QueueId
    Optional queue ID(s) to restrict the query.

.PARAMETER OutputPath
    Folder for the downloaded CSV and audit reports. Default: .\output (git-ignored).

.PARAMETER ConfigPath
    Optional non-secret JSON config. Default: .\config\genesys-connector.json (git-ignored).
    See config\genesys-connector.example.json.

.PARAMETER CompletedOnly
    Export only completed surveys. By default, incomplete surveys (timeout, disconnect,
    abandoned) are included because they are audit findings. Declined surveys are always excluded.

.PARAMETER RunAudit
    Run Export-GenesysNpsAudit.ps1 on the downloaded data.

.PARAMETER ExportHtmlReport
    Passed through to the audit when -RunAudit is used.

.PARAMETER ConfidenceThreshold
    Passed through to the audit when -RunAudit is used. Default 0.70.

.EXAMPLE
    .\Get-GenesysNpsSurveyData.ps1 -RunAudit -ExportHtmlReport
    # Last 7 days, Australia region, credentials from environment variables.

.NOTES
    Independent community project. Not an official Genesys product, integration, or endorsement.
    Downloaded data is real customer data: keep it in git-ignored folders and delete it when done.
#>
[CmdletBinding()]
param(
    [string]$Region,
    [ValidateRange(1, 31)][int]$Days = 7,
    [string[]]$QueueId = @(),
    [string]$OutputPath,
    [string]$ConfigPath,
    [switch]$CompletedOnly,
    [switch]$RunAudit,
    [switch]$ExportHtmlReport,
    [ValidateRange(0.0, 1.0)][double]$ConfidenceThreshold = 0.70
)

$ErrorActionPreference = 'Stop'

$SchemaColumns = @('surveyId', 'conversationId', 'completedAt', 'channel', 'question',
                   'utterance', 'recordedScore', 'confidence', 'participantStatus')

function Write-ConnectorFailure {
    param([string]$Message)
    Write-Host ''
    Write-Host ('ERROR: ' + $Message) -ForegroundColor Red
}

try {
    $scriptRoot = $PSScriptRoot
    if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
    . (Join-Path $scriptRoot 'GenesysCloudApi.ps1')

    if (-not $OutputPath) { $OutputPath = Join-Path $scriptRoot 'output' }
    if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $scriptRoot 'config') 'genesys-connector.json' }

    Write-Host ''
    Write-Host '=== Genesys NPS Survey Auditor - Genesys Cloud connector ===' -ForegroundColor Cyan
    Write-Host 'Independent community tool. Downloaded data is real customer data; keep it out of source control.' -ForegroundColor DarkGray
    Write-Host ''

    # ---- Optional non-secret configuration ----------------------------------------------
    $config = $null
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $rawConfig = Get-Content -LiteralPath $ConfigPath -Raw
        # The config file is for non-secret settings only. Refuse to run if it holds secrets.
        if ($rawConfig -match '(?i)"\s*(client_?id|client_?secret|secret|password|access_?token|token)\s*"\s*:') {
            Write-ConnectorFailure ("Config file '" + (Split-Path -Leaf $ConfigPath) + "' appears to contain a credential. " +
                'Remove it: credentials must come from the GENESYS_CLIENT_ID / GENESYS_CLIENT_SECRET environment variables only.')
            exit 2
        }
        try { $config = $rawConfig | ConvertFrom-Json }
        catch {
            Write-ConnectorFailure ("Config file is not valid JSON: " + $_.Exception.Message)
            exit 2
        }
        Write-Host ('Config file          : ' + (Split-Path -Leaf $ConfigPath))
    }

    # ---- Region -------------------------------------------------------------------------
    $regionInput = 'mypurecloud.com.au'
    $regionSource = 'default (Australia)'
    if ($null -ne $config -and $config.region) { $regionInput = [string]$config.region; $regionSource = 'config file' }
    if ($env:GENESYS_REGION) { $regionInput = [string]$env:GENESYS_REGION; $regionSource = 'GENESYS_REGION' }
    if (($PSBoundParameters.Keys -contains 'Region')) { $regionInput = $Region; $regionSource = '-Region' }
    try { $domain = Get-GcRegionDomain -Region $regionInput }
    catch { Write-ConnectorFailure $_.Exception.Message; exit 2 }
    $loginBase = 'https://login.' + $domain
    $apiBase = 'https://api.' + $domain

    # ---- Days, queues, attribute mapping -----------------------------------------------
    if (-not ($PSBoundParameters.Keys -contains 'Days') -and $null -ne $config -and $config.days) {
        $Days = [int]$config.days
        if ($Days -lt 1 -or $Days -gt 31) { Write-ConnectorFailure 'Config "days" must be between 1 and 31.'; exit 2 }
    }
    $queues = @($QueueId)
    if ($queues.Count -eq 0 -and $null -ne $config -and $null -ne $config.queueIds) { $queues = @($config.queueIds) }

    # Survey keys are discovered automatically. The config file can optionally pin exact key
    # names ("attributes") or change the discovery pattern ("surveyKeyPattern").
    $attributeMap = @{}
    if ($null -ne $config -and $null -ne $config.attributes) {
        foreach ($role in @('SurveyId', 'Question', 'Utterance', 'Score', 'Confidence', 'Status')) {
            $override = $config.attributes.$role
            if ($null -ne $override -and ([string]$override).Trim() -ne '') { $attributeMap[$role] = ([string]$override).Trim() }
        }
    }
    $surveyKeyPattern = Get-GcDefaultSurveyKeyPattern
    if ($null -ne $config -and $config.surveyKeyPattern) {
        $surveyKeyPattern = [string]$config.surveyKeyPattern
        try { 'test' -match $surveyKeyPattern | Out-Null }
        catch { Write-ConnectorFailure 'Config "surveyKeyPattern" is not a valid regular expression.'; exit 2 }
    }
    $defaultQuestion = 'How likely are you to recommend us from zero to ten?'
    if ($null -ne $config -and $config.defaultQuestion) { $defaultQuestion = [string]$config.defaultQuestion }

    # ---- Credentials (environment only) -------------------------------------------------
    try { $credential = Get-GcCredentialFromEnvironment }
    catch { Write-ConnectorFailure $_.Exception.Message; exit 2 }

    $intervals = @(Get-GcDailyIntervals -Days $Days)
    $firstStart = ($intervals[0] -split '/')[0]
    $lastEnd = ($intervals[$intervals.Count - 1] -split '/')[1]

    Write-Host ("Region               : $domain  (from $regionSource)")
    Write-Host ("OAuth client         : " + (Get-GcMaskedValue $credential.ClientId) + '  (from GENESYS_CLIENT_ID)')
    Write-Host ("Date range (UTC)     : $firstStart  ->  $lastEnd  ($Days day(s))")
    if ($queues.Count -gt 0) { Write-Host ('Queue filter         : ' + $queues.Count + ' queue(s)') }
    $pinned = ''
    if ($attributeMap.Count -gt 0) { $pinned = ' + ' + $attributeMap.Count + ' pinned key(s) from config' }
    Write-Host ("Survey detection     : automatic (participant keys matching '" + $surveyKeyPattern + "'" + $pinned + '; native web surveys)')
    if ($CompletedOnly) { Write-Host 'Filter               : completed surveys only' }
    Write-Host ''

    # ---- Authenticate --------------------------------------------------------------------
    try {
        $token = Get-GcAccessToken -LoginBaseUri $loginBase -ClientId $credential.ClientId -ClientSecret $credential.ClientSecret
    }
    catch { Write-ConnectorFailure $_.Exception.Message; exit 3 }
    finally { $credential = $null }
    Write-Host 'Authenticated.' -ForegroundColor Green

    # ---- Query, one day at a time ------------------------------------------------------
    $detected = @()
    $conversationCount = 0
    try {
        foreach ($interval in $intervals) {
            $conversations = @(Get-GcConversationDetails -ApiBaseUri $apiBase -AccessToken $token -Interval $interval -QueueIds $queues)
            $daySurveys = @()
            foreach ($c in $conversations) {
                $row = ConvertFrom-GcConversation -Conversation $c -AttributeMap $attributeMap `
                    -SurveyKeyPattern $surveyKeyPattern -DefaultQuestion $defaultQuestion
                if ($null -ne $row) { $daySurveys += $row }
            }
            $conversationCount += $conversations.Count
            $detected += $daySurveys
            $dayCompleted = @($daySurveys | Where-Object { $_.DetectedState -eq 'Completed' }).Count
            Write-Host ('  {0}  conversations: {1,6}   surveys detected: {2,5}   completed: {3,5}' -f `
                ($interval -split 'T')[0], $conversations.Count, $daySurveys.Count, $dayCompleted)
        }
    }
    catch { Write-ConnectorFailure $_.Exception.Message; exit 3 }
    finally { $token = $null }

    # ---- Detection summary ---------------------------------------------------------------
    $completed = @($detected | Where-Object { $_.DetectedState -eq 'Completed' })
    $incomplete = @($detected | Where-Object { $_.DetectedState -eq 'Incomplete' })
    $declined = @($detected | Where-Object { $_.DetectedState -eq 'Declined' })
    $unknown = @($detected | Where-Object { $_.DetectedState -eq 'Unknown' })

    # Declined surveys are not responses; incomplete ones are kept unless -CompletedOnly.
    $rows = @($detected | Where-Object { $_.DetectedState -ne 'Declined' })
    if ($CompletedOnly) { $rows = @($completed) }

    Write-Host ''
    Write-Host 'Survey detection' -ForegroundColor Cyan
    Write-Host ("  Conversations scanned : $conversationCount")
    Write-Host ("  Surveys detected      : " + $detected.Count)
    Write-Host ("    Completed           : " + $completed.Count)
    Write-Host ("    Incomplete          : " + $incomplete.Count + '  (timeout / disconnect / abandoned)')
    Write-Host ("    Declined (excluded) : " + $declined.Count)
    if ($unknown.Count -gt 0) { Write-Host ("    Unknown status      : " + $unknown.Count + '  (flagged for review in the audit)') }

    # Which participant-data keys were recognised, so the detection can be verified at a glance.
    $keyUsage = @($detected | Where-Object { $_.DetectedKeys -ne '' } | ForEach-Object { ($_.DetectedKeys -split '; ') } |
        Group-Object | Sort-Object -Property Count -Descending)
    if ($keyUsage.Count -gt 0) {
        Write-Host '  Keys recognised:'
        foreach ($k in ($keyUsage | Select-Object -First 12)) {
            Write-Host ('    {0,-45} {1,6} conversation(s)' -f $k.Name, $k.Count)
        }
    }
    $native = @($detected | Where-Object { $_.DetectedSource -eq 'Native web survey' }).Count
    if ($native -gt 0) { Write-Host ("  Native web surveys    : $native") }

    # ---- Write the CSV -------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $resolvedOutput = (Resolve-Path -LiteralPath $OutputPath).Path
    $exportFile = Join-Path $resolvedOutput ('genesys-survey-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')

    if ($rows.Count -gt 0) {
        $rows | Select-Object -Property $SchemaColumns | Export-Csv -LiteralPath $exportFile -NoTypeInformation -Encoding UTF8
    }
    else {
        Set-Content -LiteralPath $exportFile -Value ($SchemaColumns -join ',') -Encoding UTF8
    }

    Write-Host ''
    Write-Host ("Surveys exported     : " + $rows.Count)
    Write-Host ("Export written       : $exportFile")
    if ($detected.Count -eq 0) {
        Write-Host ('No surveys detected. If surveys ran in this period, their participant-data keys may not contain ' +
            'survey/nps/csat/post-call/feedback: set "surveyKeyPattern" or pin "attributes" in config\genesys-connector.json.') -ForegroundColor Yellow
    }

    # ---- Optional audit ------------------------------------------------------------------
    if ($RunAudit) {
        $auditParams = @{
            InputPath           = $exportFile
            OutputPath          = $resolvedOutput
            ConfidenceThreshold = $ConfidenceThreshold
        }
        if ($ExportHtmlReport) { $auditParams.ExportHtmlReport = $true }
        & (Join-Path $scriptRoot 'Export-GenesysNpsAudit.ps1') @auditParams
        exit $LASTEXITCODE
    }

    Write-Host ''
    Write-Host 'Run the audit with:' -ForegroundColor Cyan
    Write-Host ('  .\Export-GenesysNpsAudit.ps1 -InputPath "' + $exportFile + '" -ExportHtmlReport')
    Write-Host ''
    exit 0
}
catch {
    Write-ConnectorFailure ('Unexpected error: ' + $_.Exception.Message)
    exit 1
}
