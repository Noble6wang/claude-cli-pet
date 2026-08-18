[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HookScriptPath,
    [string]$SettingsPath = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
}

function Test-NotifyPetHookGroup {
    param($Group)
    foreach ($hook in @($Group.hooks)) {
        $command = [string]$hook.command
        if ($command -match '(?i)NotifyPet.*ClaudeHook\.ps1|ClaudeHook\.ps1') {
            return $true
        }
    }
    return $false
}

try {
    if (-not (Test-Path -LiteralPath $HookScriptPath)) {
        throw 'Claude hook script not found: ' + $HookScriptPath
    }

    $settingsFolder = Split-Path -Parent $SettingsPath
    [IO.Directory]::CreateDirectory($settingsFolder) | Out-Null
    if (Test-Path -LiteralPath $SettingsPath) {
        $raw = [IO.File]::ReadAllText($SettingsPath)
        $settings = if ([string]::IsNullOrWhiteSpace($raw)) { [pscustomobject]@{} } else { $raw | ConvertFrom-Json }
        Copy-Item -LiteralPath $SettingsPath -Destination ($SettingsPath + '.notify-pet.bak') -Force
    }
    else {
        $settings = [pscustomobject]@{}
    }

    if ($null -eq $settings.PSObject.Properties['hooks']) {
        $settings | Add-Member -MemberType NoteProperty -Name hooks -Value ([pscustomobject]@{})
    }

    $safeHookPath = $HookScriptPath.Replace('"', '\"')
    $command = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $safeHookPath + '"'
    foreach ($eventName in @('UserPromptSubmit', 'Stop', 'PermissionRequest', 'Notification')) {
        $groups = New-Object 'System.Collections.Generic.List[object]'
        $property = $settings.hooks.PSObject.Properties[$eventName]
        if ($null -ne $property) {
            foreach ($group in @($property.Value)) {
                if (-not (Test-NotifyPetHookGroup $group)) {
                    $groups.Add($group)
                }
            }
        }

        $groups.Add([pscustomobject]@{
            matcher = ''
            hooks = @(
                [pscustomobject]@{
                    type = 'command'
                    command = $command
                    timeout = 10
                    statusMessage = 'NotifyPet'
                }
            )
        })

        if ($null -eq $property) {
            $settings.hooks | Add-Member -MemberType NoteProperty -Name $eventName -Value $groups.ToArray()
        }
        else {
            $settings.hooks.$eventName = $groups.ToArray()
        }
    }

    $json = $settings | ConvertTo-Json -Depth 32
    $tempPath = $SettingsPath + '.notify-pet.tmp'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($tempPath, $json, $utf8)
    Move-Item -LiteralPath $tempPath -Destination $SettingsPath -Force
    [Console]::Out.WriteLine((@{ type = 'installed'; settingsPath = $SettingsPath } | ConvertTo-Json -Compress))
    exit 0
}
catch {
    [Console]::Out.WriteLine((@{ type = 'error'; message = $_.Exception.Message } | ConvertTo-Json -Compress))
    exit 1
}
