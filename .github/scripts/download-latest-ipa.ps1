param(
    [long]$RunId = 0
)

$ErrorActionPreference = "Stop"

$resolvedRunId = $RunId
if ($resolvedRunId -le 0) {
    $runJson = & gh run list --workflow build-ipa.yml --status success --limit 1 --json databaseId
    if ($LASTEXITCODE -ne 0) { throw "Unable to query the latest successful IPA workflow" }

    $runs = @($runJson | ConvertFrom-Json)
    if ($runs.Count -eq 0) { throw "No successful IPA workflow run was found" }
    $resolvedRunId = [long]$runs[0].databaseId
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$artifactRoot = Join-Path $repositoryRoot "build-artifacts"
$temporaryRoot = Join-Path $artifactRoot ".ipa-download-$resolvedRunId"
$latestIPA = Join-Path $artifactRoot "CoupleChat-latest.ipa"

New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null

if (Test-Path -LiteralPath $temporaryRoot) {
    $resolvedTemporary = (Resolve-Path $temporaryRoot).Path
    if (-not $resolvedTemporary.StartsWith(
        $artifactRoot + [IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to clean path outside build-artifacts: $resolvedTemporary"
    }
    Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null

try {
    & gh run download $resolvedRunId --name CoupleChat-latest --dir $temporaryRoot
    if ($LASTEXITCODE -ne 0) { throw "GitHub artifact download failed for run $resolvedRunId" }

    $downloadedIPA = Get-ChildItem -LiteralPath $temporaryRoot -Recurse -File -Filter *.ipa |
        Select-Object -First 1
    if (-not $downloadedIPA) { throw "Run $resolvedRunId did not contain an IPA artifact" }

    Copy-Item -LiteralPath $downloadedIPA.FullName -Destination $latestIPA -Force
    $hash = Get-FileHash -LiteralPath $latestIPA -Algorithm SHA256
    Write-Output "RUN_ID=$resolvedRunId"
    Write-Output "IPA=$latestIPA"
    Write-Output "SHA256=$($hash.Hash)"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
