# Publish the CoupleChat server to the Mi 10 phone (Ubuntu chroot).
# Usage:
#   .\server\deploy\publish-phone.ps1 [-SshTarget server@100.102.27.64] [-SshPort 2222]
#       [-IdentityFile <path>] [-WithMigrations] [-CheckPublic] [-SkipLocalCheck]
#
# Same safety rules as publish-server.ps1: clean tree, HEAD == origin/main,
# local check, then a verified tarball is shipped to the phone and installed
# by /home/server/bin/deploy-phone.sh.

param(
    [string]$SshTarget = "server@100.102.27.64",
    [int]$SshPort = 2222,
    [string]$IdentityFile = "",
    [string]$RemoteAppDir = "/home/server/apps/couplechat",
    [switch]$WithMigrations,
    [switch]$CheckPublic,
    [switch]$SkipLocalCheck
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
    throw "-SshTarget contains unsupported characters; use an SSH alias or user@host"
}
if ($SshPort -lt 1 -or $SshPort -gt 65535) {
    throw "-SshPort out of range"
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

    if (-not $SkipLocalCheck) {
        Push-Location $serverDirectory
        try {
            Invoke-Native -Command "npm" -Arguments @("run", "check")
        } finally {
            Pop-Location
        }
    }

    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $temporaryDirectory = Join-Path $temporaryParent ("couplechat-phone-deploy-" + [Guid]::NewGuid().ToString("N"))
    [IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
    try {
        $packageName = "server-$commitSha.tar.gz"
        $packagePath = Join-Path $temporaryDirectory $packageName
        Invoke-Native -Command "git" -Arguments @(
            "archive", "--worktree-attributes", "--format=tar.gz",
            "--output=$packagePath", "${commitSha}:server"
        )
        $packageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagePath).Hash.ToLowerInvariant()

        $sshArguments = @(
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=15",
            "-p", "$SshPort"
        )
        $scpArguments = @(
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=15",
            "-P", "$SshPort"
        )
        if ($IdentityFile) {
            $sshArguments += @("-i", $IdentityFile)
            $scpArguments += @("-i", $IdentityFile)
        }

        # 手机端必须已按迁移文档初始化（.env、uploads、.data、releases、deploy-phone.sh）

        Invoke-Native -Command "ssh" -Arguments (@($sshArguments) + @(
            $SshTarget,
            "install -d -m 0755 $RemoteAppDir/incoming"
        ))
        Invoke-Native -Command "scp" -Arguments (@($scpArguments) + @(
            (Join-Path $PSScriptRoot "deploy-phone.sh"),
            "${SshTarget}:/home/server/bin/deploy-phone.sh"
        ))
        Invoke-Native -Command "ssh" -Arguments (@($sshArguments) + @(
            $SshTarget,
            "chmod 755 /home/server/bin/deploy-phone.sh"
        ))
        Invoke-Native -Command "ssh" -Arguments (@($sshArguments) + @(
            $SshTarget,
            "test -f $RemoteAppDir/.env && test -d $RemoteAppDir/uploads && test -d $RemoteAppDir/.data && " +
            "echo phone-env-ok"
        ))

        $remotePackage = "$RemoteAppDir/incoming/$packageName"
        Invoke-Native -Command "scp" -Arguments (@($scpArguments) + @(
            $packagePath,
            "${SshTarget}:$remotePackage"
        ))
        Invoke-Native -Command "ssh" -Arguments (@($sshArguments) + @(
            $SshTarget,
            "chmod 600 $remotePackage"
        ))

        $remoteCommand = "/home/server/bin/deploy-phone.sh '$remotePackage' '$packageHash' '$commitSha'"
        if ($WithMigrations) {
            $remoteCommand += " --with-migrations"
        }
        if ($CheckPublic) {
            $remoteCommand = "COUPLECHAT_PUBLIC_BASE_URL=https://hoo66.top " + $remoteCommand
        }

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-Native -Command "ssh" -Arguments (@($sshArguments) + @($SshTarget, $remoteCommand))
        $stopwatch.Stop()
        Write-Output "release=$commitSha total_seconds=$([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1))"
    } finally {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryDirectory)
        if ($resolvedTemporary.StartsWith($temporaryParent, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedTemporary).StartsWith("couplechat-phone-deploy-", [StringComparison]::Ordinal)) {
            [IO.Directory]::Delete($resolvedTemporary, $true)
        }
    }
} finally {
    Pop-Location
}