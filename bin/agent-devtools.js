#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

function getPlatform() {
  const platform = process.platform;
  switch (platform) {
    case "darwin":
      return "darwin";
    case "linux":
      return "linux";
    case "win32":
      return "win32";
    default:
      throw new Error(`Unsupported platform: ${platform}`);
  }
}

function getArch() {
  const arch = process.arch;
  switch (arch) {
    case "arm64":
      return "arm64";
    case "x64":
      return "x64";
    default:
      throw new Error(`Unsupported architecture: ${arch}`);
  }
}

function getBinaryName(platform, arch) {
  const ext = platform === "win32" ? ".exe" : "";
  return `agent-devtools-${platform}-${arch}${ext}`;
}

const platform = getPlatform();
const arch = getArch();
const binaryName = getBinaryName(platform, arch);
const binaryPath = join(__dirname, binaryName);

if (!existsSync(binaryPath)) {
  console.error(`Binary not found: ${binaryPath}`);
  console.error("");
  console.error("The native binary was not downloaded during installation.");
  console.error("Try reinstalling:");
  console.error("  npm install @ohah/agent-devtools");
  console.error("");
  console.error("Or build from source:");
  console.error("  git clone https://github.com/ohah/agent-devtools");
  console.error("  cd agent-devtools");
  console.error("  zig build -Doptimize=ReleaseSafe");
  process.exit(1);
}

try {
  execFileSync(binaryPath, process.argv.slice(2), {
    stdio: "inherit",
    env: process.env,
  });
} catch (error) {
  if (error.status !== null) {
    process.exit(error.status);
  }
  throw error;
}
