[CmdletBinding()]
param(
    [string]$EventDirectory = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($EventDirectory)) {
    $EventDirectory = Join-Path $env:LOCALAPPDATA 'NotifyPet\events'
}

function Write-HookDiagnostic {
    param($ErrorRecord)

    try {
        $message = if ($null -ne $ErrorRecord.Exception) {
            [string]$ErrorRecord.Exception.Message
        }
        else {
            [string]$ErrorRecord
        }
        $logPath = Join-Path $PSScriptRoot 'ReimuWatch.log'
        $line = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff') +
            ' Claude Hook error: ' + $message + [Environment]::NewLine
        [IO.File]::AppendAllText($logPath, $line, (New-Object Text.UTF8Encoding($false)))
    }
    catch {
    }
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

function Test-NonWorkingPrompt {
    param([string]$Prompt)

    $text = [string]$Prompt
    # Claude may pass slash commands either as plain text or command markup.
    # /model changes local configuration and never starts a model turn.
    return $text -match '(?is)^\s*<local-command-' -or
        $text -match '(?is)^\s*<command-name>\s*/[a-z0-9_-]+.*?</command-name>' -or
        $text -match '(?im)^\s*/model(?:\s|$)'
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
    param($Entry, [string]$TranscriptPath, [string]$Raw)

    $eventId = [string]$Entry.uuid
    if (-not [string]::IsNullOrWhiteSpace($eventId)) {
        return $eventId
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($TranscriptPath + "`n" + $Raw)
        $hash = $sha.ComputeHash($bytes)
        return 'transcript-' + ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 24).ToLowerInvariant())
    }
    finally {
        $sha.Dispose()
    }
}

function Get-TranscriptState {
    param([string]$TranscriptPath)

    $state = @{
        ErrorKind = ''
        ErrorText = ''
        ErrorId = ''
        TurnEventId = ''
    }
    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path -LiteralPath $TranscriptPath)) {
        return $state
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in @(Get-Content -LiteralPath $TranscriptPath -Tail 400 -ErrorAction SilentlyContinue)) {
        try {
            $entry = $line | ConvertFrom-Json
            $entries.Add([pscustomobject]@{ Value = $entry; Raw = $line })
        }
        catch {
        }
    }

    $lastUserIndex = -1
    for ($index = $entries.Count - 1; $index -ge 0; $index--) {
        if ($entries[$index].Value.type -eq 'user') {
            $lastUserIndex = $index
            break
        }
    }

    $scanStart = if ($lastUserIndex -ge 0) { $lastUserIndex + 1 } else { 0 }
    if ($lastUserIndex -ge 0) {
        $userId = [string]$entries[$lastUserIndex].Value.uuid
        if (-not [string]::IsNullOrWhiteSpace($userId)) {
            $state.TurnEventId = 'turn-' + $userId
        }
        else {
            $state.TurnEventId = Get-ErrorEventId `
                -Entry $entries[$lastUserIndex].Value `
                -TranscriptPath $TranscriptPath `
                -Raw $entries[$lastUserIndex].Raw
        }
    }
    for ($index = $scanStart; $index -lt $entries.Count; $index++) {
        $record = $entries[$index]
        if (Test-ClaudeErrorEntry -Entry $record.Value -Raw $record.Raw) {
            $state.ErrorKind = if (Test-RateLimitEntry -Entry $record.Value -Raw $record.Raw) { 'RateLimited' } else { 'Error' }
            $state.ErrorText = Get-ClaudeErrorText -Entry $record.Value
            $state.ErrorId = Get-ErrorEventId -Entry $record.Value -TranscriptPath $TranscriptPath -Raw $record.Raw
        }
    }
    return $state
}

function Write-EventFile {
    param([System.Collections.IDictionary]$Event)

    [IO.Directory]::CreateDirectory($EventDirectory) | Out-Null
    $cutoff = [DateTime]::UtcNow.AddHours(-1)
    Get-ChildItem -LiteralPath $EventDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $json = $Event | ConvertTo-Json -Compress -Depth 6
    $name = ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff') + '-' + [Guid]::NewGuid().ToString('N'))
    $tempPath = Join-Path $EventDirectory ($name + '.tmp')
    $eventPath = Join-Path $EventDirectory ($name + '.json')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($tempPath, $json, $utf8)
    Move-Item -LiteralPath $tempPath -Destination $eventPath
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        exit 0
    }

    $payload = $raw | ConvertFrom-Json
    $eventName = [string]$payload.hook_event_name
    $transcriptPath = [string]$payload.transcript_path

    if ($eventName -eq 'UserPromptSubmit') {
        $promptParts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($candidate in @(
            [string]$payload.prompt,
            [string]$payload.command,
            [string]$payload.command_name,
            [string]$payload.message,
            [string]$raw
        )) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $promptParts.Add($candidate)
            }
        }
        $promptText = [string]::Join([Environment]::NewLine, $promptParts)
        if (-not (Test-NonWorkingPrompt -Prompt $promptText)) {
            Write-EventFile ([ordered]@{
                type = 'activity'
                activity = 'working'
                source = 'Claude Code'
                eventId = [Guid]::NewGuid().ToString('N')
                transcriptPath = $transcriptPath
                createdAt = [DateTime]::Now.ToString('o')
            })
        }
        exit 0
    }

    $title = ''
    $body = ''
    $eventId = [Guid]::NewGuid().ToString('N')

    if ($eventName -eq 'PermissionRequest') {
        $title = 'Claude permission required'
        $toolName = [string]$payload.tool_name
        $body = if ([string]::IsNullOrWhiteSpace($toolName)) {
            'Claude is waiting for permission.'
        }
        else {
            'Claude is waiting for permission: ' + $toolName
        }
    }
    elseif ($eventName -eq 'Notification') {
        $notificationText = [string]$payload.notification_type + "`n" + [string]$payload.title + "`n" + [string]$payload.message
        if ($notificationText -match '(?i)permission|approval|allow|权限|授权|批准|确认') {
            $title = 'Claude permission required'
            $body = if ([string]::IsNullOrWhiteSpace([string]$payload.message)) {
                'Claude is waiting for permission.'
            }
            else {
                [string]$payload.message
            }
        }
    }
    elseif ($eventName -eq 'Stop') {
        Write-EventFile ([ordered]@{
            type = 'activity'
            activity = 'idle'
            source = 'Claude Code'
            eventId = [Guid]::NewGuid().ToString('N')
            transcriptPath = $transcriptPath
            createdAt = [DateTime]::Now.ToString('o')
        })
        $transcript = Get-TranscriptState -TranscriptPath $transcriptPath
        if ($transcript.ErrorKind -eq 'RateLimited') {
            $title = 'Claude 429 rate limit'
            $body = $transcript.ErrorText
            $eventId = $transcript.ErrorId
        }
        elseif ($transcript.ErrorKind -eq 'Error') {
            $title = 'Claude error'
            $body = $transcript.ErrorText
            $eventId = $transcript.ErrorId
        }
        else {
            $title = 'Claude command completed'
            $body = 'Claude completed the current task.'
            if (-not [string]::IsNullOrWhiteSpace([string]$transcript.TurnEventId)) {
                $eventId = [string]$transcript.TurnEventId
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        exit 0
    }

    Write-EventFile ([ordered]@{
        type = 'notification'
        id = 0
        source = 'Claude Code'
        title = $title
        body = $body
        eventId = $eventId
        transcriptPath = $transcriptPath
        createdAt = [DateTime]::Now.ToString('o')
    })
    exit 0
}
catch {
    Write-HookDiagnostic -ErrorRecord $_
    # Notification failures must never interrupt or add an error panel to Claude CLI.
    exit 0
}
