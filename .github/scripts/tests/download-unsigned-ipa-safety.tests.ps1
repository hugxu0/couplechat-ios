Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptsDirectory = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$toolsPath = Join-Path $scriptsDirectory "ipa-artifact-tools.ps1"
$downloadScriptPath = Join-Path $scriptsDirectory "download-unsigned-ipa.ps1"
. $toolsPath

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $threw = $false
    try {
        & $Action
    } catch {
        $threw = $true
    }
    if (-not $threw) {
        throw $Message
    }
}

function Assert-PowerShellParses {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count -ne 0) {
        throw "PowerShell parser rejected $Path"
    }
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Remove-TestJunction {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    Assert-True `
        -Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) `
        -Message "Test cleanup only removes the fixture junction itself"
    [IO.Directory]::Delete($item.FullName, $false)
}

function New-TestArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ActualBundleIdentifier,
        [bool]$IncludeCodeSignature = $false
    )

    $commit = "0123456789abcdef0123456789abcdef01234567"
    $runId = 123456
    $runAttempt = 2
    $artifactName = "CoupleChat-unsigned-$commit-run-$runId-attempt-$runAttempt"
    $version = "0.2.0"
    $buildNumber = "11"
    $ipaName = "CoupleChat-unsigned-$($commit.Substring(0, 12))-$version-$buildNumber.ipa"
    $artifactDirectory = Join-Path $FixtureRoot $Name
    $sourceDirectory = Join-Path $FixtureRoot "$Name-source"
    $appDirectory = Join-Path $sourceDirectory "Payload\CoupleChat.app"
    New-Item -ItemType Directory -Path $artifactDirectory, $appDirectory | Out-Null

    $infoPlist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$ActualBundleIdentifier</string>
  <key>MinimumOSVersion</key>
  <string>26.0</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$buildNumber</string>
</dict>
</plist>
"@
    Write-Utf8Text -Path (Join-Path $appDirectory "Info.plist") -Content $infoPlist
    Write-Utf8Text -Path (Join-Path $appDirectory "cute_cat.glb") -Content "fixture-model"
    Write-Utf8Text -Path (Join-Path $appDirectory "ThirdPartyNotices.txt") -Content "fixture-notice"
    if ($IncludeCodeSignature) {
        $signatureDirectory = Join-Path $appDirectory "_CodeSignature"
        New-Item -ItemType Directory -Path $signatureDirectory | Out-Null
        Write-Utf8Text -Path (Join-Path $signatureDirectory "CodeResources") -Content "fixture-signature"
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ipaPath = Join-Path $artifactDirectory $ipaName
    $archive = [IO.Compression.ZipFile]::Open(
        $ipaPath,
        [IO.Compression.ZipArchiveMode]::Create
    )
    try {
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse)) {
            $entryName = $sourceFile.FullName.Substring($sourceDirectory.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $sourceFile.FullName,
                $entryName
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
    $ipaHash = (Get-FileHash -LiteralPath $ipaPath -Algorithm SHA256).Hash

    $metadata = [ordered]@{
        schemaVersion = 2
        repository = "owner/repository"
        commitSha = $commit
        workflowFile = ".github/workflows/build-ipa.yml"
        runId = $runId
        runAttempt = $runAttempt
        artifactName = $artifactName
        version = $version
        buildNumber = $buildNumber
        bundleIdentifier = "com.hugxu0.couplechat.native"
        minimumOSVersion = "26.0"
        ipaFile = $ipaName
        ipaSha256 = $ipaHash
        signed = $false
    }
    $metadataPath = Join-Path $artifactDirectory "BUILD-METADATA.json"
    Write-Utf8Text -Path $metadataPath -Content (($metadata | ConvertTo-Json) + "`n")
    $metadataHash = (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash
    Write-Utf8Text `
        -Path (Join-Path $artifactDirectory "SHA256SUMS") `
        -Content "$($ipaHash.ToLowerInvariant())  $ipaName`n$($metadataHash.ToLowerInvariant())  BUILD-METADATA.json`n"

    return [PSCustomObject]@{
        Directory = $artifactDirectory
        Commit = $commit
        RunId = $runId
        RunAttempt = $runAttempt
        ArtifactName = $artifactName
    }
}

Assert-PowerShellParses -Path $toolsPath
Assert-PowerShellParses -Path $downloadScriptPath

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $missingCommitOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File $downloadScriptPath 2>&1
    $missingCommitExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
Assert-True `
    -Condition ($missingCommitExit -ne 0) `
    -Message "Downloader must fail before GitHub access when the full commit is missing"

$tempParent = Get-NormalizedAbsolutePath ([IO.Path]::GetTempPath())
$fixtureRoot = New-SafeChildDirectory -Parent $tempParent -Prefix "couplechat-ipa-tests-"
$junctionPath = ""
try {
    $repositoryFixture = Join-Path $fixtureRoot "repository"
    $outsideFixture = Join-Path $fixtureRoot "outside"
    New-Item -ItemType Directory -Path $repositoryFixture, $outsideFixture | Out-Null
    Write-Utf8Text -Path (Join-Path $outsideFixture "sentinel.txt") -Content "must-survive"

    $safeChild = Join-Path $repositoryFixture "build-artifacts"
    New-Item -ItemType Directory -Path $safeChild | Out-Null
    Assert-NoReparsePointPath -Root $repositoryFixture -Path $safeChild

    $junctionPath = Join-Path $repositoryFixture "linked-artifacts"
    New-Item -ItemType Junction -Path $junctionPath -Target $outsideFixture | Out-Null
    Assert-Throws `
        -Action { Assert-NoReparsePointPath -Root $repositoryFixture -Path $junctionPath } `
        -Message "Existing junctions in the output path must be rejected"
    Assert-Throws `
        -Action { Remove-SafeChildDirectory -Parent $repositoryFixture -Target $junctionPath } `
        -Message "Recursive cleanup must reject a junction target"
    Assert-True `
        -Condition (Test-Path -LiteralPath (Join-Path $outsideFixture "sentinel.txt")) `
        -Message "Reparse-point rejection must preserve the external target"

    Remove-TestJunction -Path $junctionPath
    $junctionPath = ""

    $validArtifact = New-TestArtifact `
        -FixtureRoot $fixtureRoot `
        -Name "valid-artifact" `
        -ActualBundleIdentifier "com.hugxu0.couplechat.native"
    $validated = Test-IpaArtifactDirectory `
        -Directory $validArtifact.Directory `
        -ExpectedRepository "owner/repository" `
        -ExpectedCommit $validArtifact.Commit `
        -ExpectedRunId $validArtifact.RunId `
        -ExpectedRunAttempt $validArtifact.RunAttempt `
        -ExpectedArtifactName $validArtifact.ArtifactName `
        -ExpectedBundleIdentifier "com.hugxu0.couplechat.native" `
        -ExpectedMinimumOSVersion "26.0"
    Assert-True -Condition ($validated.IpaHash.Length -eq 64) -Message "Valid fixture must pass"

    $wrongBundleArtifact = New-TestArtifact `
        -FixtureRoot $fixtureRoot `
        -Name "wrong-bundle-artifact" `
        -ActualBundleIdentifier "com.example.wrong"
    Assert-Throws `
        -Action {
            Test-IpaArtifactDirectory `
                -Directory $wrongBundleArtifact.Directory `
                -ExpectedRepository "owner/repository" `
                -ExpectedCommit $wrongBundleArtifact.Commit `
                -ExpectedRunId $wrongBundleArtifact.RunId `
                -ExpectedRunAttempt $wrongBundleArtifact.RunAttempt `
                -ExpectedArtifactName $wrongBundleArtifact.ArtifactName `
                -ExpectedBundleIdentifier "com.hugxu0.couplechat.native" `
                -ExpectedMinimumOSVersion "26.0"
        } `
        -Message "Actual IPA Info.plist bundle mismatch must be rejected"

    $signedArtifact = New-TestArtifact `
        -FixtureRoot $fixtureRoot `
        -Name "signed-artifact" `
        -ActualBundleIdentifier "com.hugxu0.couplechat.native" `
        -IncludeCodeSignature $true
    Assert-Throws `
        -Action {
            Test-IpaArtifactDirectory `
                -Directory $signedArtifact.Directory `
                -ExpectedRepository "owner/repository" `
                -ExpectedCommit $signedArtifact.Commit `
                -ExpectedRunId $signedArtifact.RunId `
                -ExpectedRunAttempt $signedArtifact.RunAttempt `
                -ExpectedArtifactName $signedArtifact.ArtifactName `
                -ExpectedBundleIdentifier "com.hugxu0.couplechat.native" `
                -ExpectedMinimumOSVersion "26.0"
        } `
        -Message "IPA signing residue must be rejected"
} finally {
    if (-not [string]::IsNullOrWhiteSpace($junctionPath) -and
        (Get-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue)) {
        Remove-TestJunction -Path $junctionPath
    }
    Remove-SafeChildDirectory -Parent $tempParent -Target $fixtureRoot
}

Write-Output "[download-unsigned-ipa-safety] all tests passed"
