param(
    [Parameter(Mandatory = $true)]
    [string]$SshTarget,

    [string]$IdentityFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

if ($SshTarget -notmatch '^[A-Za-z0-9_.@:-]+$') {
    throw "-SshTarget contains unsupported characters; use a trusted SSH alias or user@host"
}
if ($IdentityFile) {
    $IdentityFile = [IO.Path]::GetFullPath($IdentityFile)
    if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {
        throw "-IdentityFile does not exist"
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$serverDirectory = Join-Path $repositoryRoot "server"
Push-Location $repositoryRoot
try {
    $topLevel = (& git rev-parse --show-toplevel).Trim()
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($topLevel) -ne $repositoryRoot) {
        throw "Run this script from the CoupleChat monorepo"
    }
    if (& git status --porcelain) {
        throw "Working tree must be clean before deployment"
    }
    $commitSha = (& git rev-parse HEAD).Trim().ToLowerInvariant()
    if ($commitSha -notmatch '^[0-9a-f]{40}$') {
        throw "Unable to resolve a full commit SHA"
    }
    Invoke-Native -Command "git" -Arguments @("fetch", "--quiet", "origin", "main")
    $remoteSha = (& git rev-parse origin/main).Trim().ToLowerInvariant()
    if ($remoteSha -ne $commitSha) {
        throw "HEAD must exactly match origin/main before deployment"
    }

    Push-Location $serverDirectory
    try {
        Invoke-Native -Command "npm" -Arguments @("run", "check")
    } finally {
        Pop-Location
    }

    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $temporaryDirectory = Join-Path $temporaryParent ("couplechat-deploy-" + [Guid]::NewGuid().ToString("N"))
    [IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
    try {
        $packageName = "server-$commitSha.tar.gz"
        $packagePath = Join-Path $temporaryDirectory $packageName
        Invoke-Native -Command "git" -Arguments @(
            "archive",
            "--worktree-attributes",
            "--format=tar.gz",
            "--output=$packagePath",
            "${commitSha}:server"
        )
        $packageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagePath).Hash.ToLowerInvariant()
        $remotePackage = "/opt/couplechat/incoming/$packageName"

        $sshArguments = @(
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=15"
        )
        if ($IdentityFile) {
            $sshArguments += @("-i", $IdentityFile)
        }
        $scpArguments = @($sshArguments) + @($packagePath, "${SshTarget}:$remotePackage")
        Invoke-Native -Command "ssh" -Arguments (@($sshArguments) + @(
            $SshTarget,
            "install -d -m 0700 -o root -g root /opt/couplechat/incoming"
        ))
        Invoke-Native -Command "scp" -Arguments $scpArguments

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-Native -Command "ssh" -Arguments (@($sshArguments) + @(
            $SshTarget,
            "/opt/couplechat/bin/deploy-server '$remotePackage' '$packageHash' '$commitSha'"
        ))
        $stopwatch.Stop()
        Write-Output "release=$commitSha total_seconds=$([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1))"
    } finally {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryDirectory)
        if ($resolvedTemporary.StartsWith($temporaryParent, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedTemporary).StartsWith("couplechat-deploy-", [StringComparison]::Ordinal)) {
            [IO.Directory]::Delete($resolvedTemporary, $true)
        }
    }
} finally {
    Pop-Location
}
