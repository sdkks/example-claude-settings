#!/usr/bin/env npx tsx
/**
 * auto-approve.ts — PermissionRequest hook for Bash tool
 *
 * Pipeline:
 *   Stage 1: Fast structural allowlist (no LLM) — approves if every meaningful
 *            token is a safe tool, control-flow keyword, variable assignment, etc.
 *   Stage 2: Haiku category classifier (only when Stage 1 skips) — classifies
 *            what the command does and approves if all categories are safe.
 *
 * Tries Anthropic API first (home), then Bedrock (work), then CLI fallback.
 *
 * Outputs hookSpecificOutput JSON to stdout on allow, nothing on skip/error.
 * Side-effects: permissionDecisions.jsonl, permissionRequestHashes sentinel.
 */

import { parse as shellParse } from "shell-quote";
import { execFileSync } from "child_process";
import { appendFileSync, mkdirSync, rmdirSync, existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { createHash } from "crypto";
import { request } from "https";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Decision = "allow" | "skip";

interface StageResult {
  decision: Decision;
  stage: string;
  reason: string;
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const HOME = homedir();
const DECISIONS_LOG = `${HOME}/.claude/permissionDecisions.jsonl`;
const HASHES_FILE = `${HOME}/.claude/permissionRequestHashes`;
const LOCK_DIR = `${HOME}/.claude/permissionRequestHashes.lock.d`;
const HAIKU_TIMEOUT_MS = 15_000;

// Bedrock (work environment) — set these in your env
const BEDROCK_MODEL = process.env.BEDROCK_HAIKU_MODEL ?? "us.anthropic.claude-haiku-4-5-20251001-v1:0";
const BEDROCK_GATEWAY = process.env.BEDROCK_GATEWAY ?? "ai-gateway.example.com";
const BEDROCK_PATH = `/bedrock/model/${BEDROCK_MODEL}/invoke`;
const BEDROCK_TOKEN = process.env.ANTHROPIC_AUTH_TOKEN ?? "";

// Anthropic API (home environment)
const ANTHROPIC_BASE_URL = process.env.ANTHROPIC_BASE_URL ?? "https://api.anthropic.com";
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY ?? "";

// Dynamically discover haiku model from gateway so we don't hardcode aliases
// that may differ between litellm, 7-bridges, or real Anthropic.
let _discoveredHaikuModel: string | null = null;

function discoverHaikuModel(): Promise<string> {
  if (_discoveredHaikuModel) return Promise.resolve(_discoveredHaikuModel);

  return new Promise((resolve) => {
    const url = new URL("/v1/models", ANTHROPIC_BASE_URL);
    const isHttps = url.protocol === "https:";
    const httpModule = isHttps ? require("https") : require("http");
    const req = httpModule.request(
      {
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname,
        method: "GET",
        headers: {
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
        },
        timeout: 5_000,
      },
      (res: any) => {
        let data = "";
        res.on("data", (chunk: string) => (data += chunk));
        res.on("end", () => {
          try {
            const parsed = JSON.parse(data);
            const models = parsed.data || [];
            // Prefer the first model whose id contains "haiku" (case-insensitive)
            const haiku = models.find((m: any) =>
              typeof m.id === "string" && m.id.toLowerCase().includes("haiku")
            );
            if (haiku?.id) {
              _discoveredHaikuModel = haiku.id;
              resolve(haiku.id);
              return;
            }
          } catch {
            // fall through
          }
          resolve("claude-haiku-4-5"); // fallback
        });
      }
    );
    req.on("timeout", () => { req.destroy(); resolve("claude-haiku-4-5"); });
    req.on("error", () => resolve("claude-haiku-4-5"));
    req.end();
  });
}

// Categories Haiku may return — ones we consider safe
const SAFE_CATEGORIES = new Set([
  "file-read",
  "network-local",
  "build",
  "test",
  "process-inspect",
  "shell-control-flow",
  "version-manager",
  "package-run",
  "text-transform",
  "variable-assignment",
  "output-format",
]);

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

export type Segment = string[]; // ordered word tokens within one simple command

/**
 * Parse a shell command into segments separated by operators (&& || ; | & \n).
 * Within each segment, only word tokens are kept (operators and redirections dropped).
 * shell-quote handles quoting, $(...), globs correctly.
 */
export function parseSegments(command: string): Segment[] {
  // Strip redirections before parsing so they don't produce spurious word tokens
  let cleaned = command;
  // Strip comment lines (# ...) — shell-quote treats # as a comment token and
  // swallows all subsequent text including newlines
  cleaned = cleaned.replace(/^[^\S\n]*#[^\n]*/gm, "");
  // Strip heredocs: <<[-] 'DELIM' or DELIM (with optional trailing args on opener)
  cleaned = cleaned.replace(/<<-?\s*['"]?(\w+)['"]?[^\n]*\n[\s\S]*?\n\s*\1\b/g, "");
  cleaned = cleaned
    .replace(/\d*>>&?\s*\/dev\/null/g, "")
    .replace(/\d*>&\d+/g, "")
    .replace(/\d*>>?\/dev\/null/g, "")
    .replace(/\d*>>?\s*\S+/g, "")  // strip output redirects (> file, >> file)
    .replace(/<\s*\S+/g, "");      // strip input redirects (< file)

  const parsed = shellParse(cleaned);
  const segments: Segment[] = [];
  let current: string[] = [];

  for (const token of parsed) {
    if (typeof token === "string") {
      current.push(token);
    } else if (typeof token === "object" && "pattern" in token) {
      current.push((token as { pattern: string }).pattern);
    } else if (typeof token === "object" && "op" in token) {
      // Operator — flush current segment and start a new one
      if (current.length > 0) segments.push(current);
      current = [];
    }
  }
  if (current.length > 0) segments.push(current);
  return segments;
}

/** Flat list of all words, for curl localhost detection */
function allWords(segments: Segment[]): string[] {
  return segments.flat();
}

// ---------------------------------------------------------------------------
// Env-loader stripping
// ---------------------------------------------------------------------------

/**
 * Strip leading `source .env*` segments before evaluation.
 * e.g. `source .env && curl https://...` → `curl https://...`
 * These segments only load env vars and are safe by themselves; stripping them
 * lets stage1/stage2 evaluate the real work without tripping credential-access.
 */
export function stripEnvLoaders(command: string): string {
  // Handles: source .env, source .envrc, source .env.local, source .env.production, etc.
  // Strips one or more such segments chained with &&
  return command.replace(/^(\s*source\s+\.env[^\s]*\s*&&\s*)+/, "").trim();
}

// ---------------------------------------------------------------------------
// Stage 1: Structural allowlist
// ---------------------------------------------------------------------------

// Tools that are safe to run in any form (read-only / build / inspect)
const SAFE_TOOLS = new Set([
  // File reading
  "cat", "head", "tail", "less", "more",
  // Search
  "grep", "rg", "ag", "awk", "sed",
  // File system
  "ls", "find", "du", "stat", "file", "realpath", "dirname", "basename",
  // Text manipulation
  "echo", "printf", "tr", "cut", "paste", "sort", "uniq", "wc", "column",
  "tee", "fold", "fmt", "nl", "od", "expand", "unexpand", "comm", "diff", "join",
  // Crypto/encoding
  "md5sum", "sha256sum", "shasum", "base64", "iconv",
  // System inspect
  "which", "date", "pwd", "env", "ps", "uname", "codesign",
  // Math
  "bc", "expr",
  // Data
  "jq", "xargs", "strings",
  // Scripting runtimes (read/build use)
  "python3", "python", "node", "ruby",
  // Node toolchain
  "npm", "npx", "fnm", "nvm", "yarn", "pnpm",
  // Go toolchain
  "go", "gofmt", "goimports", "golangci-lint",
  // Git
  "git",
  // GitHub CLI
  "gh",
  // Kubernetes
  "kubectl",
  // Make
  "make",
  // Network (localhost only — checked separately)
  "curl", "wget",
  // Shell built-ins
  "cd", "true", "false", "exit", "source", ".", "test", "[",
  // File system mutations (block hook handles dangerous misuse)
  "mkdir", "rmdir", "chmod", "touch", "ln", "unlink", "tar", "zip", "unzip", "cp", "mv",
  // Process
  "sleep", "wait", "kill", "pkill", "killall", "timeout",
  // Terminal multiplexers
  "tmux", "screen",
  // Claude CLI (tool management, doctor, plugins — block hook handles misuse)
  "claude",
  // Misc tools
  "perl", "brew", "cargo", "rustc", "open", "cog",
]);

// Shell control-flow keywords and builtins
const CONTROL_FLOW = new Set([
  "if", "then", "else", "elif", "fi",
  "for", "while", "until", "do", "done",
  "case", "esac", "in",
  "function", "return", "local",
  "break", "continue",
  "!", "[[", "]]",
  "eval", "export", "unset", "set", "shopt",
]);


/**
 * Check the command word (first meaningful token) of a segment.
 * Arguments are not checked — anything after the command word is always allowed.
 */
export function checkCommand(cmd: string, allTokens: string[]): Decision {
  if (!cmd) return "allow";

  // Flags are always safe (they appear as first token of segment only when segment has just a flag)
  if (/^-/.test(cmd)) return "allow";

  // Strip leading env var prefixes: KEY=val cmd → cmd
  const stripped = cmd.replace(/^([A-Z_][A-Z_0-9]*=[^\s]*\s+)+/, "").trim();
  if (!stripped) return "allow";

  // Variable assignment standing alone as a command (FOO=bar with no following cmd)
  if (/^[a-zA-Z_][a-zA-Z_0-9]*=/.test(stripped)) return "allow";

  const word = stripped.split("/").pop()!; // handle /usr/bin/grep etc.

  // Shell control-flow keyword
  if (CONTROL_FLOW.has(word)) return "allow";

  // Natural-language annotation line (title-case, no shell metacharacters)
  if (/^[A-Z][a-zA-Z0-9 _,.()\-]*$/.test(stripped)) return "allow";

  // Known safe tool
  if (SAFE_TOOLS.has(word)) {
    if (word === "curl" || word === "wget") {
      const hasLocalhost = allTokens.some(t =>
        /https?:\/\/(localhost|127\.0\.0\.1|\[::1\])/.test(t)
      );
      return hasLocalhost ? "allow" : "skip";
    }
    return "allow";
  }

  // Script paths (./scripts/..., ~/scripts/..., absolute paths to .sh/.ts/.py)
  if (/^(\.\/|~\/|\/Users\/|\/home\/|\/tmp\/).*\.(sh|ts|py|js|rb)$/.test(stripped)) {
    return "allow";
  }

  return "skip";
}

export function stage1(command: string): StageResult {
  const segments = parseSegments(command);
  const all = allWords(segments);

  for (const segment of segments) {
    if (segment.length === 0) continue;
    // First non-empty token is the command; the rest are arguments (always safe)
    const cmdWord = segment[0];
    if (checkCommand(cmdWord, all) === "skip") {
      return { decision: "skip", stage: "stage1", reason: `command not in allowlist: ${cmdWord}` };
    }
  }
  return { decision: "allow", stage: "stage1", reason: "all commands structurally safe" };
}

// ---------------------------------------------------------------------------
// Stage 2: Haiku category classifier
// ---------------------------------------------------------------------------

const CLASSIFY_PROMPT = `You are a shell command classifier. Given a bash command, return ONLY a JSON array of category strings describing what it does. Use only these categories:

file-read         — reads files or stdin
file-write        — writes or modifies files (includes sed -i, tee to file, redirects to file)
network-local     — network calls to localhost/127.0.0.1 only
network-remote    — network calls to external hosts
build             — compiles, builds, or packages code (make, go build, npm run build, etc.)
test              — runs tests (make test, go test, npm test, vitest, etc.)
process-inspect   — reads process/system state (ps, env, uname, etc.)
shell-control-flow — loops, conditionals, variable assignments, pipelines
version-manager   — manages runtime versions (fnm, nvm, rbenv, etc.)
package-run       — runs a package binary (npx, go run, etc.)
text-transform    — transforms text in memory (grep, awk, sed without -i, jq, etc.)
variable-assignment — sets shell variables only
output-format     — formats/displays output (echo, printf, column, head, tail, etc.)
destructive       — deletes or overwrites data (rm, truncate, overwrite, dd, etc.)
credential-access — reads credential/secret files (~/.ssh, ~/.aws, ~/.gnupg, .env, etc.)
privilege-escalation — sudo, su, chmod +s, chown root, etc.
execute-downloaded — pipes downloaded content directly to a shell for execution
other             — anything not fitting above categories

Reply with ONLY a JSON array, no explanation. Example: ["file-read","text-transform"]

Command:
`;

function callHaikuBedrock(prompt: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      anthropic_version: "bedrock-2023-05-31",
      max_tokens: 200,
      messages: [{ role: "user", content: prompt }],
    });

    const req = request(
      {
        hostname: BEDROCK_GATEWAY,
        path: BEDROCK_PATH,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${BEDROCK_TOKEN}`,
          "anthropic-version": "2023-06-01",
          "Content-Length": Buffer.byteLength(body),
        },
        timeout: HAIKU_TIMEOUT_MS,
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          if (res.statusCode === 200) resolve(data);
          else reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 200)}`));
        });
      }
    );
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

async function callHaikuAPI(prompt: string): Promise<string> {
  const haikuModel = await discoverHaikuModel();
  return new Promise((resolve, reject) => {
    const url = new URL("/v1/messages", ANTHROPIC_BASE_URL);
    const body = JSON.stringify({
      model: haikuModel,
      max_tokens: 200,
      messages: [{ role: "user", content: prompt }],
    });

    const isHttps = url.protocol === "https:";
    const httpModule = isHttps ? require("https") : require("http");
    const req = httpModule.request(
      {
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
          "Content-Length": Buffer.byteLength(body),
        },
        timeout: HAIKU_TIMEOUT_MS,
      },
      (res: any) => {
        let data = "";
        res.on("data", (chunk: string) => (data += chunk));
        res.on("end", () => {
          if (res.statusCode === 200) resolve(data);
          else reject(new Error(`HTTP ${res.statusCode}: ${data.slice(0, 200)}`));
        });
      }
    );
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function withRetry<T>(fn: () => Promise<T>, maxRetries = 3, baseDelayMs = 200): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (attempt < maxRetries - 1) await sleep(baseDelayMs * 2 ** attempt);
    }
  }
  throw lastErr;
}

async function stage2(command: string): Promise<StageResult> {
  const prompt = CLASSIFY_PROMPT + command.slice(0, 1000);

  // Try Anthropic API first (home environment)
  if (ANTHROPIC_API_KEY) {
    try {
      const raw = await withRetry(() => callHaikuAPI(prompt));
      const result = extractCategories(raw);
      if (result) return result;
    } catch (err: any) {
      // Fall through to next method
    }
  }

  // Try Bedrock (work environment)
  if (BEDROCK_TOKEN) {
    try {
      const raw = await withRetry(() => callHaikuBedrock(prompt));
      const result = extractCategories(raw);
      if (result) return result;
    } catch (err: any) {
      // Fall through to CLI fallback
    }
  }

  // CLI fallback (last resort)
  try {
    const result = execFileSync(
      "claude",
      ["-p", "--model", "haiku", prompt],
      { timeout: HAIKU_TIMEOUT_MS, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
    );
    const match = result.match(/\[.*\]/s);
    if (!match) return { decision: "skip", stage: "stage2", reason: "haiku returned no JSON array" };
    const categories: string[] = JSON.parse(match[0]);
    const unsafe = categories.filter(c => !SAFE_CATEGORIES.has(c));
    if (unsafe.length === 0) {
      return { decision: "allow", stage: "stage2", reason: `categories: ${categories.join(", ")}` };
    }
    return { decision: "skip", stage: "stage2", reason: `unsafe categories: ${unsafe.join(", ")}` };
  } catch (err: any) {
    const msg = err?.code === "ETIMEDOUT" ? "haiku timeout" : `haiku error: ${err?.message ?? err}`;
    return { decision: "skip", stage: "stage2", reason: msg };
  }
}

function extractCategories(raw: string): StageResult | null {
  try {
    const parsed = JSON.parse(raw);
    const text = parsed?.content?.[0]?.text ?? "";
    const match = text.match(/\[.*\]/s);
    if (!match) return null;
    const categories: string[] = JSON.parse(match[0]);
    const unsafe = categories.filter(c => !SAFE_CATEGORIES.has(c));
    if (unsafe.length === 0) {
      return { decision: "allow", stage: "stage2", reason: `categories: ${categories.join(", ")}` };
    }
    return { decision: "skip", stage: "stage2", reason: `unsafe categories: ${unsafe.join(", ")}` };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Sentinel: deduplication across parallel hook invocations
// ---------------------------------------------------------------------------

function claimHash(hash: string): boolean {
  const now = Math.floor(Date.now() / 1000);
  const WINDOW = 5;

  // Atomic claim via mkdir
  try {
    mkdirSync(LOCK_DIR);
  } catch {
    // Another hook holds the lock — spin up to 100ms then read-check
    for (let i = 0; i < 10; i++) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      if (!existsSync(LOCK_DIR)) break;
    }
    // Read-only check: if hash is already there, skip
    return !isHashPresent(hash, now, WINDOW);
  }

  try {
    const present = isHashPresent(hash, now, WINDOW);
    if (!present) {
      appendFileSync(HASHES_FILE, `${hash} ${now}\n`);
    }
    return !present;
  } finally {
    try { rmdirSync(LOCK_DIR); } catch {}
  }
}

function isHashPresent(hash: string, now: number, window: number): boolean {
  try {
    const lines: string[] = readFileSync(HASHES_FILE, "utf8").split("\n");
    return lines.some(line => {
      const [h, ts] = line.trim().split(" ");
      return h === hash && now - parseInt(ts, 10) <= window;
    });
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

function logDecision(hook: string, command: string, stage: string, reason: string) {
  const entry = JSON.stringify({
    hook,
    stage,
    reason,
    command,
    ts: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  });
  try { appendFileSync(DECISIONS_LOG, entry + "\n"); } catch {}
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

function outputAllow() {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" },
    },
  }));
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  let raw = "";
  try {
    raw = readFileSync("/dev/stdin", "utf8");
  } catch {
    process.exit(0);
  }

  let input: any;
  try {
    input = JSON.parse(raw);
  } catch {
    process.exit(0);
  }

  const command: string = input?.tool_input?.command;
  if (!command || typeof command !== "string") process.exit(0);

  const hash = createHash("sha256").update(command).digest("hex").slice(0, 16);
  if (!claimHash(hash)) process.exit(0); // already approved by a parallel instance

  const effectiveCommand = stripEnvLoaders(command);

  // Stage 1
  const s1 = stage1(effectiveCommand);
  if (s1.decision === "allow") {
    logDecision("auto-approve-structural", command, s1.stage, s1.reason);
    outputAllow();
    process.exit(0);
  }

  // Stage 2
  const s2 = await stage2(effectiveCommand);
  if (s2.decision === "allow") {
    logDecision("auto-approve-haiku", command, s2.stage, s2.reason);
    outputAllow();
    process.exit(0);
  }

  // Both stages skipped — fall through to user prompt
  process.exit(0);
}

// Only run when executed directly, not when imported by tests
if (require.main === module) {
  main().catch(() => process.exit(0));
}
