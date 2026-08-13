[CmdletBinding()]
param(
    [string]$ExtensionPath,
    [switch]$ResetAssetGraph
)

$ErrorActionPreference = 'Stop'
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

function Read-Utf8Text {
    param([string]$Path)

    return [System.IO.File]::ReadAllText($Path, $utf8Strict)
}

function Get-CodexExtension {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        $resolved = (Resolve-Path -LiteralPath $ExplicitPath).Path
        $packagePath = Join-Path $resolved 'package.json'
        if (-not (Test-Path -LiteralPath $packagePath)) {
            throw "package.json was not found under: $resolved"
        }
        $package = Read-Utf8Text -Path $packagePath | ConvertFrom-Json
        if ($package.publisher -ne 'openai' -or $package.name -ne 'chatgpt') {
            throw "The selected directory is not the openai.chatgpt extension: $resolved"
        }
        return [pscustomobject]@{ Path = $resolved; Package = $package }
    }

    $roots = @()
    if ($env:VSCODE_EXTENSIONS) {
        $roots += $env:VSCODE_EXTENSIONS
    }
    if ($env:USERPROFILE) {
        $roots += (Join-Path $env:USERPROFILE '.vscode\extensions')
        $roots += (Join-Path $env:USERPROFILE '.vscode-insiders\extensions')
        $roots += (Join-Path $env:USERPROFILE '.positron\extensions')
    }

    $candidates = foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $activeLocations = @{}
        $registryPath = Join-Path $root 'extensions.json'
        if (Test-Path -LiteralPath $registryPath) {
            try {
                foreach ($entry in (Read-Utf8Text -Path $registryPath | ConvertFrom-Json)) {
                    if ($entry.identifier.id -eq 'openai.chatgpt') {
                        $locationPath = $entry.location.fsPath
                        if (-not $locationPath) {
                            $locationPath = $entry.location.path
                        }
                        if ($locationPath) {
                            if ($locationPath -match '^/[A-Za-z]:/') {
                                $locationPath = $locationPath.Substring(1)
                            }
                            $normalized = [System.IO.Path]::GetFullPath($locationPath.Replace('/', '\'))
                            $activeLocations[$normalized.ToLowerInvariant()] = $entry.metadata.installedTimestamp
                        }
                    }
                }
            } catch {
                throw "Could not read the VS Code extension registry: $registryPath"
            }
        }
        foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $packagePath = Join-Path $directory.FullName 'package.json'
            if (-not (Test-Path -LiteralPath $packagePath)) {
                continue
            }
            try {
                $package = Read-Utf8Text -Path $packagePath | ConvertFrom-Json
            } catch {
                continue
            }
            if ($package.publisher -eq 'openai' -and $package.name -eq 'chatgpt') {
                $normalizedDirectory = [System.IO.Path]::GetFullPath($directory.FullName)
                $activeKey = $normalizedDirectory.ToLowerInvariant()
                [pscustomobject]@{
                    Path = $directory.FullName
                    Package = $package
                    IsActive = $activeLocations.ContainsKey($activeKey)
                    InstalledTimestamp = if ($activeLocations.ContainsKey($activeKey)) {
                        [int64]$activeLocations[$activeKey]
                    } else {
                        [int64]0
                    }
                }
            }
        }
    }

    if (-not $candidates) {
        throw 'No installed openai.chatgpt extension was found. Pass -ExtensionPath explicitly.'
    }
    $active = @($candidates | Where-Object IsActive | Sort-Object InstalledTimestamp -Descending)
    if ($active.Count -gt 1) {
        $paths = ($active.Path | ForEach-Object { "  $_" }) -join [Environment]::NewLine
        throw "Multiple active openai.chatgpt installations were found. Re-run with -ExtensionPath and choose one:`n$paths"
    }
    $selected = if ($active.Count -eq 1) {
        $active[0]
    } elseif ($candidates.Count -eq 1) {
        $candidates[0]
    } else {
        $paths = ($candidates.Path | ForEach-Object { "  $_" }) -join [Environment]::NewLine
        throw "Multiple unregistered openai.chatgpt directories were found. Re-run with -ExtensionPath and choose one:`n$paths"
    }
    return [pscustomobject]@{ Path = $selected.Path; Package = $selected.Package }
}

function Get-UniqueFileContaining {
    param(
        [string]$Directory,
        [string]$Filter,
        [string]$Needle
    )

    $matches = @(
        Get-ChildItem -LiteralPath $Directory -File -Filter $Filter |
            Where-Object { (Read-Utf8Text -Path $_.FullName).Contains($Needle) }
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Filter file containing '$Needle'; found $($matches.Count). No files were changed."
    }
    return $matches[0]
}

function Get-ReadinessPatch {
    param([string]$AssetsDirectory)

    $mainFile = Get-UniqueFileContaining -Directory $AssetsDirectory -Filter 'app-main-*.js' -Needle 'React root render requested'
    $routeFile = Get-UniqueFileContaining -Directory $AssetsDirectory -Filter 'app-initial-*.js' -Needle 'app routes mounted after'
    $mainText = Read-Utf8Text -Path $mainFile.FullName
    $routeText = Read-Utf8Text -Path $routeFile.FullName

    $runtimeMarker = '[startup][renderer] webview runtime ready'
    $routeReadyPattern = '(?<channel>[A-Za-z_$][A-Za-z0-9_$]*)\.dispatchMessage\(`ready`,\{\}\)'
    $routeReadyMatches = [regex]::Matches($routeText, $routeReadyPattern)
    if ($mainText.Contains($runtimeMarker)) {
        if ($routeReadyMatches.Count -gt 0) {
            throw 'The runtime-ready patch is present, but a delayed ready dispatch also remains. Refusing to guess at a partially modified bundle.'
        }
        return [pscustomobject]@{
            Changed = $false
            MainFile = $mainFile
            RouteFile = $routeFile
            MainText = $mainText
            RouteText = $routeText
        }
    }
    if ($routeReadyMatches.Count -ne 1) {
        throw "Expected exactly one delayed ready dispatch; found $($routeReadyMatches.Count). No files were changed."
    }

    $mainChannelPattern = '(?<channel>[A-Za-z_$][A-Za-z0-9_$]*)\.dispatchMessage\(`log-message`,'
    $mainChannelMatches = [regex]::Matches($mainText, $mainChannelPattern)
    if ($mainChannelMatches.Count -lt 1) {
        throw 'Could not identify the webview-to-host message channel in the entry chunk. No files were changed.'
    }
    $mainChannel = $mainChannelMatches[0].Groups['channel'].Value

    $renderMarker = 'React root render requested'
    $renderIndex = $mainText.IndexOf($renderMarker, [System.StringComparison]::Ordinal)
    $insertionIndex = $mainText.IndexOf(');let e=', $renderIndex, [System.StringComparison]::Ordinal)
    if ($renderIndex -lt 0 -or $insertionIndex -lt 0) {
        throw 'Could not locate the validated insertion point after the React root log. No files were changed.'
    }

    $runtimeDispatch = ");$mainChannel.dispatchMessage(``log-message``,{level:``info``,message:``$runtimeMarker``}),$mainChannel.dispatchMessage(``ready``,{});let e="
    $patchedMain = $mainText.Substring(0, $insertionIndex) + $runtimeDispatch + $mainText.Substring($insertionIndex + 8)

    $delayedDispatch = $routeReadyMatches[0].Value
    $delayedIndex = $routeReadyMatches[0].Index
    $prefixLength = if ($delayedIndex -gt 0 -and $routeText[$delayedIndex - 1] -eq ',') { 1 } else { 0 }
    $patchedRoute = $routeText.Remove($delayedIndex - $prefixLength, $delayedDispatch.Length + $prefixLength)

    if (-not $patchedMain.Contains($runtimeMarker) -or $patchedRoute.Contains('dispatchMessage(`ready`,{})')) {
        throw 'Post-patch validation failed. No files were changed.'
    }

    return [pscustomobject]@{
        Changed = $true
        MainFile = $mainFile
        RouteFile = $routeFile
        MainText = $patchedMain
        RouteText = $patchedRoute
    }
}

function Get-CssOnlyEntryPatch {
    param([string]$EntryPath)

    $entryText = Read-Utf8Text -Path $EntryPath
    $dependencyMapMatch = [regex]::Match($entryText, 'm\.f\|\|\(m\.f=\[(?<dependencies>[^\]]+)\]\)')
    if (-not $dependencyMapMatch.Success) {
        throw 'Could not identify the entry dependency map. No files were changed.'
    }

    try {
        $dependencies = ConvertFrom-Json "[$($dependencyMapMatch.Groups['dependencies'].Value)]"
    } catch {
        throw 'Could not parse the entry dependency map. No files were changed.'
    }
    $preloadMatches = [regex]::Matches($entryText, '__vite__mapDeps\(\[(?<indices>[0-9,\s]+)\]\)')
    if ($preloadMatches.Count -ne 1) {
        throw "Expected exactly one dynamic preload list; found $($preloadMatches.Count). No files were changed."
    }

    $cssIndices = @()
    foreach ($rawIndex in ($preloadMatches[0].Groups['indices'].Value -split ',')) {
        $index = [int]$rawIndex.Trim()
        if ($index -lt 0 -or $index -ge $dependencies.Count) {
            throw "Dependency index $index is outside the dependency map. No files were changed."
        }
        if ([string]$dependencies[$index] -match '\.css$') {
            $cssIndices += $index
        }
    }
    if ($cssIndices.Count -eq 0) {
        throw 'The dynamic preload list did not contain any CSS dependencies. No files were changed.'
    }

    $replacement = '__vite__mapDeps([' + ($cssIndices -join ',') + '])'
    $patchedEntry = $entryText.Remove($preloadMatches[0].Index, $preloadMatches[0].Length).Insert($preloadMatches[0].Index, $replacement)
    if ([regex]::Matches($patchedEntry, '__vite__mapDeps\(\[(?<indices>[0-9,\s]+)\]\)').Count -ne 1) {
        throw 'Post-patch entry validation failed. No files were changed.'
    }
    return $patchedEntry
}

function New-BackupDirectory {
    param(
        [object]$Extension,
        [string]$BackupRoot
    )

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $nonce = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $safeVersion = [string]$Extension.Package.version
    $backupDirectory = Join-Path $BackupRoot "$safeVersion-$stamp-$nonce"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    return $backupDirectory
}

$extension = Get-CodexExtension -ExplicitPath $ExtensionPath
$webviewDirectory = Join-Path $extension.Path 'webview'
$assetsDirectory = Join-Path $webviewDirectory 'assets'
if (-not (Test-Path -LiteralPath $assetsDirectory)) {
    throw "Webview assets were not found under: $($extension.Path)"
}
$backupRootBase = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }
$backupRoot = Join-Path $backupRootBase 'CodexWebviewReadinessFix\backups'

$indexPath = Join-Path $webviewDirectory 'index.html'
if (-not (Test-Path -LiteralPath $indexPath)) {
    throw "Webview index was not found under: $webviewDirectory"
}
$indexText = Read-Utf8Text -Path $indexPath
$assetGraphMarker = '<!-- codex-webview-fix: asset-graph-reset='
$assetGraphAlreadyReset = $indexText.Contains($assetGraphMarker)

if ($ResetAssetGraph) {
    if ($assetGraphAlreadyReset) {
        Write-Host "Asset graph already reset: $($extension.Path)"
        exit 0
    }

    $entryMatch = [regex]::Match($indexText, '<script\s+type="module"[^>]+src="\./assets/(?<entry>index-[^"]+\.js)"[^>]*></script>')
    if (-not $entryMatch.Success) {
        throw 'Could not identify the active Webview entry script. No files were changed.'
    }
    $staticModulePreloads = [regex]::Matches($indexText, '(?m)^[ \t]*<link\s+rel="modulepreload"[^>]*>[ \t]*\r?\n?')
    if ($staticModulePreloads.Count -eq 0) {
        throw 'No static modulepreload links were found. No files were changed.'
    }

    $assetNonce = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $stagingName = ".codex-webview-fix-stage-$assetNonce"
    $targetName = "assets-cache-bust-$assetNonce"
    $stagingDirectory = Join-Path $webviewDirectory $stagingName
    $targetDirectory = Join-Path $webviewDirectory $targetName
    Copy-Item -LiteralPath $assetsDirectory -Destination $stagingDirectory -Recurse

    try {
        $readinessPatch = Get-ReadinessPatch -AssetsDirectory $stagingDirectory
        if ($readinessPatch.Changed) {
            [System.IO.File]::WriteAllText($readinessPatch.MainFile.FullName, $readinessPatch.MainText, $utf8WithoutBom)
            [System.IO.File]::WriteAllText($readinessPatch.RouteFile.FullName, $readinessPatch.RouteText, $utf8WithoutBom)
        }

        $entryPath = Join-Path $stagingDirectory $entryMatch.Groups['entry'].Value
        if (-not (Test-Path -LiteralPath $entryPath)) {
            throw "The active Webview entry script is missing: $entryPath"
        }
        $patchedEntry = Get-CssOnlyEntryPatch -EntryPath $entryPath
        [System.IO.File]::WriteAllText($entryPath, $patchedEntry, $utf8WithoutBom)

        $patchedIndex = [regex]::Replace($indexText, '(?m)^[ \t]*<link\s+rel="modulepreload"[^>]*>[ \t]*\r?\n?', '')
        $marker = "$assetGraphMarker$targetName -->"
        $patchedIndex = $patchedIndex.Replace($entryMatch.Value, "$marker`r`n    $($entryMatch.Value.Replace('./assets/', "./$targetName/"))")
        $patchedIndex = $patchedIndex.Replace('./assets/', "./$targetName/")
        if ($patchedIndex.Contains('rel="modulepreload"') -or -not $patchedIndex.Contains($marker) -or -not $patchedIndex.Contains("./$targetName/")) {
            throw 'Post-patch index validation failed. No files were changed.'
        }

        $backupDirectory = New-BackupDirectory -Extension $extension -BackupRoot $backupRoot
        $indexBackup = Join-Path $backupDirectory 'index.html'
        Copy-Item -LiteralPath $indexPath -Destination $indexBackup
        $manifest = [ordered]@{
            extensionPath = $extension.Path
            extensionVersion = [string]$extension.Package.version
            mode = 'asset-graph-reset'
            createdAt = (Get-Date).ToString('o')
            files = @(@{ original = $indexPath; backup = $indexBackup })
            directories = @($targetDirectory)
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDirectory 'manifest.json') -Encoding UTF8

        Move-Item -LiteralPath $stagingDirectory -Destination $targetDirectory
        try {
            [System.IO.File]::WriteAllText($indexPath, $patchedIndex, $utf8WithoutBom)
        } catch {
            Remove-Item -LiteralPath $targetDirectory -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $indexBackup -Destination $indexPath -Force
            throw
        }
    } catch {
        if (Test-Path -LiteralPath $stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
        }
        throw
    }

    Write-Host "Patched openai.chatgpt $($extension.Package.version) with an isolated asset graph"
    Write-Host "Extension: $($extension.Path)"
    Write-Host "Assets: $targetDirectory"
    Write-Host "Backup: $backupDirectory"
    Write-Host 'Restart every VS Code window. Reload affected windows sequentially.'
    exit 0
}

if ($assetGraphAlreadyReset) {
    Write-Host "Asset graph fallback already active: $($extension.Path)"
    exit 0
}

$readinessPatch = Get-ReadinessPatch -AssetsDirectory $assetsDirectory
if (-not $readinessPatch.Changed) {
    Write-Host "Already patched: $($extension.Path)"
    exit 0
}

$backupDirectory = New-BackupDirectory -Extension $extension -BackupRoot $backupRoot
$mainBackup = Join-Path $backupDirectory $readinessPatch.MainFile.Name
$routeBackup = Join-Path $backupDirectory $readinessPatch.RouteFile.Name
Copy-Item -LiteralPath $readinessPatch.MainFile.FullName -Destination $mainBackup
Copy-Item -LiteralPath $readinessPatch.RouteFile.FullName -Destination $routeBackup
$manifest = [ordered]@{
    extensionPath = $extension.Path
    extensionVersion = [string]$extension.Package.version
    mode = 'readiness'
    createdAt = (Get-Date).ToString('o')
    files = @(
        @{ original = $readinessPatch.MainFile.FullName; backup = $mainBackup }
        @{ original = $readinessPatch.RouteFile.FullName; backup = $routeBackup }
    )
    directories = @()
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDirectory 'manifest.json') -Encoding UTF8

try {
    [System.IO.File]::WriteAllText($readinessPatch.MainFile.FullName, $readinessPatch.MainText, $utf8WithoutBom)
    [System.IO.File]::WriteAllText($readinessPatch.RouteFile.FullName, $readinessPatch.RouteText, $utf8WithoutBom)
} catch {
    Copy-Item -LiteralPath $mainBackup -Destination $readinessPatch.MainFile.FullName -Force
    Copy-Item -LiteralPath $routeBackup -Destination $readinessPatch.RouteFile.FullName -Force
    throw
}

Write-Host "Patched openai.chatgpt $($extension.Package.version)"
Write-Host "Extension: $($extension.Path)"
Write-Host "Backup: $backupDirectory"
Write-Host 'Restart VS Code or run Developer: Reload Window.'
