<#
.SYNOPSIS
    Utterance analysis and audit classification functions for the Genesys NPS Survey Auditor.

.DESCRIPTION
    This file is a function library. Dot-source it to load the functions:

        . .\Invoke-NpsUtteranceAnalysis.ps1
        Invoke-NpsUtteranceAnalysis -Utterance "seven, actually make that eight" -RecordedScore 8 -Confidence 0.91

    Public functions:
        Invoke-NpsUtteranceAnalysis  - Audits one survey response and returns a classification object.
        Get-NpsExpectedScore         - Extracts the explicit 0-10 score (if any) from an utterance.
        Get-NpsCategory              - Maps a 0-10 score to Detractor / Passive / Promoter.
        Get-NpsAuditPriority         - Maps an audit status to High / Medium / None.
        Get-NpsScoreSummary          - Calculates promoter / passive / detractor counts and NPS.
        Format-NpsNumber             - Culture-independent number formatting.

    Compatibility:
        - Windows PowerShell 5.1 and PowerShell 7+.
        - Constrained Language Mode (AppLocker / WDAC) safe: no .NET static method calls,
          no Add-Type, no ::new(), no [pscustomobject] casts, no classes, no external modules.
        - This file is ASCII-only so it is read identically regardless of file encoding detection.

    All sample data used with this tool must be synthetic or sanitised.

.NOTES
    Project : Genesys NPS Survey Auditor (independent community project, not affiliated with Genesys)
    License : MIT
#>

# ---------------------------------------------------------------------------------------------
# Lexicon
# ---------------------------------------------------------------------------------------------

function Get-NpsNumberLexicon {
    <#
    .SYNOPSIS
        Returns the word lists used by the score tokeniser.
    .DESCRIPTION
        Kept in a function (rather than script-scoped variables) so the library behaves the same
        whether it is dot-sourced from a script, a test harness, or an interactive console.
    #>
    [CmdletBinding()]
    param()

    return @{
        # Written scores inside the NPS range.
        InRange          = @{
            'zero' = 0; 'nought' = 0; 'one' = 1; 'two' = 2; 'three' = 3; 'four' = 4; 'five' = 5
            'six' = 6; 'seven' = 7; 'eight' = 8; 'nine' = 9; 'ten' = 10
        }
        # Written numbers outside the NPS range (used to detect invalid rating attempts).
        Teens            = @{
            'eleven' = 11; 'twelve' = 12; 'thirteen' = 13; 'fourteen' = 14; 'fifteen' = 15
            'sixteen' = 16; 'seventeen' = 17; 'eighteen' = 18; 'nineteen' = 19
        }
        Tens             = @{
            'twenty' = 20; 'thirty' = 30; 'forty' = 40; 'fifty' = 50
            'sixty' = 60; 'seventy' = 70; 'eighty' = 80; 'ninety' = 90
        }
        Multipliers      = @{ 'hundred' = 100; 'thousand' = 1000; 'million' = 1000000 }

        # "minus one", "negative five"
        NegativeWords    = @('minus', 'negative')

        # Words that signal the customer is replacing an earlier number with a later one.
        # A cue only counts when it sits BETWEEN two different numbers.
        CorrectionCues   = @('actually', 'no', 'nope', 'sorry', 'rather', 'instead', 'correction',
                             'scratch', 'wait', 'mean', 'make', 'change', 'changed', 'update', 'correct')

        # "not a ten", "never a five" - the number is being rejected, not given.
        NegationWords    = @('not', 'never', 'isnt', 'wasnt', 'aint', 'hardly')

        # Words skipped when looking backwards for a negation word ("not really a ten").
        FillerWords      = @('a', 'an', 'the', 'really', 'quite', 'even', 'exactly', 'like')

        # A number followed by one of these is a quantity, not a score ("I waited ten minutes").
        QuantityNouns    = @('second', 'seconds', 'minute', 'minutes', 'min', 'mins', 'hour', 'hours',
                             'day', 'days', 'week', 'weeks', 'month', 'months', 'year', 'years',
                             'time', 'times', 'call', 'calls', 'agent', 'agents', 'transfer', 'transfers',
                             'attempt', 'attempts', 'people', 'person', 'persons', 'item', 'items',
                             'pound', 'pounds', 'dollar', 'dollars', 'euro', 'euros', 'oclock',
                             'am', 'pm', 'percent')

        # A number followed by one of these is a rating on a different scale ("five stars").
        AlternateScale   = @('star', 'stars')

        # "one" is very common in ordinary speech. It is ignored when it follows or precedes these.
        OneNonScorePrev  = @('that', 'this', 'the', 'every', 'any', 'which', 'each', 'some',
                             'another', 'only')
        OneNonScoreNext  = @('of', 'more', 'thing', 'things', 'question', 'another', 'way', 'issue',
                             'problem', 'bit', 'else', 'who', 'that', 'answered', 'helped', 'picked',
                             'called', 'told', 'could', 'would', 'was', 'is', 'did', 'has', 'had',
                             'cared', 'listened', 'seemed', 'came', 'knew', 'got')
    }
}

# ---------------------------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------------------------

function Format-NpsNumber {
    <#
    .SYNOPSIS
        Formats a number with a fixed number of decimals using '.' as the decimal separator,
        regardless of the current culture. CLM-safe (no CultureInfo static members).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$Value,
        [int]$Decimals = 1
    )

    $pattern = '0'
    if ($Decimals -gt 0) { $pattern = '0.' + ('0' * $Decimals) }
    # A '0.0' style format has no group separators, so the only possible comma is a
    # culture-specific decimal separator. Replace it to keep output culture-independent.
    $format = '{0:' + $pattern + '}'
    return ($format -f $Value).Replace(',', '.')
}

function Get-NpsCategory {
    <#
    .SYNOPSIS
        Maps a 0-10 score to its NPS category. Returns an empty string for anything else.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Score)

    if ($null -eq $Score -or [string]$Score -eq '') { return '' }
    if ([string]$Score -notmatch '^\d{1,2}$') { return '' }
    $value = [int]$Score
    if ($value -ge 0 -and $value -le 6) { return 'Detractor' }
    if ($value -ge 7 -and $value -le 8) { return 'Passive' }
    if ($value -ge 9 -and $value -le 10) { return 'Promoter' }
    return ''
}

function Get-NpsAuditPriority {
    <#
    .SYNOPSIS
        Maps an audit status to its priority.
    .NOTES
        "No input" is not listed in the original priority specification. This project treats it
        as Medium so blank responses still appear in the exceptions report for follow-up.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AuditStatus)

    switch ($AuditStatus) {
        'Valid'                  { return 'None' }
        'Likely missed score'    { return 'High' }
        'Score mismatch'         { return 'High' }
        'Invalid score response' { return 'High' }
        'Abandoned survey'       { return 'High' }
        'Low-confidence capture' { return 'Medium' }
        'Ambiguous response'     { return 'Medium' }
        'Review required'        { return 'Medium' }
        'No input'               { return 'Medium' }
        default                  { return 'Medium' }
    }
}

function Get-NpsAuditStatusList {
    <#
    .SYNOPSIS
        Returns every audit status in reporting order, with a short description.
    #>
    [CmdletBinding()]
    param()

    $list = @(
        @{ Status = 'Valid';                  Description = 'Expected and recorded score match, and confidence meets the threshold.' }
        @{ Status = 'Likely missed score';    Description = 'A clear 0-10 score was spoken or typed, but no score was recorded.' }
        @{ Status = 'Score mismatch';         Description = 'A clear score was given, but a different score was recorded.' }
        @{ Status = 'Low-confidence capture'; Description = 'The recorded score matches, but recognition confidence is below the threshold.' }
        @{ Status = 'Ambiguous response';     Description = 'Meaningful text exists, but no explicit 0-10 score can be safely inferred.' }
        @{ Status = 'Invalid score response'; Description = 'The customer attempted a rating outside the 0-10 range.' }
        @{ Status = 'No input';               Description = 'The utterance is blank or whitespace.' }
        @{ Status = 'Abandoned survey';       Description = 'The participant timed out, disconnected, or abandoned the survey.' }
        @{ Status = 'Review required';        Description = 'Complex or uncertain scenario (e.g. "eight or nine", "seven and a half", malformed data).' }
    )
    return $list
}

# ---------------------------------------------------------------------------------------------
# Utterance normalisation and tokenisation
# ---------------------------------------------------------------------------------------------

function ConvertTo-NpsNormalizedText {
    <#
    .SYNOPSIS
        Lower-cases an utterance, removes scale references ("out of ten", "/10", "0-10"),
        and reduces it to plain space-separated tokens.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return '' }
    $t = ' ' + $Text.ToLower() + ' '

    # Typographic characters -> ASCII (built from char codes so this file stays ASCII-only).
    $t = $t.Replace([string][char]0x2019, "'").Replace([string][char]0x2018, "'")
    $t = $t.Replace([string][char]0x201C, '"').Replace([string][char]0x201D, '"')
    $t = $t.Replace([string][char]0x2013, '-').Replace([string][char]0x2014, ' - ')
    $t = $t.Replace([string][char]0x2026, ' ... ').Replace([string][char]0x00A0, ' ')

    # Thousands separators and decimals in digit form: "1,000" -> "1000", "7.5" -> "7 point 5".
    $t = $t -replace '(\d),(\d{3})', '$1$2'
    $t = $t -replace '(\d)\.(\d)', '$1 point $2'

    # Remove references to the 0-10 scale itself so they are not mistaken for scores.
    #   "ten out of ten" -> "ten", "10/10" -> "10", "from zero to ten, a nine" -> "a nine"
    $t = $t -replace '\b(out\s+of|outta)\s+(a\s+)?(10|ten)\b', ' '
    $t = $t -replace '\s*/\s*(10|ten)\b', ' '
    $t = $t -replace '\bon\s+a\s+scale\s+of\b', ' '
    $t = $t -replace '\b(from\s+|between\s+)?(0|zero|1|one)\s*(-|to|through|thru|and)\s*(10|ten)\b', ' '

    # Numeric ranges "7-8" -> "7 to 8" (kept as two numbers so they are flagged for review).
    $t = $t -replace '(\d)\s*-\s*(\d)', '$1 to $2'
    # Leading minus sign "-1" -> "minus 1".
    $t = $t -replace '(^|\s)-\s?(\d)', '$1minus $2'

    # Contractions: "i'd" -> "id", "isn't" -> "isnt".
    $t = $t.Replace("'", '')
    # Everything that is not a letter or digit becomes a separator.
    $t = $t -replace '[^a-z0-9]+', ' '

    return $t.Trim()
}

function Get-NpsTokenValue {
    <#
    .SYNOPSIS
        Returns @{ Value; Kind } for a single numeric token, or $null if the token is not a number.
        Kind is one of: Digit, Word, Teen, Tens, Multiplier.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Token,
        [Parameter(Mandatory = $true)][hashtable]$Lexicon
    )

    if ($Token -match '^\d+$') {
        # [double] avoids overflow on absurdly long digit strings.
        return @{ Value = [double]$Token; Kind = 'Digit' }
    }
    if ($Lexicon.InRange.ContainsKey($Token))     { return @{ Value = [double]$Lexicon.InRange[$Token];     Kind = 'Word' } }
    if ($Lexicon.Teens.ContainsKey($Token))       { return @{ Value = [double]$Lexicon.Teens[$Token];       Kind = 'Teen' } }
    if ($Lexicon.Tens.ContainsKey($Token))        { return @{ Value = [double]$Lexicon.Tens[$Token];        Kind = 'Tens' } }
    if ($Lexicon.Multipliers.ContainsKey($Token)) { return @{ Value = [double]$Lexicon.Multipliers[$Token]; Kind = 'Multiplier' } }
    return $null
}

function Get-NpsNumberCandidates {
    <#
    .SYNOPSIS
        Scans normalised tokens and returns every number mention with its context.
    .OUTPUTS
        Array of hashtables: Value, Start, End, Text, Role, IsDecimal, IsNegated.
        Role is one of: Score, Quantity, AlternateScale, NonScoreOne.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Tokens,
        [Parameter(Mandatory = $true)][hashtable]$Lexicon
    )

    $candidates = @()
    if ($null -eq $Tokens) { return $candidates }
    $n = $Tokens.Count
    $i = 0

    while ($i -lt $n) {
        $start = $i
        $isNegative = $false

        # "minus one" / "negative five"
        if (($Lexicon.NegativeWords -contains $Tokens[$i]) -and (($i + 1) -lt $n)) {
            $peek = Get-NpsTokenValue -Token $Tokens[$i + 1] -Lexicon $Lexicon
            if ($null -ne $peek) { $isNegative = $true; $i++ }
        }

        $info = Get-NpsTokenValue -Token $Tokens[$i] -Lexicon $Lexicon
        if ($null -eq $info) { $i++; continue }

        $firstToken = $Tokens[$i]
        $value = $info.Value
        $isCompound = $false

        # "twenty five"
        if ($info.Kind -eq 'Tens' -and (($i + 1) -lt $n) -and $Lexicon.InRange.ContainsKey($Tokens[$i + 1])) {
            $unit = $Lexicon.InRange[$Tokens[$i + 1]]
            if ($unit -ge 1 -and $unit -le 9) { $value = $value + $unit; $i++; $isCompound = $true }
        }
        # "one hundred", "two thousand"
        if ($info.Kind -ne 'Multiplier' -and (($i + 1) -lt $n) -and $Lexicon.Multipliers.ContainsKey($Tokens[$i + 1])) {
            $value = $value * $Lexicon.Multipliers[$Tokens[$i + 1]]
            $i++
            $isCompound = $true
        }

        # Non-integer answers: "seven point five", "seven and a half", "seven half".
        $isDecimal = $false
        if ((($i + 2) -lt $n) -and $Tokens[$i + 1] -eq 'point' -and $null -ne (Get-NpsTokenValue -Token $Tokens[$i + 2] -Lexicon $Lexicon)) {
            $isDecimal = $true; $i += 2
        }
        elseif ((($i + 3) -lt $n) -and $Tokens[$i + 1] -eq 'and' -and $Tokens[$i + 2] -eq 'a' -and $Tokens[$i + 3] -eq 'half') {
            $isDecimal = $true; $i += 3
        }
        elseif ((($i + 2) -lt $n) -and $Tokens[$i + 1] -eq 'and' -and $Tokens[$i + 2] -eq 'half') {
            $isDecimal = $true; $i += 2
        }
        elseif ((($i + 1) -lt $n) -and $Tokens[$i + 1] -eq 'half') {
            $isDecimal = $true; $i += 1
        }

        $end = $i
        if ($isNegative) { $value = -1 * $value }

        # Context: the word right before, the word before ignoring fillers, and the word after.
        $prevRaw = ''
        if ($start -gt 0) { $prevRaw = $Tokens[$start - 1] }
        $prevMeaningful = ''
        $k = $start - 1
        while ($k -ge 0 -and ($Lexicon.FillerWords -contains $Tokens[$k])) { $k-- }
        if ($k -ge 0) { $prevMeaningful = $Tokens[$k] }
        $next = ''
        if (($end + 1) -lt $n) { $next = $Tokens[$end + 1] }

        $role = 'Score'
        if ($Lexicon.QuantityNouns -contains $next) {
            $role = 'Quantity'
        }
        elseif ($Lexicon.AlternateScale -contains $next) {
            $role = 'AlternateScale'
        }
        elseif ($firstToken -eq 'one' -and -not $isCompound -and -not $isNegative -and -not $isDecimal -and
                (($Lexicon.OneNonScorePrev -contains $prevRaw) -or ($Lexicon.OneNonScoreNext -contains $next))) {
            $role = 'NonScoreOne'
        }

        $candidates += @{
            Value     = $value
            Start     = $start
            End       = $end
            Text      = ($Tokens[$start..$end] -join ' ')
            Role      = $role
            IsDecimal = $isDecimal
            IsNegated = ($Lexicon.NegationWords -contains $prevMeaningful)
        }

        $i = $end + 1
    }

    return $candidates
}

# ---------------------------------------------------------------------------------------------
# Score extraction
# ---------------------------------------------------------------------------------------------

function Get-NpsExpectedScore {
    <#
    .SYNOPSIS
        Identifies the explicit NPS score (0-10) in an utterance, if one can be safely identified.

    .DESCRIPTION
        Never infers a score from sentiment. Returns an object whose Outcome is one of:
            Blank      - utterance is null, empty, or whitespace
            Score      - a single clear 0-10 score was found (ExpectedScore is set)
            NoScore    - meaningful text, but no explicit number
            Invalid    - the final number given is outside 0-10 ("eleven", "minus one", "one hundred")
            Uncertain  - numbers are present but cannot be safely resolved
                         ("eight or nine", "seven and a half", "not a ten", "five stars")

    .EXAMPLE
        (Get-NpsExpectedScore -Utterance "nine... no, ten").ExpectedScore   # 10
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Utterance)

    $result = @{
        Outcome           = 'NoScore'
        ExpectedScore     = $null
        AttemptedValue    = $null
        CorrectionApplied = $false
        Detail            = ''
        NormalizedText    = ''
    }

    if ($null -eq $Utterance -or $Utterance.Trim() -eq '') {
        $result.Outcome = 'Blank'
        $result.Detail = 'Utterance is blank.'
        return (New-Object PSObject -Property $result)
    }

    $lexicon = Get-NpsNumberLexicon
    $normalized = ConvertTo-NpsNormalizedText -Text $Utterance
    $result.NormalizedText = $normalized

    $tokens = @()
    if ($normalized -ne '') { $tokens = @($normalized -split '\s+' | Where-Object { $_ -ne '' }) }

    $all = @(Get-NpsNumberCandidates -Tokens $tokens -Lexicon $lexicon)
    $scoreCandidates = @($all | Where-Object { $_.Role -eq 'Score' })
    $altScale = @($all | Where-Object { $_.Role -eq 'AlternateScale' })

    if ($scoreCandidates.Count -eq 0) {
        if ($altScale.Count -gt 0) {
            $result.Outcome = 'Uncertain'
            $result.Detail = "Rating appears to use a different scale ('" + $altScale[0].Text + " stars'); not converted to 0-10."
        }
        else {
            $result.Outcome = 'NoScore'
            if ($all.Count -gt 0) {
                $result.Detail = 'Numbers were mentioned only as quantities or in non-score phrases; no explicit 0-10 score.'
            }
            else {
                $result.Detail = 'No explicit 0-10 score in the utterance; sentiment is not converted into a score.'
            }
        }
        return (New-Object PSObject -Property $result)
    }

    $first = $scoreCandidates[0]
    $last = $scoreCandidates[$scoreCandidates.Count - 1]
    $final = $last

    if ($scoreCandidates.Count -gt 1) {
        # A correction cue must appear between the first and last score mentions.
        $hasCorrection = $false
        for ($t = $first.End + 1; $t -lt $last.Start; $t++) {
            if ($lexicon.CorrectionCues -contains $tokens[$t]) { $hasCorrection = $true; break }
        }

        $distinct = @($scoreCandidates | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $outOfRange = @($scoreCandidates | Where-Object { $_.Value -lt 0 -or $_.Value -gt 10 })
        $mentioned = (@($scoreCandidates | ForEach-Object { $_.Text }) -join "', '")

        if ($hasCorrection -and $distinct.Count -gt 1) {
            $result.CorrectionApplied = $true
        }
        elseif ($distinct.Count -eq 1) {
            # The same number repeated ("nine, nine") - no conflict.
        }
        elseif ($outOfRange.Count -eq $scoreCandidates.Count) {
            # Every number is out of range ("ninety out of a hundred") - invalid either way.
        }
        else {
            $result.Outcome = 'Uncertain'
            $result.Detail = "Multiple different numbers ('" + $mentioned + "') without a clear correction."
            return (New-Object PSObject -Property $result)
        }
    }

    $result.AttemptedValue = $final.Value

    if ($final.IsNegated) {
        $result.Outcome = 'Uncertain'
        $result.Detail = "The number '" + $final.Text + "' is negated (for example 'not a ten'); no score can be safely inferred."
    }
    elseif ($final.IsDecimal) {
        $result.Outcome = 'Uncertain'
        $result.Detail = "Non-integer answer ('" + $final.Text + "'); NPS requires a whole number from 0 to 10."
    }
    elseif ($final.Value -lt 0 -or $final.Value -gt 10) {
        $result.Outcome = 'Invalid'
        $result.Detail = "Rating '" + $final.Text + "' (" + $final.Value + ") is outside the 0-10 NPS scale."
    }
    else {
        $result.Outcome = 'Score'
        $result.ExpectedScore = [int]$final.Value
        if ($result.CorrectionApplied) {
            $result.Detail = "Customer self-corrected; final explicit score '" + $final.Text + "' used."
        }
        else {
            $result.Detail = "Explicit score '" + $final.Text + "' identified."
        }
    }

    return (New-Object PSObject -Property $result)
}

# ---------------------------------------------------------------------------------------------
# Value parsing
# ---------------------------------------------------------------------------------------------

function ConvertTo-NpsRecordedScore {
    <#
    .SYNOPSIS
        Parses the recordedScore column. Returns @{ State; Value } where State is
        Blank, Valid (0-10 integer), OutOfRange, or Malformed.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    $v = $Value.Trim()
    if ($v -eq '') { return @{ State = 'Blank'; Value = $null } }
    if ($v -match '^\d{1,6}(\.0+)?$') {
        $n = [int](($v -split '\.')[0])
        if ($n -ge 0 -and $n -le 10) { return @{ State = 'Valid'; Value = $n } }
        return @{ State = 'OutOfRange'; Value = $null }
    }
    if ($v -match '^-\d+(\.\d+)?$') { return @{ State = 'OutOfRange'; Value = $null } }
    return @{ State = 'Malformed'; Value = $null }
}

function ConvertTo-NpsConfidence {
    <#
    .SYNOPSIS
        Parses the confidence column. Returns @{ State; Value } where State is
        NotReported (blank), Valid (0.0-1.0), or Malformed.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    $v = $Value.Trim()
    if ($v -eq '') { return @{ State = 'NotReported'; Value = $null } }
    if ($v -match '^(\d+(\.\d+)?|\.\d+)$') {
        $d = [double]$v
        if ($d -ge 0 -and $d -le 1) { return @{ State = 'Valid'; Value = $d } }
    }
    return @{ State = 'Malformed'; Value = $null }
}

function Get-NpsParticipantState {
    <#
    .SYNOPSIS
        Classifies the participantStatus column as Completed, Abandoned, or Unrecognised.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Status)

    if ($null -eq $Status) { $Status = '' }
    $s = $Status.Trim().ToLower()
    if ($s -match 'time\s*-?\s*d?\s*out|disconnect|abandon|hang\s*-?\s*up|hung\s*-?\s*up|dropped') { return 'Abandoned' }
    if ($s -eq '' -or $s -match '^(completed?|finished|answered|success(ful)?)$') { return 'Completed' }
    return 'Unrecognised'
}

# ---------------------------------------------------------------------------------------------
# Main analysis function
# ---------------------------------------------------------------------------------------------

function Invoke-NpsUtteranceAnalysis {
    <#
    .SYNOPSIS
        Audits a single NPS survey response and assigns exactly one audit status.

    .PARAMETER Utterance
        What the customer said (voice transcript) or typed (digital).
    .PARAMETER RecordedScore
        The score the survey platform stored. Blank if nothing was captured.
    .PARAMETER Confidence
        Recognition confidence from 0.0 to 1.0. Blank means "not reported" (for example
        typed digital responses); the threshold check is then skipped.
    .PARAMETER ParticipantStatus
        Completed, Timeout, Disconnected, Abandoned, etc.
    .PARAMETER ConfidenceThreshold
        Minimum acceptable confidence. Default 0.70.

    .OUTPUTS
        PSObject with ExpectedScore, AuditStatus, Priority, Reason, RequiresReview,
        NpsCategoryRecorded, NpsCategoryExpected, RecordedScoreValue, ConfidenceValue,
        CorrectionApplied.

    .EXAMPLE
        Invoke-NpsUtteranceAnalysis -Utterance "ten out of ten" -RecordedScore "" -Confidence 0.58
        # AuditStatus: Likely missed score
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Utterance,
        [AllowNull()][AllowEmptyString()][string]$RecordedScore,
        [AllowNull()][AllowEmptyString()][string]$Confidence,
        [AllowNull()][AllowEmptyString()][string]$ParticipantStatus = 'Completed',
        [ValidateRange(0.0, 1.0)][double]$ConfidenceThreshold = 0.70
    )

    $thresholdText = Format-NpsNumber -Value $ConfidenceThreshold -Decimals 2
    $parsed = Get-NpsExpectedScore -Utterance $Utterance
    $recorded = ConvertTo-NpsRecordedScore -Value $RecordedScore
    $conf = ConvertTo-NpsConfidence -Value $Confidence
    $participant = Get-NpsParticipantState -Status $ParticipantStatus

    $expected = $parsed.ExpectedScore
    $recText = ''
    if ($recorded.State -eq 'Valid') { $recText = [string]$recorded.Value }
    $confText = 'not reported'
    if ($conf.State -eq 'Valid') { $confText = Format-NpsNumber -Value $conf.Value -Decimals 2 }

    $status = ''
    $reason = ''

    # Classification order matters: the first matching rule wins, so every record receives
    # exactly one status.
    if ($participant -eq 'Abandoned') {
        $status = 'Abandoned survey'
        $reason = "Participant status '" + $ParticipantStatus.Trim() + "' indicates the survey was not completed."
        if ($null -ne $expected) { $reason += " A score of $expected was heard before the survey ended." }
        if ($recText -ne '') { $reason += " Recorded score $recText should be verified." }
    }
    elseif ($participant -eq 'Unrecognised') {
        $status = 'Review required'
        $reason = "Unrecognised participant status '" + $ParticipantStatus.Trim() + "'."
    }
    elseif ($recorded.State -eq 'OutOfRange' -or $recorded.State -eq 'Malformed') {
        $status = 'Review required'
        $reason = "Recorded score '" + $RecordedScore.Trim() + "' is not a whole number from 0 to 10 (data quality issue)."
    }
    elseif ($conf.State -eq 'Malformed') {
        $status = 'Review required'
        $reason = "Confidence value '" + $Confidence.Trim() + "' is not a number between 0 and 1."
    }
    elseif ($parsed.Outcome -eq 'Blank') {
        $status = 'No input'
        $reason = 'No utterance was captured.'
        if ($recText -ne '') { $reason += " A score of $recText was recorded without an utterance (possible keypad entry); verify the source." }
    }
    elseif ($parsed.Outcome -eq 'Invalid') {
        $status = 'Invalid score response'
        $reason = $parsed.Detail
        if ($recText -ne '') { $reason += " Recorded score $recText is not supported by the utterance." }
    }
    elseif ($parsed.Outcome -eq 'Uncertain') {
        $status = 'Review required'
        $reason = $parsed.Detail
        if ($recText -ne '') { $reason += " Recorded score $recText needs manual confirmation." }
    }
    elseif ($parsed.Outcome -eq 'NoScore') {
        $status = 'Ambiguous response'
        $reason = $parsed.Detail
        if ($recText -ne '') { $reason += " Recorded score $recText is not supported by an explicit number." }
    }
    elseif ($recorded.State -eq 'Blank') {
        $status = 'Likely missed score'
        $reason = "Customer gave a clear score of $expected but no score was recorded (confidence $confText)."
    }
    elseif ($recorded.Value -ne $expected) {
        $status = 'Score mismatch'
        $reason = "Utterance indicates $expected but $recText was recorded."
        if ($parsed.CorrectionApplied) { $reason += ' The customer self-corrected; the platform may have kept the first number.' }
    }
    elseif ($conf.State -eq 'Valid' -and $conf.Value -lt $ConfidenceThreshold) {
        $status = 'Low-confidence capture'
        $reason = "Recorded score $recText matches the utterance, but confidence $confText is below the $thresholdText threshold."
    }
    else {
        $status = 'Valid'
        if ($conf.State -eq 'Valid') {
            $reason = "Recorded score $recText matches the utterance; confidence $confText meets the $thresholdText threshold."
        }
        else {
            $reason = "Recorded score $recText matches the utterance; confidence not reported, threshold check skipped."
        }
        if ($parsed.CorrectionApplied) { $reason += ' Customer self-corrected; final score used.' }
    }

    $priority = Get-NpsAuditPriority -AuditStatus $status

    $output = New-Object PSObject -Property @{
        ExpectedScore       = $expected
        AuditStatus         = $status
        Priority            = $priority
        Reason              = $reason
        RequiresReview      = ($priority -ne 'None')
        NpsCategoryRecorded = (Get-NpsCategory -Score $recorded.Value)
        NpsCategoryExpected = (Get-NpsCategory -Score $expected)
        RecordedScoreValue  = $recorded.Value
        ConfidenceValue     = $conf.Value
        CorrectionApplied   = $parsed.CorrectionApplied
    }

    return ($output | Select-Object ExpectedScore, AuditStatus, Priority, Reason, RequiresReview,
        NpsCategoryRecorded, NpsCategoryExpected, RecordedScoreValue, ConfidenceValue, CorrectionApplied)
}

# ---------------------------------------------------------------------------------------------
# NPS calculation
# ---------------------------------------------------------------------------------------------

function Get-NpsScoreSummary {
    <#
    .SYNOPSIS
        Calculates promoter / passive / detractor counts, percentages, and NPS from 0-10 scores.
        Non-integer, blank, and out-of-range values are ignored.
    .OUTPUTS
        PSObject: ScoredResponses, Promoters, Passives, Detractors,
                  PromoterPercent, PassivePercent, DetractorPercent, Nps.
        Percentages and Nps are $null when there are no scored responses.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Scores)

    $promoters = 0; $passives = 0; $detractors = 0
    foreach ($s in @($Scores)) {
        $category = Get-NpsCategory -Score $s
        if ($category -eq 'Promoter') { $promoters++ }
        elseif ($category -eq 'Passive') { $passives++ }
        elseif ($category -eq 'Detractor') { $detractors++ }
    }

    $total = $promoters + $passives + $detractors
    $promoterPct = $null; $passivePct = $null; $detractorPct = $null; $nps = $null
    if ($total -gt 0) {
        $promoterPct = ($promoters / $total) * 100
        $passivePct = ($passives / $total) * 100
        $detractorPct = ($detractors / $total) * 100
        $nps = $promoterPct - $detractorPct
    }

    return (New-Object PSObject -Property @{
        ScoredResponses  = $total
        Promoters        = $promoters
        Passives         = $passives
        Detractors       = $detractors
        PromoterPercent  = $promoterPct
        PassivePercent   = $passivePct
        DetractorPercent = $detractorPct
        Nps              = $nps
    })
}

# When run directly (instead of dot-sourced), explain how to use the library.
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host 'Invoke-NpsUtteranceAnalysis.ps1 is a function library. Dot-source it to load the functions:' -ForegroundColor Yellow
    Write-Host '    . .\Invoke-NpsUtteranceAnalysis.ps1'
    Write-Host '    Invoke-NpsUtteranceAnalysis -Utterance "nine... no, ten" -RecordedScore 10 -Confidence 0.84'
    Write-Host 'To audit a CSV export, run .\Export-GenesysNpsAudit.ps1 instead.'
}
