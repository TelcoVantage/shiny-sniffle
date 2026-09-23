<#
.SYNOPSIS
    Genesys Cloud API helper functions for the Genesys NPS Survey Auditor (optional connector).

.DESCRIPTION
    Function library used by Get-GenesysNpsSurveyData.ps1. Dot-source it to load the functions:

        . .\GenesysCloudApi.ps1

    Security:
        - Credentials are read from environment variables only (GENESYS_CLIENT_ID and
          GENESYS_CLIENT_SECRET). They are never prompted for, hard-coded, written to disk, or logged.
        - The OAuth access token is held in memory only for the duration of the run.

    Compatibility:
        - Windows PowerShell 5.1 and PowerShell 7+.
        - Constrained Language Mode safe: no .NET static method calls, no Add-Type, no ::new(),
          no [pscustomobject] casts. Base64 is implemented in pure PowerShell.
        - ASCII-only file.

.NOTES
    Independent community project. Not an official Genesys product, integration, or endorsement.
#>

# ---------------------------------------------------------------------------------------------
# Regions
# ---------------------------------------------------------------------------------------------

function Get-GcRegionDomain {
    <#
    .SYNOPSIS
        Resolves a region name, AWS region code, or domain to a Genesys Cloud domain.
    .EXAMPLE
        Get-GcRegionDomain -Region 'Australia'        # mypurecloud.com.au
        Get-GcRegionDomain -Region 'ap-southeast-2'   # mypurecloud.com.au
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Region)

    $map = @{
        'australia'      = 'mypurecloud.com.au'
        'sydney'         = 'mypurecloud.com.au'
        'ap-southeast-2' = 'mypurecloud.com.au'
        'us-east-1'      = 'mypurecloud.com'
        'us-east-2'      = 'use2.us-gov-pure.cloud'
        'us-west-2'      = 'usw2.pure.cloud'
        'ca-central-1'   = 'cac1.pure.cloud'
        'eu-west-1'      = 'mypurecloud.ie'
        'eu-west-2'      = 'euw2.pure.cloud'
        'eu-central-1'   = 'mypurecloud.de'
        'eu-central-2'   = 'euc2.pure.cloud'
        'ap-northeast-1' = 'mypurecloud.jp'
        'ap-northeast-2' = 'apne2.pure.cloud'
        'ap-northeast-3' = 'apne3.pure.cloud'
        'ap-south-1'     = 'aps1.pure.cloud'
        'sa-east-1'      = 'sae1.pure.cloud'
        'me-central-1'   = 'mec1.pure.cloud'
    }

    $key = $Region.Trim().ToLower()
    if ($map.ContainsKey($key)) { return $map[$key] }

    # Accept a bare domain such as "mypurecloud.com.au", or a full host such as
    # "api.mypurecloud.com.au" / "login.mypurecloud.com.au".
    $key = $key -replace '^https?://', ''
    $key = $key -replace '/.*$', ''
    $key = $key -replace '^(api|login|apps)\.', ''
    if ($key -match '^(mypurecloud\.(com|com\.au|ie|de|jp)|[a-z0-9]+\.(pure\.cloud|us-gov-pure\.cloud))$') { return $key }

    throw "Unrecognised Genesys Cloud region '$Region'. Use a domain such as 'mypurecloud.com.au' or a region code such as 'ap-southeast-2'."
}

# ---------------------------------------------------------------------------------------------
# Credentials and Base64 (pure PowerShell, CLM-safe)
# ---------------------------------------------------------------------------------------------

function ConvertTo-GcBase64 {
    <#
    .SYNOPSIS
        UTF-8 + Base64 encodes a string without [Convert] or [Text.Encoding] (CLM-safe).
    .EXAMPLE
        ConvertTo-GcBase64 -Text 'Aladdin:open sesame'   # QWxhZGRpbjpvcGVuIHNlc2FtZQ==
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text -or $Text -eq '') { return '' }

    # 1. String -> UTF-8 byte values.
    $bytes = @()
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 0x80) {
            $bytes += $code
        }
        elseif ($code -lt 0x800) {
            $bytes += (0xC0 -bor ($code -shr 6))
            $bytes += (0x80 -bor ($code -band 0x3F))
        }
        else {
            $bytes += (0xE0 -bor ($code -shr 12))
            $bytes += (0x80 -bor (($code -shr 6) -band 0x3F))
            $bytes += (0x80 -bor ($code -band 0x3F))
        }
    }

    # 2. Bytes -> Base64, three bytes at a time.
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    $out = ''
    for ($i = 0; $i -lt $bytes.Count; $i += 3) {
        $remaining = $bytes.Count - $i
        $b0 = $bytes[$i]
        $b1 = 0; if ($remaining -gt 1) { $b1 = $bytes[$i + 1] }
        $b2 = 0; if ($remaining -gt 2) { $b2 = $bytes[$i + 2] }
        $triple = ($b0 -shl 16) -bor ($b1 -shl 8) -bor $b2

        $out += $alphabet[($triple -shr 18) -band 0x3F]
        $out += $alphabet[($triple -shr 12) -band 0x3F]
        if ($remaining -gt 1) { $out += $alphabet[($triple -shr 6) -band 0x3F] } else { $out += '=' }
        if ($remaining -gt 2) { $out += $alphabet[$triple -band 0x3F] } else { $out += '=' }
    }
    return $out
}

function Get-GcCredentialFromEnvironment {
    <#
    .SYNOPSIS
        Reads the OAuth client credentials from environment variables.
    .DESCRIPTION
        GENESYS_CLIENT_ID and GENESYS_CLIENT_SECRET must be set (for example as user environment
        variables, by a deployment tool, or by a secret manager that injects them into the process).
        Never prompts. Throws a clear error if either is missing. Values are never written out.
    #>
    [CmdletBinding()]
    param(
        [string]$ClientIdVariable = 'GENESYS_CLIENT_ID',
        [string]$ClientSecretVariable = 'GENESYS_CLIENT_SECRET'
    )

    $id = [string](Get-Item -Path ('Env:' + $ClientIdVariable) -ErrorAction SilentlyContinue).Value
    $secret = [string](Get-Item -Path ('Env:' + $ClientSecretVariable) -ErrorAction SilentlyContinue).Value

    $missing = @()
    if ($id.Trim() -eq '') { $missing += $ClientIdVariable }
    if ($secret.Trim() -eq '') { $missing += $ClientSecretVariable }
    if ($missing.Count -gt 0) {
        throw ('Missing environment variable(s): ' + ($missing -join ', ') +
            '. Set them once outside this script (see docs/genesys-api-connector.md). Credentials are never prompted for or stored in code.')
    }

    return @{ ClientId = $id.Trim(); ClientSecret = $secret.Trim() }
}

function Get-GcMaskedValue {
    # Shows only the last four characters, e.g. "****ab12". Safe for console output.
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value -or $Value.Length -le 4) { return '****' }
    return '****' + $Value.Substring($Value.Length - 4)
}

# ---------------------------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------------------------

function Get-GcHttpStatusCode {
    <#
    .SYNOPSIS
        Extracts the HTTP status code from an error record. Returns 0 if unknown.
    #>
    param($ErrorRecord)

    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { $status = 0 }
    if ($status -eq 0) {
        $message = [string]$ErrorRecord.Exception.Message
        if ($message -match '\b(400|401|403|404|408|429|500|502|503|504)\b') { $status = [int]$Matches[1] }
    }
    return $status
}

function Invoke-GcRequest {
    <#
    .SYNOPSIS
        Invoke-RestMethod wrapper with retry on 429 (rate limit) and transient 5xx errors,
        and clear messages for authentication and permission failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{},
        [string]$Body,
        [string]$ContentType = 'application/json',
        [int]$MaxRetries = 5
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $params = @{
                Method          = $Method
                Uri             = $Uri
                Headers         = $Headers
                ContentType     = $ContentType
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            if (($PSBoundParameters.Keys -contains 'Body')) { $params.Body = $Body }
            return (Invoke-RestMethod @params)
        }
        catch {
            # Capture now: inside the switch below, $_ refers to the switch value, not the error.
            $err = $_
            $status = Get-GcHttpStatusCode -ErrorRecord $err
            # Retry rate limits and transient server errors; retry network failures (status 0) briefly.
            $retryable = ($status -eq 429 -or $status -eq 408 -or $status -ge 500 -or ($status -eq 0 -and $attempt -le 2))
            if ($retryable -and $attempt -le $MaxRetries) {
                $delay = [int](2 * $attempt * $attempt)
                Write-Verbose "HTTP $status on attempt $attempt; retrying in $delay second(s)."
                Start-Sleep -Seconds $delay
                continue
            }
            switch ($status) {
                400 { throw "Bad request (HTTP 400) to $Uri. Check the query parameters." }
                401 { throw 'Authentication failed (HTTP 401). Check GENESYS_CLIENT_ID / GENESYS_CLIENT_SECRET and the region.' }
                403 { throw "Permission denied (HTTP 403) for $Uri. The OAuth client's role needs Analytics > Conversation Detail > View." }
                404 { throw "Not found (HTTP 404): $Uri. Check the region." }
                default {
                    if ($status -eq 0) { throw ('Request to ' + $Uri + ' failed: ' + $err.Exception.Message) }
                    throw "Request to $Uri failed with HTTP $status after $attempt attempt(s)."
                }
            }
        }
    }
}

function Get-GcAccessToken {
    <#
    .SYNOPSIS
        Obtains an OAuth access token using the client credentials grant.
    .OUTPUTS
        The access token string. Throws if the response does not contain one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LoginBaseUri,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret
    )

    $basic = ConvertTo-GcBase64 -Text ($ClientId + ':' + $ClientSecret)
    try {
        $response = Invoke-GcRequest -Method 'Post' -Uri ($LoginBaseUri.TrimEnd('/') + '/oauth/token') `
            -Headers @{ Authorization = ('Basic ' + $basic) } `
            -ContentType 'application/x-www-form-urlencoded' -Body 'grant_type=client_credentials' -MaxRetries 2
    }
    catch {
        throw ('OAuth token request failed: ' + $_.Exception.Message +
            ' Check GENESYS_CLIENT_ID / GENESYS_CLIENT_SECRET, that the OAuth client uses the Client Credentials grant, and that the region is correct.')
    }
    finally {
        $basic = $null
    }

    # Validate explicitly rather than assuming success.
    if ($null -eq $response -or $null -eq $response.access_token -or ([string]$response.access_token).Trim() -eq '') {
        throw 'The OAuth response did not contain an access_token. Check the OAuth client uses the Client Credentials grant.'
    }
    return [string]$response.access_token
}

# ---------------------------------------------------------------------------------------------
# Date range
# ---------------------------------------------------------------------------------------------

function Get-GcDailyIntervals {
    <#
    .SYNOPSIS
        Splits "the last N days up to now" into one-day ISO-8601 UTC intervals.
    .DESCRIPTION
        Smaller intervals keep each analytics query and its paging manageable.
    .OUTPUTS
        Array of strings like "2026-09-16T10:00:00.000Z/2026-09-17T10:00:00.000Z".
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 31)][int]$Days = 7,
        [AllowNull()]$EndUtc
    )

    if ($null -eq $EndUtc) { $EndUtc = (Get-Date).ToUniversalTime() }
    # Round down to the minute so repeated runs produce stable, readable boundaries.
    $EndUtc = $EndUtc.AddSeconds(-1 * $EndUtc.Second).AddMilliseconds(-1 * $EndUtc.Millisecond)
    $format = "yyyy-MM-dd'T'HH':'mm':'ss'.000Z'"

    $intervals = @()
    for ($d = $Days; $d -ge 1; $d--) {
        $from = $EndUtc.AddDays(-1 * $d)
        $to = $EndUtc.AddDays(-1 * ($d - 1))
        $intervals += ((Get-Date -Date $from -Format $format) + '/' + (Get-Date -Date $to -Format $format))
    }
    return $intervals
}

# ---------------------------------------------------------------------------------------------
# Conversation details
# ---------------------------------------------------------------------------------------------

function Get-GcConversationDetails {
    <#
    .SYNOPSIS
        Returns all conversations in an interval from the analytics conversation details query,
        following pagination.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ApiBaseUri,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$Interval,
        [string[]]$QueueIds = @(),
        [ValidateRange(1, 100)][int]$PageSize = 100,
        [ValidateRange(1, 10000)][int]$MaxPages = 500
    )

    $uri = $ApiBaseUri.TrimEnd('/') + '/api/v2/analytics/conversations/details/query'
    $headers = @{ Authorization = ('Bearer ' + $AccessToken) }
    $all = @()
    $page = 1

    while ($page -le $MaxPages) {
        $query = @{
            interval = $Interval
            order    = 'asc'
            orderBy  = 'conversationStart'
            paging   = @{ pageSize = $PageSize; pageNumber = $page }
        }
        $validQueues = @($QueueIds | Where-Object { $_ -and ([string]$_).Trim() -ne '' })
        if ($validQueues.Count -gt 0) {
            $predicates = @()
            foreach ($q in $validQueues) {
                $predicates += @{ type = 'dimension'; dimension = 'queueId'; operator = 'matches'; value = ([string]$q).Trim() }
            }
            $query.segmentFilters = @(@{ type = 'or'; predicates = $predicates })
        }

        $body = ConvertTo-Json -InputObject $query -Depth 10
        $response = Invoke-GcRequest -Method 'Post' -Uri $uri -Headers $headers -Body $body
        if ($null -eq $response) { throw "Empty response from the conversation details query for $Interval." }

        $batch = @()
        if ($null -ne $response.conversations) { $batch = @($response.conversations) }
        $all += $batch

        if ($batch.Count -lt $PageSize) { break }
        if ($null -ne $response.totalHits -and $all.Count -ge [int]$response.totalHits) { break }
        $page++
    }

    if ($page -gt $MaxPages) {
        Write-Warning "Stopped after $MaxPages pages for $Interval. Narrow the query with -QueueId, or raise MaxPages."
    }
    return $all
}

function ConvertTo-GcIsoTimestamp {
    <#
    .SYNOPSIS
        Returns an ISO-8601 UTC timestamp string. PowerShell 7 converts ISO date strings in JSON
        responses into DateTime objects; Windows PowerShell 5.1 leaves them as strings.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) {
        return (Get-Date -Date $Value.ToUniversalTime() -Format "yyyy-MM-dd'T'HH':'mm':'ss'.'fff'Z'")
    }
    return ([string]$Value).Trim()
}

function Get-GcDefaultAttributeMap {
    <#
    .SYNOPSIS
        Default participant-data attribute names written by the survey flow.
        Override them in config/genesys-connector.json to match your Architect flow.
    #>
    return @{
        SurveyId   = 'Survey.Id'
        Question   = 'Survey.Question'
        Utterance  = 'Survey.Utterance'
        Score      = 'Survey.Score'
        Confidence = 'Survey.Confidence'
        Status     = 'Survey.Status'
    }
}

function ConvertFrom-GcConversation {
    <#
    .SYNOPSIS
        Maps one analytics conversation to a row in the auditor's CSV schema.
    .DESCRIPTION
        Survey answers are read from participant data attributes (set by the survey flow).
        Conversations with none of the mapped attributes are not surveys and return $null.
        When several participants carry the same attribute, the last non-empty value wins
        (the survey runs at the end of the interaction).
    .OUTPUTS
        PSObject with surveyId, conversationId, completedAt, channel, question, utterance,
        recordedScore, confidence, participantStatus - or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Conversation,
        [Parameter(Mandatory = $true)][hashtable]$AttributeMap,
        [string]$DefaultQuestion = 'How likely are you to recommend us from zero to ten?'
    )

    $values = @{}
    foreach ($field in @('SurveyId', 'Question', 'Utterance', 'Score', 'Confidence', 'Status')) { $values[$field] = '' }
    $found = $false
    $mediaType = ''

    foreach ($p in @($Conversation.participants)) {
        if ($null -eq $p) { continue }
        if ($mediaType -eq '' -and ($p.purpose -eq 'customer' -or $p.purpose -eq 'external')) {
            foreach ($s in @($p.sessions)) {
                if ($null -ne $s -and $s.mediaType) { $mediaType = [string]$s.mediaType; break }
            }
        }
        if ($null -eq $p.attributes) { continue }
        foreach ($field in @($AttributeMap.Keys)) {
            $name = [string]$AttributeMap[$field]
            if ($name -eq '') { continue }
            $v = $p.attributes.$name
            if ($null -ne $v -and ([string]$v).Trim() -ne '') {
                $values[$field] = ([string]$v).Trim()
                $found = $true
            }
        }
    }

    if (-not $found) { return $null }

    if ($mediaType -eq '') {
        foreach ($p in @($Conversation.participants)) {
            foreach ($s in @($p.sessions)) {
                if ($null -ne $s -and $s.mediaType) { $mediaType = [string]$s.mediaType; break }
            }
            if ($mediaType -ne '') { break }
        }
    }
    $channel = 'Digital'
    if ($mediaType -eq 'voice' -or $mediaType -eq 'callback') { $channel = 'Voice' }
    if ($mediaType -eq '') { $channel = 'Unknown' }

    # Status: use the flow's own status attribute when present; otherwise infer.
    $status = $values.Status
    if ($status -eq '') {
        if ($values.Utterance -ne '' -or $values.Score -ne '') { $status = 'Completed' }
        else { $status = 'Disconnected' }
    }

    $surveyId = $values.SurveyId
    if ($surveyId -eq '') { $surveyId = [string]$Conversation.conversationId }
    $question = $values.Question
    if ($question -eq '') { $question = $DefaultQuestion }
    $completedAt = ConvertTo-GcIsoTimestamp -Value $Conversation.conversationEnd
    if ($completedAt -eq '') { $completedAt = ConvertTo-GcIsoTimestamp -Value $Conversation.conversationStart }

    $row = New-Object PSObject -Property @{
        surveyId          = $surveyId
        conversationId    = [string]$Conversation.conversationId
        completedAt       = $completedAt
        channel           = $channel
        question          = $question
        utterance         = $values.Utterance
        recordedScore     = $values.Score
        confidence        = $values.Confidence
        participantStatus = $status
    }
    return ($row | Select-Object surveyId, conversationId, completedAt, channel, question, utterance,
        recordedScore, confidence, participantStatus)
}
