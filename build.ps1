[CmdletBinding()]
param(
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputDir = Join-Path $projectRoot 'build'
$outputExe = Join-Path $outputDir 'ReimuWatch.exe'
$outputIcon = Join-Path $outputDir 'ReimuWatch.ico'
$sourceFile = Join-Path $projectRoot 'src\NotifyPet.cs'
$bridgeFile = Join-Path $projectRoot 'src\NotificationBridge.ps1'
$claudeHookFile = Join-Path $projectRoot 'src\ClaudeHook.ps1'
$hookInstallerFile = Join-Path $projectRoot 'src\InstallClaudeHooks.ps1'
$spriteAsset = Join-Path $projectRoot 'assets\custom-spritesheet.png'
$manifestFile = Join-Path $projectRoot 'app.manifest'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$winMetadata = Join-Path $env:WINDIR 'System32\WinMetadata'
$gacMsil = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL'
$gac64 = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_64'

if ($Clean -and (Test-Path -LiteralPath $outputDir)) {
    Remove-Item -LiteralPath $outputDir -Recurse -Force
}

foreach ($required in @($csc, $sourceFile, $bridgeFile, $claudeHookFile, $hookInstallerFile, $spriteAsset, $manifestFile)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required file not found: $required"
    }
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Add-Type -AssemblyName System.Drawing
$sourceBitmap = New-Object System.Drawing.Bitmap -ArgumentList $spriteAsset
$iconBitmap = New-Object System.Drawing.Bitmap -ArgumentList 64, 64
$iconGraphics = [Drawing.Graphics]::FromImage($iconBitmap)
try {
    $iconGraphics.Clear([Drawing.Color]::Transparent)
    $iconGraphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
    $iconGraphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $iconGraphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
    $sourceRectangle = New-Object Drawing.Rectangle -ArgumentList 30, 0, 132, 132
    $targetRectangle = New-Object Drawing.Rectangle -ArgumentList 2, 2, 60, 60
    $iconGraphics.DrawImage(
        $sourceBitmap,
        $targetRectangle,
        $sourceRectangle,
        [Drawing.GraphicsUnit]::Pixel)
    $iconHandle = $iconBitmap.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($iconHandle)
    $iconStream = [IO.File]::Create($outputIcon)
    try {
        $icon.Save($iconStream)
    }
    finally {
        $iconStream.Dispose()
        $icon.Dispose()
    }
}
finally {
    $iconGraphics.Dispose()
    $iconBitmap.Dispose()
    $sourceBitmap.Dispose()
}

$references = @(
    (Join-Path $framework 'System.dll'),
    (Join-Path $framework 'System.Core.dll'),
    (Join-Path $framework 'System.Drawing.dll'),
    (Join-Path $framework 'System.Runtime.Serialization.dll'),
    (Join-Path $framework 'System.Windows.Forms.dll'),
    (Join-Path $gacMsil 'WindowsBase\v4.0_4.0.0.0__31bf3856ad364e35\WindowsBase.dll'),
    (Join-Path $gac64 'PresentationCore\v4.0_4.0.0.0__31bf3856ad364e35\PresentationCore.dll'),
    (Join-Path $gacMsil 'PresentationFramework\v4.0_4.0.0.0__31bf3856ad364e35\PresentationFramework.dll'),
    (Join-Path $gacMsil 'System.Xaml\v4.0_4.0.0.0__b77a5c561934e089\System.Xaml.dll'),
    (Join-Path $gacMsil 'UIAutomationClient\v4.0_4.0.0.0__31bf3856ad364e35\UIAutomationClient.dll'),
    (Join-Path $gacMsil 'UIAutomationTypes\v4.0_4.0.0.0__31bf3856ad364e35\UIAutomationTypes.dll')
)

$arguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/debug-',
    '/codepage:65001',
    "/out:$outputExe",
    "/win32icon:$outputIcon",
    "/win32manifest:$manifestFile"
)

foreach ($reference in $references) {
    $arguments += "/reference:$reference"
}
$arguments += $sourceFile

& $csc $arguments
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE"
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText(
    (Join-Path $outputDir 'NotificationBridge.ps1'),
    [IO.File]::ReadAllText($bridgeFile),
    $utf8Bom)
[IO.File]::WriteAllText(
    (Join-Path $outputDir 'ClaudeHook.ps1'),
    [IO.File]::ReadAllText($claudeHookFile),
    $utf8Bom)
[IO.File]::WriteAllText(
    (Join-Path $outputDir 'InstallClaudeHooks.ps1'),
    [IO.File]::ReadAllText($hookInstallerFile),
    $utf8Bom)
New-Item -ItemType Directory -Path (Join-Path $outputDir 'assets') -Force | Out-Null
Copy-Item -LiteralPath $spriteAsset -Destination (Join-Path $outputDir 'assets\custom-spritesheet.png') -Force

Write-Host "Built $outputExe"
