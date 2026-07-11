param(
  [string]$RemoteTarget = "root@82.40.34.107",
  [int]$TunnelPort = 55433,
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
$serverRoot = Split-Path -Parent $PSScriptRoot
$remoteEnv = "/opt/couplechat-ios/server/.env"
$tunnel = $null

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
  throw "SSH tunnel did not become ready on 127.0.0.1:$Port"
}

try {
  if (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $TunnelPort -State Listen -ErrorAction SilentlyContinue) {
    throw "Local port $TunnelPort is already in use"
  }

  $databaseLine = (& ssh -o BatchMode=yes -o ConnectTimeout=8 $RemoteTarget "grep '^DATABASE_URL=' $remoteEnv").Trim()
  if (-not $databaseLine.StartsWith("DATABASE_URL=")) {
    throw "Unable to read production DATABASE_URL from RFCHost"
  }

  $databaseUri = [System.UriBuilder]::new($databaseLine.Substring("DATABASE_URL=".Length))
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
  $env:CLOUD_DB_DEBUG = "true"
  $env:SCHEDULED_JOBS_ENABLED = "false"
  $env:UPLOADS_WRITABLE = "false"
  $env:PUSH_ENABLED = "false"

  Push-Location $serverRoot
  try {
    if ($CheckOnly) {
      @'
const { Client } = require("pg");
(async () => {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  const row = (await client.query(`SELECT
    (SELECT count(*) FROM messages)::bigint AS messages,
    (SELECT count(*) FROM ai_memory)::bigint AS memories`)).rows[0];
  console.log(`cloud-db-ok messages=${row.messages} memories=${row.memories}`);
  await client.end();
})().catch((error) => {
  console.error(`cloud-db-check-failed: ${error.message}`);
  process.exit(1);
});
'@ | node -
      if ($LASTEXITCODE -ne 0) { throw "Cloud database connection check failed" }
    } else {
      Write-Host "Cloud database debug mode: http://127.0.0.1:8080/ai-debug"
      Write-Host "Safety switches: scheduled jobs=off, Bark push=off, uploads=read-only"
      & npx.cmd tsx watch scripts/cloud-ai-server.ts
      if ($LASTEXITCODE -ne 0) { throw "Local debug server exited with code $LASTEXITCODE" }
    }
  } finally {
    Pop-Location
  }
} finally {
  if ($tunnel -and -not $tunnel.HasExited) {
    Stop-Process -Id $tunnel.Id -Force
  }
}
