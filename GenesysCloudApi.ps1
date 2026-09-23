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

# ---------------------------------------------------------------------------------------------
# Automatic survey detection
# ---------------------------------------------------------------------------------------------

function Get-GcDefaultSurveyKeyPattern {
    # Participant-data keys matching this pattern are treated as survey data.
    # Override with "surveyKeyPattern" in config/genesys-connector.json.
    return '(?i)survey|nps|csat|post[._\s-]?call|feedback'
}

function Get-GcMergedAttributes {
    <#
    .SYNOPSIS
        Merges participant data from every participant of a conversation into one hashtable.
        The last non-empty value for a key wins (surveys run at the end of the interaction).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Conversation)

    $merged = @{}
    foreach ($p in @($Conversation.participants)) {
        if ($null -eq $p -or $null -eq $p.attributes) { continue }
        foreach ($prop in @($p.attributes.PSObject.Properties)) {
            $name = [string]$prop.Name
            $value = ''
            if ($null -ne $prop.Value) { $value = ([string]$prop.Value).Trim() }
            if ($value -ne '') { $merged[$name] = $value }
            elseif (-not $merged.ContainsKey($name)) { $merged[$name] = '' }
        }
    }
    return $merged
}

function Get-GcSurveyKeyRole {
    <#
    .SYNOPSIS
        Guesses what a survey participant-data key holds from its name (and value when needed).
    .OUTPUTS
        One of: Confidence, SurveyId, Question, Utterance, Status, OptIn, Score - or '' (not used).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Value = ''
    )

    $k = $Key.ToLower()
    # Counters, timestamps and flow bookkeeping are never survey answers.
    if ($k -match 'count|attempt|retr(y|ies)|timestamp|date|time$|duration|flow|version|language|lang$|url|link') { return '' }
    if ($k -match 'confidence|conf$') { return 'Confidence' }
    if ($k -match '(survey|response|nps)[._\s-]*id$') { return 'SurveyId' }
    if ($k -match 'question|prompt') { if ($k -match 'id$') { return '' }; return 'Question' }
    if ($k -match 'utterance|transcri|verbatim|speech|spoken|said|response[._\s-]?text|answer[._\s-]?text') { return 'Utterance' }
    if ($k -match 'opt[._\s-]?in|opt[._\s-]?out|consent|accept|offered|agreed') { return 'OptIn' }
    if ($k -match 'result|outcome' -and $Value -match '^\s*\d{1,3}\s*$') { return 'Score' }
    if ($k -match 'status|state$|result|outcome|disposition|completed?$|finished') { return 'Status' }
    if ($k -match 'answer|response$') {
        # A free-text answer is an utterance; a bare number is a captured score.
        if ($Value -match '[a-z]{2,}' -and $Value -notmatch '^\s*\d{1,2}\s*$') { return 'Utterance' }
        return 'Score'
    }
    if ($k -match 'score|rating|nps$|nps[._\s-]?value|value$') { return 'Score' }
    return ''
}

function Find-GcSurveyAttributeMap {
    <#
    .SYNOPSIS
        Works out which participant-data keys hold the survey utterance, score, confidence, etc.
    .DESCRIPTION
        1. Keys named in -ExplicitMap (from the optional config file) are used first.
        2. Every other key matching -SurveyKeyPattern is classified by Get-GcSurveyKeyRole.
        The first key found for each role wins (keys are processed in sorted order, so the
        result is deterministic). No attribute names need to be configured.
    .OUTPUTS
        Hashtable of role -> key name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Attributes,
        [hashtable]$ExplicitMap = @{},
        [string]$SurveyKeyPattern = (Get-GcDefaultSurveyKeyPattern)
    )

    $map = @{}
    foreach ($role in @($ExplicitMap.Keys)) {
        $name = [string]$ExplicitMap[$role]
        if ($name -ne '' -and $Attributes.ContainsKey($name)) { $map[$role] = $name }
    }

    foreach ($key in @($Attributes.Keys | Sort-Object)) {
        if ($map.Values -contains $key) { continue }
        if ($key -notmatch $SurveyKeyPattern) { continue }
        $role = Get-GcSurveyKeyRole -Key $key -Value ([string]$Attributes[$key])
        if ($role -eq '') { continue }
        if ($map.ContainsKey($role)) {
            # Prefer a key that actually has a value.
            if ([string]$Attributes[$map[$role]] -eq '' -and [string]$Attributes[$key] -ne '') { $map[$role] = $key }
            continue
        }
        $map[$role] = $key
    }
    return $map
}

function ConvertTo-GcSurveyState {
    <#
    .SYNOPSIS
        Normalises a survey status value and decides whether the survey was completed.
    .OUTPUTS
        @{ Status = <value for participantStatus>; State = Completed | Incomplete | Declined | Unknown }
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$RawStatus = '',
        [AllowEmptyString()][string]$OptIn = '',
        [bool]$HasAnswer = $false
    )

    $s = $RawStatus.Trim().ToLower()
    $o = $OptIn.Trim().ToLower()

    if ($s -match 'declin|opt[._\s-]?out|refus|reject|skip' -or
        ($o -match '^(false|no|n|0|declined|optout|opt-out)$' -and -not $HasAnswer)) {
        return @{ Status = 'Declined'; State = 'Declined' }
    }
    if ($s -eq '') {
        if ($HasAnswer) { return @{ Status = 'Completed'; State = 'Completed' } }
        # Survey data exists but nothing was answered: the customer left before answering.
        return @{ Status = 'Disconnected'; State = 'Incomplete' }
    }
    if ($s -match 'no[._\s-]?input|no[._\s-]?match|no[._\s-]?answer') {
        # The survey ran to the end but nothing usable was captured - audited as No input / ambiguous.
        return @{ Status = 'Completed'; State = 'Completed' }
    }
    if ($s -match 'time[._\s-]?d?[._\s-]?out') { return @{ Status = 'Timeout'; State = 'Incomplete' } }
    if ($s -match 'disconnect|hang|hung|drop') { return @{ Status = 'Disconnected'; State = 'Incomplete' } }
    if ($s -match 'abandon|expire|incomplete|partial|cancel') { return @{ Status = 'Abandoned'; State = 'Incomplete' } }
    if ($s -match 'complet|finish|success|done|answered|submitted|captured') { return @{ Status = 'Completed'; State = 'Completed' } }
    # Unknown values pass through unchanged; the audit flags them as Review required.
    return @{ Status = $RawStatus.Trim(); State = 'Unknown' }
}

function Get-GcConversationChannel {
    # Voice for voice/callback media, Digital for everything else, Unknown if no media found.
    param([Parameter(Mandatory = $true)]$Conversation)

    $mediaType = ''
    foreach ($purposeFirst in @($true, $false)) {
        foreach ($p in @($Conversation.participants)) {
            if ($null -eq $p) { continue }
            if ($purposeFirst -and -not ($p.purpose -eq 'customer' -or $p.purpose -eq 'external')) { continue }
            foreach ($sess in @($p.sessions)) {
                if ($null -ne $sess -and $sess.mediaType) { $mediaType = [string]$sess.mediaType; break }
            }
            if ($mediaType -ne '') { break }
        }
        if ($mediaType -ne '') { break }
    }
    if ($mediaType -eq '') { return 'Unknown' }
    if ($mediaType -eq 'voice' -or $mediaType -eq 'callback') { return 'Voice' }
    return 'Digital'
}

function New-GcSurveyRow {
    # Builds a row in the auditor schema plus internal detection fields (prefixed with "Detected").
    param($SurveyId, $ConversationId, $CompletedAt, $Channel, $Question, $Utterance, $Score,
          $Confidence, $Status, $State, $Source, $Keys)
    $row = New-Object PSObject -Property @{
        surveyId          = [string]$SurveyId
        conversationId    = [string]$ConversationId
        completedAt       = [string]$CompletedAt
        channel           = [string]$Channel
        question          = [string]$Question
        utterance         = [string]$Utterance
        recordedScore     = [string]$Score
        confidence        = [string]$Confidence
        participantStatus = [string]$Status
        DetectedState     = [string]$State
        DetectedSource    = [string]$Source
        DetectedKeys      = [string]$Keys
    }
    return ($row | Select-Object surveyId, conversationId, completedAt, channel, question, utterance,
        recordedScore, confidence, participantStatus, DetectedState, DetectedSource, DetectedKeys)
}

function ConvertFrom-GcConversation {
    <#
    .SYNOPSIS
        Detects whether a conversation contains an NPS survey and maps it to the auditor schema.

    .DESCRIPTION
        No conversation IDs or attribute names need to be supplied. Two survey sources are detected:

        1. Voice / bot surveys run in an Architect flow, which store results in participant data.
           Survey keys are discovered automatically by name (see Find-GcSurveyAttributeMap).
        2. Genesys Cloud native web surveys, returned in the conversation's "surveys" array.
           Only surveys with status Finished and a promoter score are included.

        Conversations with no survey data return $null.

    .OUTPUTS
        PSObject with the nine auditor columns plus DetectedState (Completed / Incomplete /
        Declined / Unknown), DetectedSource, and DetectedKeys - or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Conversation,
        [hashtable]$AttributeMap = @{},
        [string]$SurveyKeyPattern = (Get-GcDefaultSurveyKeyPattern),
        [string]$DefaultQuestion = 'How likely are you to recommend us from zero to ten?'
    )

    $conversationId = [string]$Conversation.conversationId
    $completedAt = ConvertTo-GcIsoTimestamp -Value $Conversation.conversationEnd
    if ($completedAt -eq '') { $completedAt = ConvertTo-GcIsoTimestamp -Value $Conversation.conversationStart }
    $channel = Get-GcConversationChannel -Conversation $Conversation

    # ---- 1. Flow-based survey in participant data ---------------------------------------
    $attributes = Get-GcMergedAttributes -Conversation $Conversation
    $map = Find-GcSurveyAttributeMap -Attributes $attributes -ExplicitMap $AttributeMap -SurveyKeyPattern $SurveyKeyPattern

    $core = @($map.Keys | Where-Object { $_ -eq 'Utterance' -or $_ -eq 'Score' -or $_ -eq 'Status' -or $_ -eq 'OptIn' })
    if ($core.Count -gt 0) {
        $v = @{}
        foreach ($role in @('SurveyId', 'Question', 'Utterance', 'Score', 'Confidence', 'Status', 'OptIn')) {
            $v[$role] = ''
            if ($map.ContainsKey($role)) { $v[$role] = [string]$attributes[$map[$role]] }
        }
        $hasAnswer = ($v.Utterance -ne '' -or $v.Score -ne '')
        $state = ConvertTo-GcSurveyState -RawStatus $v.Status -OptIn $v.OptIn -HasAnswer $hasAnswer

        $surveyId = $v.SurveyId
        if ($surveyId -eq '') { $surveyId = $conversationId }
        $question = $v.Question
        if ($question -eq '') { $question = $DefaultQuestion }
        $keys = (@($map.Keys | Sort-Object | ForEach-Object { $_ + '=' + $map[$_] }) -join '; ')

        return (New-GcSurveyRow -SurveyId $surveyId -ConversationId $conversationId -CompletedAt $completedAt `
            -Channel $channel -Question $question -Utterance $v.Utterance -Score $v.Score -Confidence $v.Confidence `
            -Status $state.Status -State $state.State -Source 'Participant data' -Keys $keys)
    }

    # ---- 2. Native Genesys Cloud survey --------------------------------------------------
    foreach ($survey in @($Conversation.surveys)) {
        if ($null -eq $survey) { continue }
        $score = $survey.surveyPromoterScore
        if ([string]$survey.surveyStatus -notmatch '(?i)^finished$' -or $null -eq $score -or [string]$score -eq '') { continue }
        $surveyId = [string]$survey.surveyId
        if ($surveyId -eq '') { $surveyId = $conversationId }
        $when = ConvertTo-GcIsoTimestamp -Value $survey.surveyCompletedDate
        if ($when -eq '') { $when = $completedAt }
        $question = $DefaultQuestion
        if ($survey.surveyFormName) { $question = [string]$survey.surveyFormName + ' (NPS question)' }
        # The customer selected the score directly, so the selection is recorded as the answer.
        return (New-GcSurveyRow -SurveyId $surveyId -ConversationId $conversationId -CompletedAt $when `
            -Channel 'Web survey' -Question $question -Utterance ([string]$score) -Score ([string]$score) -Confidence '' `
            -Status 'Completed' -State 'Completed' -Source 'Native web survey' -Keys 'Score=surveyPromoterScore')
    }

    return $null
}
