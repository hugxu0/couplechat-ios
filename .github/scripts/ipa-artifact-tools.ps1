function Get-PathComparison {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}

function Get-NormalizedAbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $pathRoot.Length) {
        $fullPath = $fullPath.TrimEnd(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        )
    }
    return $fullPath
}

function Test-PathEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return (Get-NormalizedAbsolutePath $Left).Equals(
        (Get-NormalizedAbsolutePath $Right),
        (Get-PathComparison)
    )
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootPath = Get-NormalizedAbsolutePath $Root
    $candidatePath = Get-NormalizedAbsolutePath $Path
    if ($candidatePath.Equals($rootPath, (Get-PathComparison))) {
        return
    }

    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($prefix, (Get-PathComparison))) {
        throw "Refusing a path outside the expected root: $candidatePath"
    }
}

function Assert-DirectChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $parentPath = Get-NormalizedAbsolutePath $Parent
    $childPath = Get-NormalizedAbsolutePath $Child
    $childParent = [IO.Directory]::GetParent($childPath)
    if (-not $childParent -or -not $childParent.FullName.Equals(
        $parentPath,
        (Get-PathComparison)
    )) {
        throw "Refusing to modify a path outside its expected parent"
    }
}

function Assert-ItemIsNotReparsePoint {
    param([Parameter(Mandatory = $true)]$Item)

    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a filesystem reparse point: $($Item.FullName)"
    }
}

function Assert-NoReparsePointPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootPath = Get-NormalizedAbsolutePath $Root
    $candidatePath = Get-NormalizedAbsolutePath $Path
    Assert-PathWithinRoot -Root $rootPath -Path $candidatePath

    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) {
        throw "Expected a directory root: $rootPath"
    }
    Assert-ItemIsNotReparsePoint $rootItem

    if ($candidatePath.Equals($rootPath, (Get-PathComparison))) {
        return
    }

    $relativePath = $candidatePath.Substring($rootPath.Length).TrimStart(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    )
    $currentPath = $rootPath
    foreach ($segment in ($relativePath -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            throw "Refusing an invalid empty path segment"
        }
        $currentPath = Join-Path $currentPath $segment
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue
        if (-not $item) {
            break
        }
        Assert-ItemIsNotReparsePoint $item
    }
}

function Assert-DirectoryTreeHasNoReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $directoryPath = Get-NormalizedAbsolutePath $Directory
    $rootItem = Get-Item -LiteralPath $directoryPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) {
        throw "Expected a directory: $directoryPath"
    }
    Assert-ItemIsNotReparsePoint $rootItem

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($directoryPath)
    while ($pending.Count -gt 0) {
        $currentPath = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction Stop)) {
            Assert-ItemIsNotReparsePoint $item
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            }
        }
    }
}

function Initialize-SafeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $rootPath = Get-NormalizedAbsolutePath $Root
    $directoryPath = Get-NormalizedAbsolutePath $Directory
    Assert-NoReparsePointPath -Root $rootPath -Path $directoryPath

    $item = Get-Item -LiteralPath $directoryPath -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        New-Item -ItemType Directory -Path $directoryPath -ErrorAction Stop | Out-Null
        $item = Get-Item -LiteralPath $directoryPath -Force -ErrorAction Stop
    }
    if (-not $item.PSIsContainer) {
        throw "Expected a directory: $directoryPath"
    }
    Assert-NoReparsePointPath -Root $rootPath -Path $directoryPath
    return $directoryPath
}

function Get-SafeUnusedDirectChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    if ($Prefix -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Unsafe temporary-directory prefix"
    }

    $parentPath = Get-NormalizedAbsolutePath $Parent
    Assert-NoReparsePointPath -Root $parentPath -Path $parentPath
    for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
        $name = "$Prefix$([Guid]::NewGuid().ToString('N'))"
        $candidate = Get-NormalizedAbsolutePath (Join-Path $parentPath $name)
        Assert-DirectChildPath -Parent $parentPath -Child $candidate
        if (-not (Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue)) {
            return $candidate
        }
    }
    throw "Unable to allocate a unique child path"
}

function New-SafeChildDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $candidate = Get-SafeUnusedDirectChildPath -Parent $Parent -Prefix $Prefix
    New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
    Assert-NoReparsePointPath -Root $Parent -Path $candidate
    return $candidate
}

function Remove-SafeChildDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $parentPath = Get-NormalizedAbsolutePath $Parent
    $targetPath = Get-NormalizedAbsolutePath $Target
    Assert-DirectChildPath -Parent $parentPath -Child $targetPath
    Assert-NoReparsePointPath -Root $parentPath -Path $parentPath

    $item = Get-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        return
    }
    Assert-ItemIsNotReparsePoint $item
    if (-not $item.PSIsContainer) {
        throw "Refusing to recursively remove a non-directory path: $targetPath"
    }
    Assert-DirectoryTreeHasNoReparsePoint -Directory $targetPath
    Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction Stop
}

function Get-RequiredJsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) {
        throw "BUILD-METADATA.json is missing $Name"
    }
    return $property.Value
}

function Read-XmlPlistDictionaryFromArchive {
    param(
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $matchingEntries = @($Archive.Entries | Where-Object { $_.FullName -ceq $EntryName })
    if ($matchingEntries.Count -ne 1) {
        throw "IPA must contain exactly one $EntryName"
    }

    $stream = $matchingEntries[0].Open()
    $xmlReader = $null
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $settings.XmlResolver = $null
        $xmlReader = [System.Xml.XmlReader]::Create($stream, $settings)
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($xmlReader)
    } catch {
        throw "IPA Info.plist must be a safe XML plist: $($_.Exception.Message)"
    } finally {
        if ($xmlReader) {
            $xmlReader.Dispose()
        }
        $stream.Dispose()
    }

    $dictionaryNode = $document.SelectSingleNode("/plist/dict")
    if (-not $dictionaryNode) {
        throw "IPA Info.plist does not contain a root dictionary"
    }
    $nodes = @($dictionaryNode.ChildNodes | Where-Object {
        $_.NodeType -eq [System.Xml.XmlNodeType]::Element
    })
    if (($nodes.Count % 2) -ne 0) {
        throw "IPA Info.plist dictionary has an invalid key/value structure"
    }

    $values = New-Object 'System.Collections.Generic.Dictionary[string,string]' (
        [StringComparer]::Ordinal
    )
    for ($index = 0; $index -lt $nodes.Count; $index += 2) {
        $keyNode = $nodes[$index]
        $valueNode = $nodes[$index + 1]
        if ($keyNode.LocalName -cne "key") {
            throw "IPA Info.plist dictionary contains a value without a key"
        }
        $key = [string]$keyNode.InnerText
        if ($values.ContainsKey($key)) {
            throw "IPA Info.plist contains a duplicate key: $key"
        }
        if ($valueNode.LocalName -cne "string" -and $valueNode.LocalName -cne "integer") {
            throw "IPA Info.plist key $key is not a string or integer"
        }
        $values.Add($key, [string]$valueNode.InnerText)
    }
    return ,$values
}

function Test-IpaArtifactDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$ExpectedRepository,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][long]$ExpectedRunId,
        [Parameter(Mandatory = $true)][int]$ExpectedRunAttempt,
        [Parameter(Mandatory = $true)][string]$ExpectedArtifactName,
        [Parameter(Mandatory = $true)][string]$ExpectedBundleIdentifier,
        [Parameter(Mandatory = $true)][string]$ExpectedMinimumOSVersion
    )

    $directoryPath = Get-NormalizedAbsolutePath $Directory
    Assert-DirectoryTreeHasNoReparsePoint -Directory $directoryPath
    $children = @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)
    if (@($children | Where-Object { $_.PSIsContainer }).Count -ne 0 -or $children.Count -ne 3) {
        throw "Artifact must contain exactly three top-level files"
    }

    $ipaFiles = @($children | Where-Object { -not $_.PSIsContainer -and $_.Extension -ceq ".ipa" })
    $metadataFiles = @($children | Where-Object { -not $_.PSIsContainer -and $_.Name -ceq "BUILD-METADATA.json" })
    $checksumFiles = @($children | Where-Object { -not $_.PSIsContainer -and $_.Name -ceq "SHA256SUMS" })
    if ($ipaFiles.Count -ne 1 -or $metadataFiles.Count -ne 1 -or $checksumFiles.Count -ne 1) {
        throw "Artifact must contain one IPA, BUILD-METADATA.json, and SHA256SUMS"
    }

    $ipaFile = $ipaFiles[0]
    $metadataFile = $metadataFiles[0]
    $checksumFile = $checksumFiles[0]
    $metadata = Get-Content -LiteralPath $metadataFile.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json

    if ([int](Get-RequiredJsonProperty $metadata "schemaVersion") -ne 2) {
        throw "Unsupported build metadata schema"
    }
    if (-not ([string](Get-RequiredJsonProperty $metadata "repository")).Equals(
        $ExpectedRepository,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Artifact metadata belongs to a different repository"
    }
    if (-not ([string](Get-RequiredJsonProperty $metadata "commitSha")).Equals(
        $ExpectedCommit,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Artifact metadata belongs to a different commit"
    }
    if ([long](Get-RequiredJsonProperty $metadata "runId") -ne $ExpectedRunId) {
        throw "Artifact metadata has a different runId"
    }
    if ([int](Get-RequiredJsonProperty $metadata "runAttempt") -ne $ExpectedRunAttempt) {
        throw "Artifact metadata has a different runAttempt"
    }
    if ([string](Get-RequiredJsonProperty $metadata "artifactName") -cne $ExpectedArtifactName) {
        throw "Artifact metadata has a different artifactName"
    }
    if ([string](Get-RequiredJsonProperty $metadata "workflowFile") -cne ".github/workflows/build-ipa.yml") {
        throw "Artifact metadata has a different workflow file"
    }

    $signedValue = Get-RequiredJsonProperty $metadata "signed"
    if ($signedValue -isnot [bool] -or $signedValue) {
        throw "Artifact metadata must explicitly declare signed=false"
    }

    $bundleIdentifier = [string](Get-RequiredJsonProperty $metadata "bundleIdentifier")
    $minimumOSVersion = [string](Get-RequiredJsonProperty $metadata "minimumOSVersion")
    $version = [string](Get-RequiredJsonProperty $metadata "version")
    $buildNumber = [string](Get-RequiredJsonProperty $metadata "buildNumber")
    if ($bundleIdentifier -cne $ExpectedBundleIdentifier) {
        throw "Artifact has an unexpected bundle identifier"
    }
    if ($minimumOSVersion -cne $ExpectedMinimumOSVersion) {
        throw "Artifact has an unexpected minimum OS version"
    }
    if ($version -notmatch '^\d+(\.\d+){1,3}$') {
        throw "Artifact metadata contains an invalid version"
    }
    if ($buildNumber -notmatch '^\d+$') {
        throw "Artifact metadata contains an invalid build number"
    }
    if ([string](Get-RequiredJsonProperty $metadata "ipaFile") -cne $ipaFile.Name) {
        throw "Artifact IPA filename does not match metadata"
    }

    $expectedIpaName = "CoupleChat-unsigned-$($ExpectedCommit.Substring(0, 12))-$version-$buildNumber.ipa"
    if ($ipaFile.Name -cne $expectedIpaName) {
        throw "Artifact IPA filename does not match the commit and version metadata"
    }

    $expectedHashes = New-Object 'System.Collections.Generic.Dictionary[string,string]' (
        [StringComparer]::Ordinal
    )
    foreach ($line in [IO.File]::ReadAllLines($checksumFile.FullName, [Text.Encoding]::UTF8)) {
        if ($line -notmatch '^([0-9a-fA-F]{64})  (\*?)([^/\\]+)$') {
            throw "SHA256SUMS contains an invalid line"
        }
        $fileName = $Matches[3]
        if ($expectedHashes.ContainsKey($fileName)) {
            throw "SHA256SUMS contains a duplicate filename"
        }
        $expectedHashes.Add($fileName, $Matches[1].ToUpperInvariant())
    }

    $requiredChecksums = @($ipaFile.Name, "BUILD-METADATA.json")
    if ($expectedHashes.Count -ne $requiredChecksums.Count) {
        throw "SHA256SUMS must describe only the IPA and BUILD-METADATA.json"
    }
    foreach ($fileName in $requiredChecksums) {
        if (-not $expectedHashes.ContainsKey($fileName)) {
            throw "SHA256SUMS is missing $fileName"
        }
        $sourcePath = if ($fileName -ceq $ipaFile.Name) {
            $ipaFile.FullName
        } else {
            $metadataFile.FullName
        }
        $actualHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        if ($actualHash -cne $expectedHashes[$fileName]) {
            throw "SHA-256 mismatch for $fileName"
        }
    }

    $ipaHash = (Get-FileHash -LiteralPath $ipaFile.FullName -Algorithm SHA256).Hash
    if (-not $ipaHash.Equals(
        [string](Get-RequiredJsonProperty $metadata "ipaSha256"),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "IPA hash does not match BUILD-METADATA.json"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ipaFile.FullName)
    try {
        $requiredEntries = @(
            "Payload/CoupleChat.app/Info.plist",
            "Payload/CoupleChat.app/cute_cat.glb",
            "Payload/CoupleChat.app/ThirdPartyNotices.txt"
        )
        foreach ($entryName in $requiredEntries) {
            if (@($archive.Entries | Where-Object { $_.FullName -ceq $entryName }).Count -ne 1) {
                throw "IPA must contain exactly one $entryName"
            }
        }
        foreach ($entry in $archive.Entries) {
            $originalEntryName = $entry.FullName
            $entryName = $originalEntryName.Replace('\', '/')
            $entrySegments = @($entryName.Split('/') | Where-Object { $_ -ne "" })
            if ($entryName.StartsWith("/", [StringComparison]::Ordinal) -or
                $originalEntryName.Contains("\") -or
                $entryName.Contains(":") -or
                $entrySegments -contains "." -or
                $entrySegments -contains "..") {
                throw "IPA contains an unsafe ZIP entry path"
            }
            if ($entryName -match '(^|/)_CodeSignature(/|$)' -or
                $entryName -match '(^|/)embedded\.mobileprovision$') {
                throw "IPA unexpectedly contains signing material"
            }
        }

        $plistValues = Read-XmlPlistDictionaryFromArchive `
            -Archive $archive `
            -EntryName "Payload/CoupleChat.app/Info.plist"
        foreach ($key in @(
            "CFBundleIdentifier",
            "MinimumOSVersion",
            "CFBundleShortVersionString",
            "CFBundleVersion"
        )) {
            if (-not $plistValues.ContainsKey($key)) {
                throw "IPA Info.plist is missing $key"
            }
        }
        if ($plistValues["CFBundleIdentifier"] -cne $ExpectedBundleIdentifier) {
            throw "IPA Info.plist has an unexpected bundle identifier"
        }
        if ($plistValues["MinimumOSVersion"] -cne $ExpectedMinimumOSVersion) {
            throw "IPA Info.plist has an unexpected minimum OS version"
        }
        if ($plistValues["CFBundleShortVersionString"] -cne $version -or
            $plistValues["CFBundleVersion"] -cne $buildNumber) {
            throw "IPA Info.plist does not match BUILD-METADATA.json"
        }
    } finally {
        $archive.Dispose()
    }

    return [PSCustomObject]@{
        IpaFile = $ipaFile.FullName
        IpaName = $ipaFile.Name
        IpaHash = $ipaHash
        MetadataFile = $metadataFile.FullName
        ChecksumFile = $checksumFile.FullName
    }
}
