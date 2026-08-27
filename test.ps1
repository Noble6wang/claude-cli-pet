[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

& (Join-Path $projectRoot 'build.ps1') -Clean

$exe = Join-Path $projectRoot 'build\ReimuWatch.exe'
$icon = Join-Path $projectRoot 'build\ReimuWatch.ico'
$bridge = Join-Path $projectRoot 'build\NotificationBridge.ps1'
$hook = Join-Path $projectRoot 'build\ClaudeHook.ps1'
$installer = Join-Path $projectRoot 'build\InstallClaudeHooks.ps1'

foreach ($required in @($exe, $icon, $bridge, $hook, $installer)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Smoke-test prerequisite missing: $required"
    }
}

$assembly = [Reflection.Assembly]::LoadFrom($exe)
$versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
$expectedDescription = -join @([char]0x7075, [char]0x68A6, [char]0x503C, [char]0x5B88)
if ($versionInfo.ProductName -ne 'Reimu Watch' -or $versionInfo.FileDescription -ne $expectedDescription) {
    throw 'Reimu Watch executable metadata was not embedded correctly.'
}
$associatedIcon = [Drawing.Icon]::ExtractAssociatedIcon($exe)
if ($null -eq $associatedIcon) {
    throw 'Reimu Watch executable icon was not embedded.'
}
$associatedIcon.Dispose()
Write-Host 'PASS Reimu Watch name and icon metadata'

$parserType = $assembly.GetType('NotifyPet.ClaudeNotificationParser', $true)
$parseMethod = $parserType.GetMethod('Parse', [Reflection.BindingFlags]'Public,Static')

function Invoke-ClaudeParse {
    param(
        [string]$Source,
        [string]$Title,
        [string]$Body
    )
    return $parseMethod.Invoke($null, @([uint32]1, $Source, $Title, $Body, [DateTime]::Now))
}

$unrelated = Invoke-ClaudeParse -Source 'Outlook' -Title 'Command completed' -Body 'Mail sync done'
if ($null -ne $unrelated) {
    throw 'A non-Claude notification was not filtered out.'
}

$completed = Invoke-ClaudeParse -Source 'Windows Terminal' -Title 'Claude Code' -Body 'Command completed'
if ($completed.Kind.ToString() -ne 'Completed') {
    throw 'Claude completion notification was not classified correctly.'
}

$permission = Invoke-ClaudeParse -Source 'Windows Terminal' -Title 'Claude Code' -Body 'Permission required: allow file write'
if ($permission.Kind.ToString() -ne 'PermissionRequired') {
    throw 'Claude permission notification was not classified correctly.'
}

$rateLimited = Invoke-ClaudeParse -Source 'Windows Terminal' -Title 'Claude Code' -Body 'API Error: 429 Too Many Requests'
if ($rateLimited.Kind.ToString() -ne 'RateLimited' -or $rateLimited.Body -notmatch '429') {
    throw 'Claude 429 notification classification failed.'
}

$errorNotification = Invoke-ClaudeParse -Source 'Claude Code' -Title 'Claude error' -Body 'API status: 500`nInternal server error'
if ($errorNotification.Kind.ToString() -ne 'Error' -or $errorNotification.Body -notmatch 'Internal server error') {
    throw 'Claude generic error notification classification failed.'
}

Write-Host 'PASS Claude completion, permission and 429 classification'
Write-Host 'PASS non-Claude notifications are ignored'
Write-Host 'PASS Claude generic error classification'

$monitorType = $assembly.GetType('NotifyPet.ClaudeWindowMonitor', $true)
$foregroundMethod = $monitorType.GetMethod('IsForegroundClaude', [Reflection.BindingFlags]'NonPublic,Static')
if (-not $foregroundMethod.Invoke($null, @('WindowsTerminal', 'CASCADIA_HOSTING_WINDOW_CLASS', 'PowerShell', $true))) {
    throw 'Claude foreground detection did not recognize Windows Terminal with Claude running.'
}
if ($foregroundMethod.Invoke($null, @('notepad', 'Notepad', 'Claude notes', $false))) {
    throw 'Claude foreground detection incorrectly matched an unrelated foreground window.'
}
Write-Host 'PASS Claude foreground window detection'

$deduplicatorType = $assembly.GetType('NotifyPet.ClaudeEventDeduplicator', $true)
$deduplicator = [Activator]::CreateInstance($deduplicatorType, $true)
$duplicateMethod = $deduplicatorType.GetMethod('IsDuplicate', [Reflection.BindingFlags]'Public,Instance')
$first429Duplicate = $duplicateMethod.Invoke($deduplicator, @('429-event-one'))
$second429Duplicate = $duplicateMethod.Invoke($deduplicator, @('429-event-two'))
$repeatedEventDuplicate = $duplicateMethod.Invoke($deduplicator, @('429-event-one'))
if ($first429Duplicate -or $second429Duplicate -or -not $repeatedEventDuplicate) {
    throw 'Distinct 429 event IDs were incorrectly throttled or duplicate IDs were not suppressed.'
}
Write-Host 'PASS repeated 429 errors with distinct event IDs are delivered'

$petWindowType = $assembly.GetType('NotifyPet.PetWindow', $true)
$headHitMethod = $petWindowType.GetMethod('IsHeadHitPoint', [Reflection.BindingFlags]'NonPublic,Static')
if (-not $headHitMethod.Invoke($null, @([double]74, [double]40))) {
    throw 'The pet head was not included in the draggable hit region.'
}
if ($headHitMethod.Invoke($null, @([double]74, [double]118))) {
    throw 'The pet body was incorrectly included in the draggable hit region.'
}
$clickThroughMethod = $petWindowType.GetMethod('ApplyClickThroughStyle', [Reflection.BindingFlags]'NonPublic,Static')
$transparentStyle = [int64]$clickThroughMethod.Invoke($null, @([int64]0, $true))
$interactiveStyle = [int64]$clickThroughMethod.Invoke($null, @($transparentStyle, $false))
if (($transparentStyle -band 0x20) -eq 0 -or ($interactiveStyle -band 0x20) -ne 0) {
    throw 'The pet click-through window style was not toggled correctly.'
}
Write-Host 'PASS only the pet head is interactive'

$showStatusMethod = $petWindowType.GetMethod('ShouldShowPersistentStatus', [Reflection.BindingFlags]'NonPublic,Static')
if (-not $showStatusMethod.Invoke($null, @($true, $true, $false)) -or
    $showStatusMethod.Invoke($null, @($false, $true, $false))) {
    throw 'Hidden idle status did not reopen only for active Claude work.'
}
$autoDismissMethod = $petWindowType.GetMethod('ShouldAutoDismissNotification', [Reflection.BindingFlags]'NonPublic,Static')
$completedKind = [Enum]::Parse($completed.Kind.GetType(), 'Completed')
$permissionKind = [Enum]::Parse($completed.Kind.GetType(), 'PermissionRequired')
$rateLimitedKind = [Enum]::Parse($completed.Kind.GetType(), 'RateLimited')
$errorKind = [Enum]::Parse($completed.Kind.GetType(), 'Error')
$unknownKind = [Enum]::Parse($completed.Kind.GetType(), 'Unknown')
if ($autoDismissMethod.Invoke($null, @($completedKind)) -or
    $autoDismissMethod.Invoke($null, @($permissionKind)) -or
    $autoDismissMethod.Invoke($null, @($rateLimitedKind)) -or
    $autoDismissMethod.Invoke($null, @($errorKind)) -or
    -not $autoDismissMethod.Invoke($null, @($unknownKind))) {
    throw 'A persistent Claude notification was incorrectly configured to auto-dismiss.'
}
$foregroundDismissMethod = $petWindowType.GetMethod('ShouldDismissNotificationWhenClaudeForeground', [Reflection.BindingFlags]'NonPublic,Static')
if (-not $foregroundDismissMethod.Invoke($null, @($completedKind)) -or
    -not $foregroundDismissMethod.Invoke($null, @($rateLimitedKind)) -or
    -not $foregroundDismissMethod.Invoke($null, @($errorKind)) -or
    $foregroundDismissMethod.Invoke($null, @($permissionKind))) {
    throw 'Claude foreground dismissal rules were incorrect.'
}
$activityDismissMethod = $petWindowType.GetMethod('ShouldDismissNotificationOnActivity', [Reflection.BindingFlags]'NonPublic,Static')
if (-not $activityDismissMethod.Invoke($null, @($true, $permissionKind)) -or
    -not $activityDismissMethod.Invoke($null, @($true, $completedKind)) -or
    -not $activityDismissMethod.Invoke($null, @($true, $rateLimitedKind)) -or
    -not $activityDismissMethod.Invoke($null, @($true, $errorKind)) -or
    $activityDismissMethod.Invoke($null, @($true, $unknownKind)) -or
    $activityDismissMethod.Invoke($null, @($false, $permissionKind))) {
    throw 'Claude activity did not replace persistent notifications with the working state.'
}
$ignoreWhileRunningMethod = $petWindowType.GetMethod('ShouldIgnoreNotificationWhileRunning', [Reflection.BindingFlags]'NonPublic,Static')
$oldNotificationAt = [DateTime]::Parse('2026-08-27T02:13:45.831+08:00')
$newTaskAt = [DateTime]::Parse('2026-08-27T02:13:45.871+08:00')
$currentErrorAt = [DateTime]::Parse('2026-08-27T02:14:45.871+08:00')
if (-not $ignoreWhileRunningMethod.Invoke($null, @($true, $completedKind, $oldNotificationAt, $newTaskAt)) -or
    -not $ignoreWhileRunningMethod.Invoke($null, @($true, $rateLimitedKind, $oldNotificationAt, $newTaskAt)) -or
    -not $ignoreWhileRunningMethod.Invoke($null, @($true, $errorKind, $oldNotificationAt, $newTaskAt)) -or
    -not $ignoreWhileRunningMethod.Invoke($null, @($true, $permissionKind, $oldNotificationAt, $newTaskAt)) -or
    $ignoreWhileRunningMethod.Invoke($null, @($true, $rateLimitedKind, $currentErrorAt, $newTaskAt)) -or
    $ignoreWhileRunningMethod.Invoke($null, @($false, $rateLimitedKind, $oldNotificationAt, $newTaskAt))) {
    throw 'Claude timestamp precedence rules for queued turns were incorrect.'
}
Write-Host 'PASS hidden idle status reopens for Claude activity'
Write-Host 'PASS completion, permission and error notifications remain until explicit dismissal'
Write-Host 'PASS completion and error notifications close when Claude returns to foreground'
Write-Host 'PASS resumed Claude activity replaces persistent notifications'
Write-Host 'PASS stale notifications from a previous queued turn are ignored'

$selectSpriteRowMethod = $petWindowType.GetMethod('SelectSpriteRow', [Reflection.BindingFlags]'NonPublic,Static')
if ([int]$selectSpriteRowMethod.Invoke($null, @($false, $true, $false, $unknownKind)) -ne 2 -or
    [int]$selectSpriteRowMethod.Invoke($null, @($false, $false, $true, $permissionKind)) -ne 5 -or
    [int]$selectSpriteRowMethod.Invoke($null, @($false, $false, $true, $rateLimitedKind)) -ne 8 -or
    [int]$selectSpriteRowMethod.Invoke($null, @($false, $false, $true, $errorKind)) -ne 8 -or
    [int]$selectSpriteRowMethod.Invoke($null, @($false, $false, $true, $completedKind)) -ne 3) {
    throw 'Claude states were not mapped to the requested Reimu animation rows.'
}
Write-Host 'PASS Claude states use left-running, kneeling and thinking animation rows'

$frameCountsField = $petWindowType.GetField('SpriteFrameCounts', [Reflection.BindingFlags]'NonPublic,Static')
$frameDurationsField = $petWindowType.GetField('SpriteFrameDurations', [Reflection.BindingFlags]'NonPublic,Static')
$frameCounts = [int[]]$frameCountsField.GetValue($null)
$frameDurations = $frameDurationsField.GetValue($null)
$workingDurations = [int[]]$frameDurations[2]
if ($frameCounts[2] -ne 8 -or $frameCounts[5] -ne 8 -or $frameCounts[8] -ne 6) {
    throw 'One of the working, permission or error animation rows uses the wrong frame count.'
}
if (@($workingDurations | Where-Object { $_ -ne 120 }).Count -ne 0) {
    throw 'The working animation must keep an even cadence without a pause at the loop boundary.'
}
Write-Host 'PASS working, permission and error animations use complete loops'
Write-Host 'PASS working animation keeps an even frame cadence'

$testRoot = Join-Path $projectRoot 'tests\tmp-hook-test'
$settingsPath = Join-Path $testRoot '.claude\settings.json'
$transcriptPath = Join-Path $testRoot 'transcript.jsonl'
$eventDirectory = Join-Path $testRoot 'events'
$bridgeProcess = $null

try {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath), $eventDirectory -Force | Out-Null
    [IO.File]::WriteAllText($settingsPath, '{"model":"sonnet"}', (New-Object Text.UTF8Encoding($false)))

    $installerOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -HookScriptPath $hook -SettingsPath $settingsPath
    if ($LASTEXITCODE -ne 0) {
        throw "Claude hook installer failed: $installerOutput"
    }
    $installed = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    foreach ($eventName in @('UserPromptSubmit', 'Stop', 'PermissionRequest', 'Notification')) {
        if ($null -eq $installed.hooks.PSObject.Properties[$eventName] -or @($installed.hooks.$eventName).Count -lt 1) {
            throw "Claude hook installer did not add $eventName."
        }
    }

    $userEntry = @{ type = 'user'; cwd = $projectRoot; message = @{ role = 'user'; content = 'fix tests' } } | ConvertTo-Json -Compress -Depth 8
    $assistantEntry = @{ type = 'assistant'; message = @{ role = 'assistant'; content = @() }; isApiErrorMessage = $true; apiErrorStatus = 429; error = 'API Error: 429 Too Many Requests' } | ConvertTo-Json -Compress -Depth 8
    [IO.File]::WriteAllLines($transcriptPath, @($userEntry), (New-Object Text.UTF8Encoding($false)))

    $bridgeInfo = New-Object System.Diagnostics.ProcessStartInfo
    $bridgeInfo.FileName = 'powershell.exe'
    $bridgeInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ParentProcessId {1} -EventDirectory "{2}" -TranscriptDirectory "{3}"' -f $bridge, $PID, $eventDirectory, $testRoot
    $bridgeInfo.UseShellExecute = $false
    $bridgeInfo.CreateNoWindow = $true
    $bridgeInfo.RedirectStandardOutput = $true
    $bridgeInfo.RedirectStandardError = $true
    $bridgeProcess = New-Object System.Diagnostics.Process
    $bridgeProcess.StartInfo = $bridgeInfo
    [void]$bridgeProcess.Start()

    $readyTask = $bridgeProcess.StandardOutput.ReadLineAsync()
    if (-not $readyTask.Wait(5000) -or $readyTask.Result -notmatch '"status":"ready"') {
        throw 'Claude hook bridge did not become ready.'
    }

    [IO.File]::AppendAllText($transcriptPath, $assistantEntry + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $eventTask = $bridgeProcess.StandardOutput.ReadLineAsync()
    if (-not $eventTask.Wait(5000)) {
        throw 'Claude transcript 429 was not delivered immediately by the bridge.'
    }
    $transcriptEvent = $eventTask.Result | ConvertFrom-Json
    if ($transcriptEvent.title -notmatch '429' -or $transcriptEvent.body -notmatch 'Too Many Requests') {
        throw 'Claude transcript monitor did not capture the 429 error details.'
    }

    $hookEventDirectory = Join-Path $testRoot 'hook-events'
    New-Item -ItemType Directory -Path $hookEventDirectory -Force | Out-Null
    $payload = @{ hook_event_name = 'Stop'; transcript_path = $transcriptPath; cwd = $projectRoot } | ConvertTo-Json -Compress
    $hookInfo = New-Object System.Diagnostics.ProcessStartInfo
    $hookInfo.FileName = 'powershell.exe'
    $hookInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -EventDirectory "{1}"' -f $hook, $hookEventDirectory
    $hookInfo.UseShellExecute = $false
    $hookInfo.CreateNoWindow = $true
    $hookInfo.RedirectStandardInput = $true
    $hookProcess = New-Object System.Diagnostics.Process
    $hookProcess.StartInfo = $hookInfo
    try {
        [void]$hookProcess.Start()
        $hookProcess.StandardInput.Write($payload)
        $hookProcess.StandardInput.Close()
        $hookProcess.WaitForExit(5000) | Out-Null
        if (-not $hookProcess.HasExited -or $hookProcess.ExitCode -ne 0) {
            throw 'Claude 429 hook fixture failed.'
        }
    }
    finally {
        if ($hookProcess) { $hookProcess.Dispose() }
    }

    $hookEvents = @(Get-ChildItem -LiteralPath $hookEventDirectory -Filter '*.json' -File |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    $hookEventFile = @($hookEvents | Where-Object { $_.type -eq 'notification' }) | Select-Object -First 1
    $idleHookEvent = @($hookEvents | Where-Object { $_.type -eq 'activity' -and $_.activity -eq 'idle' }) | Select-Object -First 1
    if ($null -eq $hookEventFile) {
        throw 'Claude 429 hook did not write an event file.'
    }
    if ($null -eq $idleHookEvent) {
        throw 'Claude Stop hook did not reset the working animation state.'
    }
    $hookEvent = $hookEventFile
    if ($hookEvent.title -notmatch '429' -or $hookEvent.body -notmatch 'Too Many Requests') {
        throw 'Claude hook did not capture the 429 error details.'
    }

    $genericUserEntry = @{ type = 'user'; cwd = $projectRoot; message = @{ role = 'user'; content = 'run generic error test' } } | ConvertTo-Json -Compress -Depth 8
    $genericErrorEntry = @{ type = 'assistant'; uuid = 'generic-error-fixture'; message = @{ role = 'assistant'; content = @() }; isApiErrorMessage = $true; apiErrorStatus = 500; error = 'Internal server error' } | ConvertTo-Json -Compress -Depth 8
    [IO.File]::AppendAllText($transcriptPath, $genericUserEntry + [Environment]::NewLine + $genericErrorEntry + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $genericWorkingTask = $bridgeProcess.StandardOutput.ReadLineAsync()
    if (-not $genericWorkingTask.Wait(5000)) {
        throw 'Claude transcript user prompt did not start the working state.'
    }
    $genericWorkingEvent = $genericWorkingTask.Result | ConvertFrom-Json
    if ($genericWorkingEvent.type -ne 'activity' -or $genericWorkingEvent.activity -ne 'working') {
        throw 'Claude transcript user prompt was not mapped to working activity.'
    }
    $genericEventTask = $bridgeProcess.StandardOutput.ReadLineAsync()
    if (-not $genericEventTask.Wait(5000)) {
        throw 'Claude transcript generic error was not delivered immediately by the bridge.'
    }
    $genericEvent = $genericEventTask.Result | ConvertFrom-Json
    if ($genericEvent.title -notmatch 'error' -or $genericEvent.body -notmatch '500|Internal server error') {
        throw 'Claude transcript monitor did not capture the generic error details.'
    }

    $completedUserEntry = @{ type = 'user'; uuid = 'completed-turn-fixture'; message = @{ role = 'user'; content = 'finish normally' } } | ConvertTo-Json -Compress -Depth 8
    $stopSummaryEntry = @{ type = 'system'; subtype = 'stop_hook_summary'; uuid = 'stop-summary-fixture'; timestamp = [DateTime]::Now.ToString('o') } | ConvertTo-Json -Compress -Depth 8
    [IO.File]::AppendAllText($transcriptPath, $completedUserEntry + [Environment]::NewLine + $stopSummaryEntry + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $workingFallbackTask = $bridgeProcess.StandardOutput.ReadLineAsync()
    if (-not $workingFallbackTask.Wait(5000)) {
        throw 'Claude transcript working fallback was not delivered.'
    }
    $workingFallback = $workingFallbackTask.Result | ConvertFrom-Json
    if ($workingFallback.type -ne 'activity' -or $workingFallback.activity -ne 'working') {
        throw 'Claude transcript working fallback was incorrect.'
    }
    $idleEventTask = $bridgeProcess.StandardOutput.ReadLineAsync()
    if (-not $idleEventTask.Wait(5000)) {
        throw 'Claude transcript stop summary did not reset the working state.'
    }
    $idleEvent = $idleEventTask.Result | ConvertFrom-Json
    if ($idleEvent.type -ne 'activity' -or $idleEvent.activity -ne 'idle') {
        throw 'Claude transcript stop summary was not mapped to idle activity.'
    }
    $completedEventTask = $bridgeProcess.StandardOutput.ReadLineAsync()
    if (-not $completedEventTask.Wait(5000)) {
        throw 'Claude transcript stop summary did not deliver completion.'
    }
    $completedEvent = $completedEventTask.Result | ConvertFrom-Json
    if ($completedEvent.title -notmatch 'completed' -or $completedEvent.eventId -ne 'turn-completed-turn-fixture') {
        throw 'Claude transcript stop summary completion fallback was incorrect.'
    }

    $modelCaveatEntry = @{ type = 'user'; uuid = 'model-caveat-fixture'; isMeta = $true; message = @{ role = 'user'; content = '<local-command-caveat>local command</local-command-caveat>' } } | ConvertTo-Json -Compress -Depth 8
    $modelCommandEntry = @{ type = 'user'; uuid = 'model-command-fixture'; message = @{ role = 'user'; content = '<command-name>/model</command-name>`n<command-args>sonnet</command-args>' } } | ConvertTo-Json -Compress -Depth 8
    $modelOutputEntry = @{ type = 'user'; uuid = 'model-output-fixture'; message = @{ role = 'user'; content = '<local-command-stdout>Set model to sonnet</local-command-stdout>' } } | ConvertTo-Json -Compress -Depth 8
    $afterModelEntry = @{ type = 'user'; uuid = 'after-model-fixture'; message = @{ role = 'user'; content = 'run a real task' } } | ConvertTo-Json -Compress -Depth 8
    [IO.File]::AppendAllText(
        $transcriptPath,
        ($modelCaveatEntry, $modelCommandEntry, $modelOutputEntry, $afterModelEntry -join [Environment]::NewLine) + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false)))
    $afterModelTask = $bridgeProcess.StandardOutput.ReadLineAsync()
    if (-not $afterModelTask.Wait(5000)) {
        throw 'Claude transcript did not resume working after /model.'
    }
    $afterModelEvent = $afterModelTask.Result | ConvertFrom-Json
    if ($afterModelEvent.type -ne 'activity' -or
        $afterModelEvent.activity -ne 'working' -or
        $afterModelEvent.eventId -ne 'working-after-model-fixture') {
        throw 'Claude transcript treated /model metadata as working activity.'
    }

    $activityEventDirectory = Join-Path $testRoot 'activity-events'
    New-Item -ItemType Directory -Path $activityEventDirectory -Force | Out-Null
    $activityPayload = @{ hook_event_name = 'UserPromptSubmit'; transcript_path = $transcriptPath; cwd = $projectRoot } | ConvertTo-Json -Compress
    $activityInfo = New-Object System.Diagnostics.ProcessStartInfo
    $activityInfo.FileName = 'powershell.exe'
    $activityInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -EventDirectory "{1}"' -f $hook, $activityEventDirectory
    $activityInfo.UseShellExecute = $false
    $activityInfo.CreateNoWindow = $true
    $activityInfo.RedirectStandardInput = $true
    $activityProcess = New-Object System.Diagnostics.Process
    $activityProcess.StartInfo = $activityInfo
    try {
        [void]$activityProcess.Start()
        $activityProcess.StandardInput.Write($activityPayload)
        $activityProcess.StandardInput.Close()
        $activityProcess.WaitForExit(5000) | Out-Null
        if (-not $activityProcess.HasExited -or $activityProcess.ExitCode -ne 0) {
            throw 'Claude activity hook fixture failed.'
        }
    }
    finally {
        if ($activityProcess) { $activityProcess.Dispose() }
    }

    $activityEventFile = Get-ChildItem -LiteralPath $activityEventDirectory -Filter '*.json' -File | Select-Object -First 1
    if ($null -eq $activityEventFile) {
        throw 'Claude activity hook did not write an event file.'
    }
    $activityEvent = Get-Content -LiteralPath $activityEventFile.FullName -Raw | ConvertFrom-Json
    if ($activityEvent.type -ne 'activity' -or $activityEvent.activity -ne 'working') {
        throw 'Claude user prompt was not mapped to working activity.'
    }

    $modelEventDirectory = Join-Path $testRoot 'model-events'
    New-Item -ItemType Directory -Path $modelEventDirectory -Force | Out-Null
    $modelPayload = @{ hook_event_name = 'UserPromptSubmit'; prompt = '<command-name>/model</command-name>`n<command-args>sonnet</command-args>'; transcript_path = $transcriptPath; cwd = $projectRoot } | ConvertTo-Json -Compress
    $modelInfo = New-Object System.Diagnostics.ProcessStartInfo
    $modelInfo.FileName = 'powershell.exe'
    $modelInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -EventDirectory "{1}"' -f $hook, $modelEventDirectory
    $modelInfo.UseShellExecute = $false
    $modelInfo.CreateNoWindow = $true
    $modelInfo.RedirectStandardInput = $true
    $modelProcess = New-Object System.Diagnostics.Process
    $modelProcess.StartInfo = $modelInfo
    try {
        [void]$modelProcess.Start()
        $modelProcess.StandardInput.Write($modelPayload)
        $modelProcess.StandardInput.Close()
        $modelProcess.WaitForExit(5000) | Out-Null
        if (-not $modelProcess.HasExited -or $modelProcess.ExitCode -ne 0) {
            throw 'Claude /model hook fixture failed.'
        }
    }
    finally {
        if ($modelProcess) { $modelProcess.Dispose() }
    }
    if (@(Get-ChildItem -LiteralPath $modelEventDirectory -Filter '*.json' -File).Count -ne 0) {
        throw 'Claude /model did not stay out of the working state.'
    }
    $modelRawEventDirectory = Join-Path $testRoot 'model-raw-events'
    New-Item -ItemType Directory -Path $modelRawEventDirectory -Force | Out-Null
    $modelRawPayload = @{ hook_event_name = 'UserPromptSubmit'; transcript_path = $transcriptPath; cwd = $projectRoot; command_name = '/model' } | ConvertTo-Json -Compress
    $modelRawInfo = New-Object System.Diagnostics.ProcessStartInfo
    $modelRawInfo.FileName = 'powershell.exe'
    $modelRawInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -EventDirectory "{1}"' -f $hook, $modelRawEventDirectory
    $modelRawInfo.UseShellExecute = $false
    $modelRawInfo.CreateNoWindow = $true
    $modelRawInfo.RedirectStandardInput = $true
    $modelRawProcess = New-Object System.Diagnostics.Process
    $modelRawProcess.StartInfo = $modelRawInfo
    try {
        [void]$modelRawProcess.Start()
        $modelRawProcess.StandardInput.Write($modelRawPayload)
        $modelRawProcess.StandardInput.Close()
        $modelRawProcess.WaitForExit(5000) | Out-Null
        if (-not $modelRawProcess.HasExited -or $modelRawProcess.ExitCode -ne 0) {
            throw 'Claude /model raw hook fixture failed.'
        }
    }
    finally {
        if ($modelRawProcess) { $modelRawProcess.Dispose() }
    }
    if (@(Get-ChildItem -LiteralPath $modelRawEventDirectory -Filter '*.json' -File).Count -ne 0) {
        throw 'Claude /model command_name did not stay out of the working state.'
    }
    Write-Host 'PASS Claude /model does not start the working animation'

    $diagnosticInfo = New-Object System.Diagnostics.ProcessStartInfo
    $diagnosticInfo.FileName = 'powershell.exe'
    $diagnosticInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -EventDirectory "{1}"' -f $hook, $hookEventDirectory
    $diagnosticInfo.UseShellExecute = $false
    $diagnosticInfo.CreateNoWindow = $true
    $diagnosticInfo.RedirectStandardInput = $true
    $diagnosticInfo.RedirectStandardError = $true
    $diagnosticProcess = New-Object System.Diagnostics.Process
    $diagnosticProcess.StartInfo = $diagnosticInfo
    try {
        [void]$diagnosticProcess.Start()
        $diagnosticProcess.StandardInput.Write('{invalid-json')
        $diagnosticProcess.StandardInput.Close()
        $diagnosticProcess.WaitForExit(5000) | Out-Null
        $diagnosticError = $diagnosticProcess.StandardError.ReadToEnd()
        if (-not $diagnosticProcess.HasExited -or $diagnosticProcess.ExitCode -ne 0) {
            throw 'Claude hook exposed an internal notification failure to Claude CLI.'
        }
        if (-not [string]::IsNullOrWhiteSpace($diagnosticError)) {
            throw 'Claude hook wrote an internal notification failure to stderr.'
        }
    }
    finally {
        if ($diagnosticProcess) { $diagnosticProcess.Dispose() }
    }

    $hookLogPath = Join-Path (Split-Path -Parent $hook) 'ReimuWatch.log'
    if (-not (Test-Path -LiteralPath $hookLogPath) -or
        [IO.File]::ReadAllText($hookLogPath) -notmatch 'Claude Hook error:') {
        throw 'Claude hook did not preserve its hidden failure in the diagnostic log.'
    }

    Write-Host 'PASS Claude hooks installer adds required events'
    Write-Host 'PASS Claude user prompt starts the working animation state'
    Write-Host 'PASS Claude transcript starts the working animation when the hook is missed'
    Write-Host 'PASS Claude transcript ignores /model command metadata'
    Write-Host 'PASS Claude Stop events always reset the working animation state'
    Write-Host 'PASS Claude transcript stop summary provides completion fallback'
    Write-Host 'PASS Claude transcript monitor delivers 429 immediately'
    Write-Host 'PASS Claude 429 hook captures the actual error details'
    Write-Host 'PASS Claude transcript monitor delivers generic errors immediately'
    Write-Host 'PASS Claude hook bridge remains active without Windows notification permission'
    Write-Host 'PASS Claude hook failures stay hidden and are written to ReimuWatch.log'
}
finally {
    if ($bridgeProcess -and -not $bridgeProcess.HasExited) {
        $bridgeProcess.Kill()
        $bridgeProcess.WaitForExit()
    }
    if ($bridgeProcess) {
        $bridgeProcess.Dispose()
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
