[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$ParentProcessId,
    [string]$EventDirectory = '',
    [string]$TranscriptDirectory = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($EventDirectory)) {
    $EventDirectory = Join-Path $env:LOCALAPPDATA 'NotifyPet\events'
}
if ([string]::IsNullOrWhiteSpace($TranscriptDirectory)) {
    $TranscriptDirectory = Join-Path $env:USERPROFILE '.claude\projects'
}

function Send-BridgeMessage {
    param([hashtable]$Value)
    [Console]::Out.WriteLine(($Value | ConvertTo-Json -Compress -Depth 6))
    [Console]::Out.Flush()
}

function Get-MessageText {
    param($Entry)
    if ($null -eq $Entry -or $null -eq $Entry.message) {
        return ''
    }

    $content = $Entry.message.content
    if ($content -is [string]) {
        return [string]$content
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($block in @($content)) {
        if ($null -ne $block -and $block.type -eq 'text' -and -not [string]::IsNullOrWhiteSpace([string]$block.text)) {
            $parts.Add([string]$block.text)
        }
    }
    return [string]::Join([Environment]::NewLine, $parts)
}

function Test-RateLimitEntry {
    param($Entry, [string]$Raw)
    $status = [string]$Entry.apiErrorStatus
    $text = ([string]$Raw) + "`n" + [string]$Entry.error + "`n" + (Get-MessageText $Entry)
    $isStructuredError = $Entry.isApiErrorMessage -eq $true -or
        -not [string]::IsNullOrWhiteSpace($status) -or
        -not [string]::IsNullOrWhiteSpace([string]$Entry.error)
    return $status -eq '429' -or
        ($isStructuredError -and $text -match '(?i)\b429\b|too[\s_-]*many[\s_-]*requests|rate[\s_-]*limit')
}

function Test-ClaudeErrorEntry {
    param($Entry, [string]$Raw)

    if (Test-RateLimitEntry -Entry $Entry -Raw $Raw) {
        return $true
    }

    $status = [string]$Entry.apiErrorStatus
    $errorValue = [string]$Entry.error
    $isExplicitError = $Entry.isApiErrorMessage -eq $true -or
        $Entry.is_error -eq $true -or
        -not [string]::IsNullOrWhiteSpace($status) -or
        -not [string]::IsNullOrWhiteSpace($errorValue)
    $isErrorRecord = [string]$Entry.type -eq 'system' -and
        [string]$Entry.subtype -match '(?i)api[_-]?error|error|failure'
    return $isExplicitError -or $isErrorRecord
}

function Get-ClaudeErrorText {
    param($Entry)

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $status = [string]$Entry.apiErrorStatus
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        $parts.Add('API status: ' + $status)
    }

    if ($null -ne $Entry.error) {
        $errorText = if ($Entry.error -is [string]) {
            [string]$Entry.error
        }
        else {
            $Entry.error | ConvertTo-Json -Compress -Depth 5
        }
        if (-not [string]::IsNullOrWhiteSpace($errorText)) {
            $parts.Add($errorText.Trim())
        }
    }

    $messageText = (Get-MessageText $Entry).Trim()
    if (-not [string]::IsNullOrWhiteSpace($messageText) -and -not $parts.Contains($messageText)) {
        $parts.Add($messageText)
    }

    if ($parts.Count -eq 0) {
        $parts.Add('Claude 返回了未提供详细信息的错误。')
    }

    $result = [string]::Join([Environment]::NewLine, $parts)
    if ($result.Length -gt 1200) {
        $result = $result.Substring(0, 1200) + '...'
    }
    return $result
}

function Get-ErrorEventId {
    param($Entry, [string]$Path, [string]$Raw)

    $eventId = [string]$Entry.uuid
    if (-not [string]::IsNullOrWhiteSpace($eventId)) {
        return $eventId
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Path + "`n" + $Raw)
        $hash = $sha.ComputeHash($bytes)
        return 'transcript-' + ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 24).ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

function Read-TranscriptDelta {
    param([string]$Path, [long]$Offset)
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        if ($stream.Length -le $Offset) {
            return @{ Offset = $stream.Length; Lines = @() }
        }
        [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        return @{
            Offset = $stream.Position
            Lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Drain-EventQueue {
    foreach ($eventFile in @(Get-ChildItem -LiteralPath $EventDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $json = [IO.File]::ReadAllText($eventFile.FullName)
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                [Console]::Out.WriteLine($json)
                [Console]::Out.Flush()
            }
            Remove-Item -LiteralPath $eventFile.FullName -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
}

function Get-TurnEventId {
    param($Entry, [string]$Path, [string]$Raw)

    $entryId = [string]$Entry.uuid
    if (-not [string]::IsNullOrWhiteSpace($entryId)) {
        return 'turn-' + $entryId
    }
    return Get-ErrorEventId -Entry $Entry -Path $Path -Raw $Raw
}

function Test-HumanPromptEntry {
    param($Entry)

    if ([string]$Entry.type -ne 'user' -or $null -eq $Entry.message) {
        return $false
    }
    if ($Entry.message.content -is [string]) {
        return $true
    }
    foreach ($block in @($Entry.message.content)) {
        if ([string]$block.type -eq 'tool_result') {
            return $false
        }
    }
    return $true
}

function Scan-TranscriptEvents {
    param(
        [hashtable]$Offsets,
        [hashtable]$SeenErrors,
        [hashtable]$ActiveTurns,
        [hashtable]$TurnHasErrors
    )

    if (-not (Test-Path -LiteralPath $TranscriptDirectory)) {
        return
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $TranscriptDirectory -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
        try {
            if (-not $Offsets.ContainsKey($file.FullName)) {
                $Offsets[$file.FullName] = $file.Length
                continue
            }

            $delta = Read-TranscriptDelta -Path $file.FullName -Offset ([long]$Offsets[$file.FullName])
            $Offsets[$file.FullName] = $delta.Offset
            foreach ($line in @($delta.Lines)) {
                try {
                    $entry = $line | ConvertFrom-Json
                    if ([string]$entry.type -eq 'user') {
                        if (Test-HumanPromptEntry -Entry $entry) {
                            $ActiveTurns[$file.FullName] = Get-TurnEventId -Entry $entry -Path $file.FullName -Raw $line
                            $TurnHasErrors[$file.FullName] = $false
                        }
                        Send-BridgeMessage @{
                            type = 'activity'
                            activity = 'working'
                            source = 'Claude Code'
                            eventId = if ([string]::IsNullOrWhiteSpace([string]$entry.uuid)) { [Guid]::NewGuid().ToString('N') } else { 'working-' + [string]$entry.uuid }
                            transcriptPath = $file.FullName
                            createdAt = if ([string]::IsNullOrWhiteSpace([string]$entry.timestamp)) { [DateTime]::Now.ToString('o') } else { [string]$entry.timestamp }
                        }
                        continue
                    }

                    if ([string]$entry.type -eq 'system' -and
                        [string]$entry.subtype -eq 'stop_hook_summary') {
                        Send-BridgeMessage @{
                            type = 'activity'
                            activity = 'idle'
                            source = 'Claude Code'
                            eventId = 'idle-' + [string]$entry.uuid
                            transcriptPath = $file.FullName
                            createdAt = if ([string]::IsNullOrWhiteSpace([string]$entry.timestamp)) { [DateTime]::Now.ToString('o') } else { [string]$entry.timestamp }
                        }

                        $turnFailed = $TurnHasErrors.ContainsKey($file.FullName) -and $TurnHasErrors[$file.FullName]
                        if (-not $turnFailed) {
                            $turnEventId = if ($ActiveTurns.ContainsKey($file.FullName)) {
                                [string]$ActiveTurns[$file.FullName]
                            }
                            elseif (-not [string]::IsNullOrWhiteSpace([string]$entry.uuid)) {
                                'stop-' + [string]$entry.uuid
                            }
                            else {
                                Get-ErrorEventId -Entry $entry -Path $file.FullName -Raw $line
                            }
                            Send-BridgeMessage @{
                                type = 'notification'
                                id = 0
                                source = 'Claude Code'
                                title = 'Claude command completed'
                                body = 'Claude completed the current task.'
                                eventId = $turnEventId
                                transcriptPath = $file.FullName
                                createdAt = if ([string]::IsNullOrWhiteSpace([string]$entry.timestamp)) { [DateTime]::Now.ToString('o') } else { [string]$entry.timestamp }
                            }
                        }
                        $ActiveTurns.Remove($file.FullName)
                        $TurnHasErrors.Remove($file.FullName)
                        continue
                    }

                    if (-not (Test-ClaudeErrorEntry -Entry $entry -Raw $line)) {
                        continue
                    }

                    $TurnHasErrors[$file.FullName] = $true

                    $eventId = Get-ErrorEventId -Entry $entry -Path $file.FullName -Raw $line
                    if ($SeenErrors.ContainsKey($eventId)) {
                        continue
                    }
                    $SeenErrors[$eventId] = $true

                    $createdAt = [DateTime]::Now.ToString('o')
                    if (-not [string]::IsNullOrWhiteSpace([string]$entry.timestamp)) {
                        $createdAt = [string]$entry.timestamp
                    }
                    $isRateLimited = Test-RateLimitEntry -Entry $entry -Raw $line
                    Send-BridgeMessage @{
                        type = 'notification'
                        id = 0
                        source = 'Claude Code'
                        title = if ($isRateLimited) { 'Claude 429 rate limit' } else { 'Claude error' }
                        body = Get-ClaudeErrorText -Entry $entry
                        eventId = $eventId
                        transcriptPath = $file.FullName
                        createdAt = $createdAt
                    }
                }
                catch {
                }
            }
        }
        catch {
        }
    }
}

try {
    [IO.Directory]::CreateDirectory($EventDirectory) | Out-Null
    $offsets = @{}
    $seenErrors = @{}
    $activeTurns = @{}
    $turnHasErrors = @{}

    foreach ($stale in @(Get-ChildItem -LiteralPath $EventDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TranscriptDirectory) {
        foreach ($existingTranscript in @(Get-ChildItem -LiteralPath $TranscriptDirectory -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $offsets[$existingTranscript.FullName] = $existingTranscript.Length
        }
    }
    Send-BridgeMessage @{ type = 'status'; status = 'ready'; message = 'Claude hooks are ready' }

    while ($true) {
        if (-not (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
            break
        }
        Scan-TranscriptEvents `
            -Offsets $offsets `
            -SeenErrors $seenErrors `
            -ActiveTurns $activeTurns `
            -TurnHasErrors $turnHasErrors
        Drain-EventQueue
        Start-Sleep -Milliseconds 200
    }
}
catch {
    Send-BridgeMessage @{ type = 'status'; status = 'error'; message = $_.Exception.Message }
    exit 1
}
