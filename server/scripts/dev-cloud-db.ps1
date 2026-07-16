param(
  [string]$RemoteTarget = "",
  [int]$TunnelPort = 55433,
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
$serverRoot = Split-Path -Parent $PSScriptRoot
$remoteEnv = "/opt/couplechat-ios/server/.env"
$tunnel = $null
$previousDatabaseUrl = $env:DATABASE_URL

if (-not $CheckOnly) {
  throw "Production database access is check-only; starting a debug server through this script is disabled"
}

if ([string]::IsNullOrWhiteSpace($RemoteTarget)) {
  throw "-RemoteTarget is required and must name an SSH alias from the operator's private SSH config"
}

if ($RemoteTarget -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
  throw "-RemoteTarget must be an SSH alias, not a user, IP address, or inline hostname"
}

if ($TunnelPort -lt 1024 -or $TunnelPort -gt 65535) {
  throw "-TunnelPort must be between 1024 and 65535"
}

function Wait-LocalPort([int]$Port, [int]$Attempts = 30) {
  for ($i = 0; $i -lt $Attempts; $i += 1) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
      $client.Connect("127.0.0.1", $Port)
      return
    } catch {
      Start-Sleep -Milliseconds 200
    } finally {
      $client.Dispose()
    }
  }
  throw "SSH tunnel did not become ready on the selected local port"
}

try {
  if (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $TunnelPort -State Listen -ErrorAction SilentlyContinue) {
    throw "The selected local tunnel port is already in use"
  }

  $databaseLine = (& ssh -o BatchMode=yes -o ConnectTimeout=8 $RemoteTarget "grep '^READONLY_DATABASE_URL=' $remoteEnv").Trim()
  if ($LASTEXITCODE -ne 0 -or -not $databaseLine.StartsWith("READONLY_DATABASE_URL=")) {
    throw "The target does not expose a dedicated READONLY_DATABASE_URL"
  }

  $databaseUri = [System.UriBuilder]::new($databaseLine.Substring("READONLY_DATABASE_URL=".Length))
  if ($databaseUri.Scheme -notin @("postgres", "postgresql")) {
    throw "READONLY_DATABASE_URL must use the postgres or postgresql scheme"
  }
  $databaseUri.Host = "127.0.0.1"
  $databaseUri.Port = $TunnelPort

  $tunnel = Start-Process -FilePath "ssh" -ArgumentList @(
    "-N",
    "-o", "BatchMode=yes",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ServerAliveInterval=30",
    "-L", "127.0.0.1:${TunnelPort}:127.0.0.1:5432",
    $RemoteTarget
  ) -WindowStyle Hidden -PassThru
  Wait-LocalPort $TunnelPort

  $env:DATABASE_URL = $databaseUri.Uri.AbsoluteUri

  Push-Location $serverRoot
  try {
    @'
const { Client } = require("pg");

(async () => {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  let transactionOpen = false;
  try {
    await client.connect();
    await client.query("BEGIN TRANSACTION READ ONLY");
    transactionOpen = true;
    await client.query("SET LOCAL statement_timeout = '5s'");
    const row = (await client.query(`SELECT
      current_setting('transaction_read_only') AS read_only,
      COALESCE((SELECT max(version) FROM schema_migrations), 0)::int AS schema_version`)).rows[0];
    if (row.read_only !== "on") throw new Error("database transaction is not read-only");
    await client.query("ROLLBACK");
    transactionOpen = false;
    console.log(`cloud-db-readonly-ok schema=${row.schema_version}`);
  } finally {
    if (transactionOpen) await client.query("ROLLBACK").catch(() => {});
    await client.end().catch(() => {});
  }
})().catch((error) => {
  console.error(`cloud-db-check-failed: ${error.message}`);
  process.exit(1);
});
'@ | node -
    if ($LASTEXITCODE -ne 0) { throw "Cloud database read-only check failed" }
  } finally {
    Pop-Location
  }
} finally {
  $env:DATABASE_URL = $previousDatabaseUrl
  if ($tunnel -and -not $tunnel.HasExited) {
    Stop-Process -Id $tunnel.Id -Force
  }
}
