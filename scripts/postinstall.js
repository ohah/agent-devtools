import { createWriteStream, chmodSync, existsSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { get as httpsGet } from "node:https";
import { get as httpGet } from "node:http";
import { createRequire } from "node:module";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const pkg = require("../package.json");

function getPlatform() {
  switch (process.platform) {
    case "darwin":
      return "darwin";
    case "linux":
      return "linux";
    case "win32":
      return "win32";
    default:
      return null;
  }
}

function getArch() {
  switch (process.arch) {
    case "arm64":
      return "arm64";
    case "x64":
      return "x64";
    default:
      return null;
  }
}

function getBinaryName(platform, arch) {
  const ext = platform === "win32" ? ".exe" : "";
  return `agent-devtools-${platform}-${arch}${ext}`;
}

function download(url) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith("https") ? httpsGet : httpGet;
    client(url, (response) => {
      // Follow redirects (GitHub releases redirect to S3)
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        download(response.headers.location).then(resolve).catch(reject);
        return;
      }

      if (response.statusCode !== 200) {
        reject(new Error(`Download failed with status ${response.statusCode}: ${url}`));
        return;
      }

      resolve(response);
    }).on("error", reject);
  });
}

async function main() {
  const platform = getPlatform();
  const arch = getArch();

  if (!platform || !arch) {
    console.warn(`[agent-devtools] Unsupported platform: ${process.platform}-${process.arch}`);
    console.warn("[agent-devtools] You can build from source: https://github.com/ohah/agent-devtools");
    process.exit(0);
  }

  const binaryName = getBinaryName(platform, arch);
  const binDir = join(__dirname, "..", "bin");
  const binaryPath = join(binDir, binaryName);

  // Skip if binary already exists (e.g., local development)
  if (existsSync(binaryPath)) {
    console.log(`[agent-devtools] Binary already exists: ${binaryName}`);
    return;
  }

  const version = pkg.version;
  const url = `https://github.com/ohah/agent-devtools/releases/download/v${version}/${binaryName}`;

  console.log(`[agent-devtools] Downloading ${binaryName} v${version}...`);

  try {
    if (!existsSync(binDir)) {
      mkdirSync(binDir, { recursive: true });
    }

    const response = await download(url);
    const file = createWriteStream(binaryPath);

    await new Promise((resolve, reject) => {
      response.pipe(file);
      file.on("finish", () => {
        file.close(resolve);
      });
      file.on("error", reject);
    });

    // Make executable on Unix
    if (platform !== "win32") {
      chmodSync(binaryPath, 0o755);
    }

    console.log(`[agent-devtools] Successfully installed ${binaryName}`);
  } catch (error) {
    console.warn(`[agent-devtools] Failed to download binary: ${error.message}`);
    console.warn("");
    console.warn("You can build from source instead:");
    console.warn("  git clone https://github.com/ohah/agent-devtools");
    console.warn("  cd agent-devtools");
    console.warn("  zig build -Doptimize=ReleaseSafe");
    console.warn("");
    console.warn("Then copy the binary to:");
    console.warn(`  ${binaryPath}`);
    // Don't fail the install — the user can still build manually
    process.exit(0);
  }
}

main();
