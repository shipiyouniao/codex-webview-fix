[CmdletBinding()]
param(
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

function Read-Utf8Text {
    param([string]$Path)

    return [System.IO.File]::ReadAllText($Path, $utf8Strict)
}

$backupRootBase = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }
$backupRoot = Join-Path $backupRootBase 'CodexWebviewReadinessFix\backups'

if (-not $BackupPath) {
    $manifestFile = Get-ChildItem -LiteralPath $backupRoot -Filter 'manifest.json' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $manifestFile) {
        throw "No backup manifest was found under: $backupRoot"
    }
} else {
    $resolved = (Resolve-Path -LiteralPath $BackupPath).Path
    $manifestFile = if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
        Get-Item -LiteralPath (Join-Path $resolved 'manifest.json')
    } else {
        Get-Item -LiteralPath $resolved
    }
}

$manifest = Read-Utf8Text -Path $manifestFile.FullName | ConvertFrom-Json
$extensionRoot = [System.IO.Path]::GetFullPath([string]$manifest.extensionPath)
$packagePath = Join-Path $extensionRoot 'package.json'
if (-not (Test-Path -LiteralPath $packagePath)) {
    throw "The extension recorded in the backup no longer exists: $extensionRoot"
}
$package = Read-Utf8Text -Path $packagePath | ConvertFrom-Json
if ($package.publisher -ne 'openai' -or $package.name -ne 'chatgpt') {
    throw "The backup does not point to an openai.chatgpt extension: $extensionRoot"
}
$extensionPrefix = $extensionRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$backupDirectoryRoot = [System.IO.Path]::GetFullPath($manifestFile.DirectoryName)
$backupPrefix = $backupDirectoryRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
foreach ($file in $manifest.files) {
    $originalPath = [System.IO.Path]::GetFullPath([string]$file.original)
    $backupPath = [System.IO.Path]::GetFullPath([string]$file.backup)
    if (-not $originalPath.StartsWith($extensionPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to restore a file outside the extension directory: $originalPath"
    }
    if (-not $backupPath.StartsWith($backupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to read a backup outside the selected backup directory: $backupPath"
    }
    if (-not (Test-Path -LiteralPath $backupPath)) {
        throw "Backup file is missing: $backupPath"
    }
    $parent = Split-Path -Parent $originalPath
    if (-not (Test-Path -LiteralPath $parent)) {
        throw "The original extension directory no longer exists: $parent"
    }
}

foreach ($directory in @($manifest.directories)) {
    if (-not $directory) {
        continue
    }
    $fullDirectory = [System.IO.Path]::GetFullPath([string]$directory)
    $webviewRoot = [System.IO.Path]::GetFullPath((Join-Path $extensionRoot 'webview'))
    $expectedPrefix = $webviewRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullDirectory.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $fullDirectory).StartsWith('assets-cache-bust-', [System.StringComparison]::Ordinal)) {
        throw "Refusing to remove an unexpected generated directory: $fullDirectory"
    }
}

foreach ($file in $manifest.files) {
    Copy-Item -LiteralPath $file.backup -Destination $file.original -Force
}

foreach ($directory in @($manifest.directories)) {
    if ($directory -and (Test-Path -LiteralPath $directory)) {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

Write-Host "Restored openai.chatgpt $($manifest.extensionVersion)"
Write-Host "Backup: $($manifestFile.DirectoryName)"
Write-Host 'Restart VS Code or run Developer: Reload Window.'
