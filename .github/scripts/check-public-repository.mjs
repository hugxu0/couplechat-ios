#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { lstatSync, readFileSync, readlinkSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const signingOrKeyExtension =
  /\.(?:pem|key|ppk|cer|crt|csr|der|p12|pfx|p8|jks|keystore|mobileprovision|provisionprofile)$/iu;
const backupOrBuildExtension =
  /\.(?:bak|backup|dump|pgdump|dmp|sql|sqlite|sqlite3|db|ipa|xcarchive|xcresult|tar|tgz|gz|zip|7z)$/iu;
const udidFileName = /(?:^|[._-])udid(?:[._-]|$)/iu;
const environmentFileName = /^\.env(?:\.|$)/iu;
const exampleEnvironmentFileName = /^\.env(?:\.[A-Za-z0-9_-]+)*\.example$/u;

const privateKeyHeader = new RegExp(
  "-----BEGIN " +
    "(?:(?:RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED) )?" +
    "PRIVATE KEY(?: BLOCK)?-----",
  "gu",
);

const tokenPatterns = [
  /\bgh[pousr]_[A-Za-z0-9]{30,}\b/gu,
  /\bgithub_pat_[A-Za-z0-9_]{50,}\b/gu,
  /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/gu,
  /\bAIza[0-9A-Za-z_-]{35}\b/gu,
  /\bxox[baprs]-[0-9A-Za-z-]{20,}\b/gu,
  /\bsk_live_[0-9A-Za-z]{20,}\b/gu,
  /\bsk-(?:proj-|svcacct-|ant-)?[0-9A-Za-z_-]{32,}\b/gu,
  /\beyJ[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}\b/gu,
];

const udidAssignment = new RegExp(
  "\\bUDID\\b\\s*[:=]\\s*[\"']?" +
    "(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})" +
    "\\b",
  "gu",
);
const ipv4Candidate = /(^|[^0-9])((?:[0-9]{1,3}\.){3}[0-9]{1,3})(?![0-9])/gmu;

function finding(category, file) {
  return { category, file };
}

export function classifyTrackedPath(relativePath) {
  const normalized = relativePath.replaceAll("\\", "/");
  const baseName = path.posix.basename(normalized);
  const findings = [];

  if (
    environmentFileName.test(baseName) &&
    !exampleEnvironmentFileName.test(baseName)
  ) {
    findings.push(finding("non-example-environment-file", relativePath));
  }
  if (signingOrKeyExtension.test(baseName)) {
    findings.push(finding("signing-or-private-key-file", relativePath));
  }
  if (backupOrBuildExtension.test(baseName)) {
    findings.push(finding("backup-or-build-artifact", relativePath));
  }
  if (udidFileName.test(baseName)) {
    findings.push(finding("device-udid-file", relativePath));
  }
  return findings;
}

function isAllowedNonSecretAddress(address) {
  const octets = address.split(".").map(Number);
  if (octets.length !== 4 || octets.some((octet) => octet < 0 || octet > 255)) {
    return true;
  }
  if (octets[0] === 127) return true;
  return address === "0.0.0.0";
}

export function scanTrackedText(relativePath, text) {
  const findings = [];
  if (privateKeyHeader.test(text)) {
    findings.push(finding("private-key-header", relativePath));
  }
  privateKeyHeader.lastIndex = 0;

  for (const pattern of tokenPatterns) {
    if (pattern.test(text)) {
      findings.push(finding("high-confidence-token", relativePath));
    }
    pattern.lastIndex = 0;
  }
  if (udidAssignment.test(text)) {
    findings.push(finding("device-udid-value", relativePath));
  }
  udidAssignment.lastIndex = 0;

  ipv4Candidate.lastIndex = 0;
  for (let match = ipv4Candidate.exec(text); match; match = ipv4Candidate.exec(text)) {
    if (!isAllowedNonSecretAddress(match[2])) {
      findings.push(finding("non-loopback-ipv4-literal", relativePath));
      break;
    }
  }
  ipv4Candidate.lastIndex = 0;
  return findings;
}

function readTrackedText(absolutePath) {
  const stats = lstatSync(absolutePath);
  if (stats.isSymbolicLink()) {
    return readlinkSync(absolutePath, "utf8");
  }
  if (!stats.isFile()) {
    return null;
  }

  const bytes = readFileSync(absolutePath);
  if (bytes.includes(0)) {
    return null;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

export function scanTrackedFiles(repositoryRoot, trackedFiles) {
  const findings = [];
  for (const relativePath of trackedFiles) {
    findings.push(...classifyTrackedPath(relativePath));
    const absolutePath = path.join(repositoryRoot, relativePath);
    let text;
    try {
      text = readTrackedText(absolutePath);
    } catch {
      continue;
    }
    if (text !== null) {
      findings.push(...scanTrackedText(relativePath, text));
    }
  }

  const unique = new Map();
  for (const item of findings) {
    unique.set(`${item.category}\0${item.file}`, item);
  }
  return [...unique.values()].sort(
    (left, right) =>
      left.file.localeCompare(right.file) ||
      left.category.localeCompare(right.category),
  );
}

function listTrackedFiles(repositoryRoot) {
  // Include non-ignored untracked files so the local pre-commit check sees new
  // files before they enter Git. In CI the checkout is already fully tracked.
  const output = execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    {
    cwd: repositoryRoot,
    encoding: "buffer",
    stdio: ["ignore", "pipe", "inherit"],
    },
  );
  return output
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
}

function run() {
  const repositoryRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../..",
  );
  const findings = scanTrackedFiles(repositoryRoot, listTrackedFiles(repositoryRoot));
  if (findings.length > 0) {
    for (const item of findings) {
      process.stderr.write(
        `[public-repository-safety] category=${item.category} file=${JSON.stringify(item.file)}\n`,
      );
    }
    process.stderr.write(
      `[public-repository-safety] rejected ${findings.length} category/file finding(s)\n`,
    );
    process.exitCode = 1;
    return;
  }
  process.stdout.write(
    "[public-repository-safety] current tracked tree passed; Git history is not inspected or erased\n",
  );
}

if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  run();
}
