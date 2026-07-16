param(
    [string]$Commit = "",

    [long]$RunId = 0,

    [string]$OutputDirectory = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$expectedBundleIdentifier = "com.hugxu0.couplechat.native"
$expectedMinimumOSVersion = "26.0"
$expectedWorkflowFile = ".github/workflows/build-ipa.yml"

. (Join-Path $PSScriptRoot "ipa-artifact-tools.ps1")

function Invoke-GitHubJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $json = & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        $safePrefix = @($Arguments | Select-Object -First 3) -join " "
        throw "GitHub CLI command failed: gh $safePrefix"
    }
    return $json | ConvertFrom-Json
}

function Remove-TemporaryDirectorySafely {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [string]$Target = ""
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return
    }
    try {
        Remove-SafeChildDirectory -Parent $Parent -Target $Target
    } catch {
        Write-Warning "Temporary directory was left in place because safe cleanup failed: $Target"
    }
}

if ($Commit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "-Commit is required and must be a full 40-character Git SHA"
}
if ($RunId -lt 0) {
    throw "-RunId cannot be negative"
}

$commitSha = $Commit.ToLowerInvariant()
$repositoryRoot = Get-NormalizedAbsolutePath (Join-Path $PSScriptRoot "..\..")
Assert-NoReparsePointPath -Root $repositoryRoot -Path $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $desktopDirectory = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::DesktopDirectory
    )
    if ([string]::IsNullOrWhiteSpace($desktopDirectory)) {
        throw "Unable to resolve the current user's Desktop directory"
    }
    $OutputDirectory = Join-Path $desktopDirectory "CoupleChat-IPA"
}
$destinationRoot = Get-NormalizedAbsolutePath $OutputDirectory
$destinationParentInfo = [IO.Directory]::GetParent($destinationRoot)
if (-not $destinationParentInfo) {
    throw "-OutputDirectory cannot be a filesystem root"
}
$destinationParent = Get-NormalizedAbsolutePath $destinationParentInfo.FullName
$destinationParentItem = Get-Item -LiteralPath $destinationParent -Force -ErrorAction Stop
if (-not $destinationParentItem.PSIsContainer) {
    throw "The parent of -OutputDirectory must be an existing directory"
}
Assert-ItemIsNotReparsePoint $destinationParentItem
Assert-DirectChildPath -Parent $destinationParent -Child $destinationRoot
Assert-NoReparsePointPath -Root $destinationParent -Path $destinationRoot

Push-Location $repositoryRoot
try {
    $repositoryResult = Invoke-GitHubJson -Arguments @(
        "repo", "view", "--json", "nameWithOwner"
    )
} finally {
    Pop-Location
}
$repository = [string](Get-RequiredJsonProperty $repositoryResult "nameWithOwner")
if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Unable to resolve a valid GitHub repository"
}

$workflowResult = Invoke-GitHubJson -Arguments @(
    "api", "repos/$repository/actions/workflows/build-ipa.yml"
)
$expectedWorkflowDatabaseId = [long](Get-RequiredJsonProperty $workflowResult "id")
$resolvedWorkflowPath = [string](Get-RequiredJsonProperty $workflowResult "path")
if ($expectedWorkflowDatabaseId -le 0 -or $resolvedWorkflowPath -cne $expectedWorkflowFile) {
    throw "GitHub did not resolve build-ipa.yml to the expected workflow"
}

$runFields = "attempt,databaseId,headSha,status,conclusion,workflowDatabaseId"
$run = $null
if ($RunId -gt 0) {
    $run = Invoke-GitHubJson -Arguments @(
        "run", "view", [string]$RunId,
        "--repo", $repository,
        "--json", $runFields
    )
} else {
    $runResults = Invoke-GitHubJson -Arguments @(
        "run", "list",
        "--repo", $repository,
        "--workflow", "build-ipa.yml",
        "--commit", $commitSha,
        "--status", "success",
        "--limit", "20",
        "--json", $runFields
    )
    $run = @($runResults) |
        Where-Object {
            ([string]$_.headSha).Equals($commitSha, [StringComparison]::OrdinalIgnoreCase) -and
            [long]$_.workflowDatabaseId -eq $expectedWorkflowDatabaseId
        } |
        Select-Object -First 1
}

if (-not $run) {
    throw "No successful unsigned IPA workflow was found for commit $commitSha"
}

$resolvedRunId = [long](Get-RequiredJsonProperty $run "databaseId")
$resolvedRunAttempt = [int](Get-RequiredJsonProperty $run "attempt")
$runWorkflowDatabaseId = [long](Get-RequiredJsonProperty $run "workflowDatabaseId")
if ($resolvedRunId -le 0) {
    throw "The workflow run has an invalid databaseId"
}
if ($resolvedRunAttempt -le 0) {
    throw "The workflow run has an invalid attempt"
}
if (-not ([string](Get-RequiredJsonProperty $run "headSha")).Equals(
    $commitSha,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Workflow run $resolvedRunId belongs to a different commit"
}
if ([string](Get-RequiredJsonProperty $run "status") -ne "completed" -or
    [string](Get-RequiredJsonProperty $run "conclusion") -ne "success") {
    throw "Workflow run $resolvedRunId has not completed successfully"
}
if ($runWorkflowDatabaseId -ne $expectedWorkflowDatabaseId) {
    throw "Workflow run $resolvedRunId did not originate from build-ipa.yml"
}

$artifactName = "CoupleChat-unsigned-$commitSha-run-$resolvedRunId-attempt-$resolvedRunAttempt"
$artifactRoot = Get-NormalizedAbsolutePath (Join-Path $repositoryRoot "build-artifacts")

Initialize-SafeDirectory -Root $repositoryRoot -Directory $artifactRoot | Out-Null
Assert-DirectChildPath -Parent $destinationParent -Child $destinationRoot
Assert-NoReparsePointPath -Root $destinationParent -Path $destinationRoot

$downloadRoot = New-SafeChildDirectory `
    -Parent $artifactRoot `
    -Prefix ".ipa-download-$resolvedRunId-$resolvedRunAttempt-"
$publishStaging = ""
$previousRoot = ""
$published = $false

try {
    & gh run download $resolvedRunId `
        --repo $repository `
        --name $artifactName `
        --dir $downloadRoot
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub artifact download failed for run $resolvedRunId attempt $resolvedRunAttempt"
    }

    $downloaded = Test-IpaArtifactDirectory `
        -Directory $downloadRoot `
        -ExpectedRepository $repository `
        -ExpectedCommit $commitSha `
        -ExpectedRunId $resolvedRunId `
        -ExpectedRunAttempt $resolvedRunAttempt `
        -ExpectedArtifactName $artifactName `
        -ExpectedBundleIdentifier $expectedBundleIdentifier `
        -ExpectedMinimumOSVersion $expectedMinimumOSVersion

    $publishStaging = New-SafeChildDirectory -Parent $destinationParent -Prefix ".ipa-stage-"
    foreach ($sourcePath in @(
        $downloaded.IpaFile,
        $downloaded.MetadataFile,
        $downloaded.ChecksumFile
    )) {
        Copy-Item -LiteralPath $sourcePath -Destination $publishStaging -ErrorAction Stop
    }

    $staged = Test-IpaArtifactDirectory `
        -Directory $publishStaging `
        -ExpectedRepository $repository `
        -ExpectedCommit $commitSha `
        -ExpectedRunId $resolvedRunId `
        -ExpectedRunAttempt $resolvedRunAttempt `
        -ExpectedArtifactName $artifactName `
        -ExpectedBundleIdentifier $expectedBundleIdentifier `
        -ExpectedMinimumOSVersion $expectedMinimumOSVersion

    $existingDestination = Get-Item -LiteralPath $destinationRoot -Force -ErrorAction SilentlyContinue
    if ($existingDestination) {
        Assert-ItemIsNotReparsePoint $existingDestination
        if (-not $existingDestination.PSIsContainer) {
            throw "Existing IPA destination is not a directory"
        }
        Assert-DirectoryTreeHasNoReparsePoint -Directory $destinationRoot
        $previousRoot = Get-SafeUnusedDirectChildPath -Parent $destinationParent -Prefix ".ipa-previous-"
        Move-Item -LiteralPath $destinationRoot -Destination $previousRoot -ErrorAction Stop
    }

    try {
        Move-Item -LiteralPath $publishStaging -Destination $destinationRoot -ErrorAction Stop
        $publishStaging = ""
        $published = $true
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($previousRoot) -and
            (Get-Item -LiteralPath $previousRoot -Force -ErrorAction SilentlyContinue) -and
            -not (Get-Item -LiteralPath $destinationRoot -Force -ErrorAction SilentlyContinue)) {
            Move-Item -LiteralPath $previousRoot -Destination $destinationRoot -ErrorAction Stop
            $previousRoot = ""
        }
        throw
    }

    $final = Test-IpaArtifactDirectory `
        -Directory $destinationRoot `
        -ExpectedRepository $repository `
        -ExpectedCommit $commitSha `
        -ExpectedRunId $resolvedRunId `
        -ExpectedRunAttempt $resolvedRunAttempt `
        -ExpectedArtifactName $artifactName `
        -ExpectedBundleIdentifier $expectedBundleIdentifier `
        -ExpectedMinimumOSVersion $expectedMinimumOSVersion

    if (-not [string]::IsNullOrWhiteSpace($previousRoot)) {
        Remove-TemporaryDirectorySafely -Parent $destinationParent -Target $previousRoot
        $previousRoot = ""
    }

    Write-Output "REPOSITORY=$repository"
    Write-Output "WORKFLOW_DATABASE_ID=$expectedWorkflowDatabaseId"
    Write-Output "RUN_ID=$resolvedRunId"
    Write-Output "RUN_ATTEMPT=$resolvedRunAttempt"
    Write-Output "COMMIT=$commitSha"
    Write-Output "ARTIFACT=$artifactName"
    Write-Output "OUTPUT_DIRECTORY=$destinationRoot"
    Write-Output "IPA=$($final.IpaFile)"
    Write-Output "METADATA=$($final.MetadataFile)"
    Write-Output "SHA256=$($final.IpaHash)"
} catch {
    if ($published -and
        -not [string]::IsNullOrWhiteSpace($previousRoot) -and
        (Get-Item -LiteralPath $previousRoot -Force -ErrorAction SilentlyContinue)) {
        $failedPublishedRoot = Get-SafeUnusedDirectChildPath -Parent $destinationParent -Prefix ".ipa-failed-"
        try {
            if (Get-Item -LiteralPath $destinationRoot -Force -ErrorAction SilentlyContinue) {
                Move-Item -LiteralPath $destinationRoot -Destination $failedPublishedRoot -ErrorAction Stop
            }
            Move-Item -LiteralPath $previousRoot -Destination $destinationRoot -ErrorAction Stop
            $previousRoot = ""
            Remove-TemporaryDirectorySafely -Parent $destinationParent -Target $failedPublishedRoot
        } catch {
            Write-Warning "The prior verified directory remains at $previousRoot because rollback could not finish"
        }
    } elseif ($published -and
        (Get-Item -LiteralPath $destinationRoot -Force -ErrorAction SilentlyContinue)) {
        $failedPublishedRoot = Get-SafeUnusedDirectChildPath -Parent $destinationParent -Prefix ".ipa-failed-"
        try {
            Move-Item -LiteralPath $destinationRoot -Destination $failedPublishedRoot -ErrorAction Stop
            Remove-TemporaryDirectorySafely -Parent $destinationParent -Target $failedPublishedRoot
        } catch {
            Write-Warning "A failed first publication remains at $destinationRoot and must not be used"
        }
    }
    throw
} finally {
    Remove-TemporaryDirectorySafely -Parent $artifactRoot -Target $downloadRoot
    Remove-TemporaryDirectorySafely -Parent $destinationParent -Target $publishStaging
}
