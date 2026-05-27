/**
 * auto-approve.test.ts
 *
 * Tests for the tokenizer and stage-1 structural allowlist.
 * Stage-2 (Haiku) is not tested here — it requires a live LLM call.
 */

import { describe, it, expect } from "vitest";
import { parseSegments, checkCommand, stage1, stripEnvLoaders } from "./auto-approve.js";

// ---------------------------------------------------------------------------
// Fixtures: commands that SHOULD be auto-approved by stage-1
// ---------------------------------------------------------------------------

const SHOULD_ALLOW = [
  // Basic loops
  "for f in ~/.claude/hooks/*.sh; do echo \"=== $f ===\"; head -3 \"$f\"; done",
  "for i in 1 2 3; do echo \"item $i\"; done",
  "while IFS= read -r line; do echo \"$line\" | grep -c 'hook'; done < ~/.claude/hooks/auto-approve-haiku-fallback.sh | tail -5",

  // if/else
  "if [ -f ~/.claude/settings.json ]; then echo 'exists'; else echo 'missing'; fi",

  // Variable assignment + for
  "FILTER=hook; for f in ~/.claude/hooks/*.sh; do echo \"$f\" | grep \"$FILTER\"; done",

  // cat | awk | head
  "cat ~/.claude/hooks/auto-approve-haiku-fallback.sh | awk '/^if/ {print NR, $0}' | head -10",

  // cat -n | sed (previously broken in bash hooks)
  "cat -n /Users/example-user/Dev/project/src/module.py | sed -n '25,25p'",

  // cat | sed | grep | head
  "cat ~/.claude/hooks/auto-approve-compound-git.sh | sed 's/^[[:space:]]*//' | grep -v '^#' | grep -v '^$' | head -10",

  // Env var prefixes
  "GONOSUMCHECK=* go version && go env GOPATH | head -1",
  "NODE_ENV=test node --version && npm --version",
  "DEBUG=1 make test",

  // Go toolchain
  "go version",
  "go test ./...",
  "gofmt -l .",

  // npm/npx/fnm
  "npm --version",
  "npx tsx --version",
  "fnm use",

  // git with -C
  "git -C ~/.claude log --oneline -3",
  "git -C ~/.claude log --oneline -3 | head -5",

  // Redirections (2>&1, 2>/dev/null) used to produce spurious tokens in bash hooks
  "cd /tmp && fnm use 2>/dev/null; npx tsx foo.ts 2>&1 | tail -30",
  "go test ./... 2>&1 | head -20",

  // localhost curl
  "curl -s http://localhost:8080/health 2>/dev/null | head -3",
  "curl -s http://127.0.0.1:3000/api/status | jq .",

  // for loop with find + wc
  "for ext in sh json md; do count=$(find ~/.claude -name \"*.${ext}\" | wc -l); echo \"${ext}: ${count}\"; done",

  // nested for + if + grep
  "for f in ~/.claude/hooks/*.sh; do if grep -q 'decision' \"$f\"; then echo \"NEW: $f\"; else echo \"OLD: $f\"; fi; done",

  // Previously stuck: fnm + npx tsx + redirections
  "cd /Users/example-user/.ocak/worktree/2026-05-06-example-research && fnm use 2>/dev/null; npx tsx /Users/example-user/Dev/ocak/agents/skills/deep-research-visualize/scripts/reportPipelineEmitter.ts --groupings assets/deep-research/example-project/groupings.json --theme editorial 2>&1 | tail -30",

  // Annotation line at end
  "head -3 ~/.claude/hooks/auto-approve-haiku-fallback.sh\nVerify page-4 quality",

  // Variable + if
  "LOG=~/.claude/permissionPrompts.jsonl; if [ -f \"$LOG\" ]; then wc -l \"$LOG\"; else echo 'no log yet'; fi",

  // python3 pipeline
  "cat /tmp/data.json | python3 -m json.tool | head -20",

  // jq
  "jq '.hooks.PermissionRequest' ~/.claude/settings.json",

  // git log + grep
  "git log --oneline -10 | grep fix",

  // make with safe target
  "make test",
  "make build",
  "cd ~/Dev/myproject && make lint",

  // python3 heredoc (body must not be tokenized as commands)
  "python3 - << 'PYEOF'\nimport json\ngroupings_path = '/tmp/foo.json'\nwith open(groupings_path) as f:\n    data = json.load(f)\nprint(data)\nPYEOF",
  "python3 << 'EOF'\nimport re, json\nfrom collections import defaultdict\nprint('done')\nEOF",

  // eval (e.g. fnm env, nvm env)
  'eval "$(fnm env)"',
  'eval "$(fnm env --use-on-cd --shell zsh)"',
  'eval "$(fnm env)" && node --version',

  // mkdir / rmdir / chmod / tar
  "mkdir -p ~/.ocak/worktree/2026-05-06/{dim-01,dim-02,dim-03}",
  "rmdir /tmp/foo && echo done",
  "chmod +x ~/.claude/scripts/auto-approve.ts && echo ok",
  "tar -czf out.tar.gz -C src . && echo created",
  "cd /tmp && tar -xzf archive.tar.gz",

  // Shell interpreters running scripts
  "bash scripts/foo.sh",
  "bash scripts/assemble-spec.sh /tmp/foo && echo done",
  "sh -c 'echo hi'",

  // Internal / dev CLIs
  "cicd boilerplate generate 2>&1",
  "semgrep scan --config auto",
  "openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 1",

  // Linux package query
  "apt-cache show pdf2htmlex",
  "dpkg -l | grep nginx",

  // Python tooling
  "pip install -r requirements.txt",
  "pip3 list | grep flask",

  // Transparent prefix wrappers — must look at the next token
  "time go test ./...",
  "time -p make build",
  "nice -n 10 npm run build",
  "nohup go run main.go",
  "command -v fnm",

  // rm — block hook is the safety gate; stage1 should not send rm to Haiku
  "rm -f /tmp/foo.pid",
  "rm /tmp/scratch.json",
  "rm -rf /tmp/build",
  "kill $(cat /tmp/foo.pid) 2>/dev/null; rm -f /tmp/foo.pid; open /Users/example-user/foo.html",

  // Multi-line scripts: leading var assignments + awk + bash + redirects
  "SCRATCH=/tmp/a.md\nSPEC_DIR=/tmp/b\nawk '/<!-- end -->/' \"$SCRATCH\" > \"$SPEC_DIR/out.md\"\nbash scripts/assemble.sh \"$SPEC_DIR\"",
  "awk '/foo/ {print}' /tmp/in.md > /tmp/out.md && bash $OCAK_DIR/scripts/assemble-spec.sh /tmp/spec",
];

// ---------------------------------------------------------------------------
// Fixtures: commands stage-1 should NOT approve (fall through to Haiku)
// ---------------------------------------------------------------------------

const SHOULD_SKIP_STAGE1 = [
  // External curl (no localhost)
  "curl -s https://example.com | head -5",
  "wget https://example.com/script.sh",

  // Completely unknown tool
  "myCustomTool --flag value",
];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("parseSegments", () => {
  it("splits on &&", () => {
    const segs = parseSegments("git log && echo done");
    expect(segs).toHaveLength(2);
    expect(segs[0]).toContain("git");
    expect(segs[1]).toContain("echo");
  });

  it("splits on pipe", () => {
    const segs = parseSegments("cat foo | head -3");
    expect(segs).toHaveLength(2);
    expect(segs[0][0]).toBe("cat");
    expect(segs[1][0]).toBe("head");
  });

  it("splits on semicolon", () => {
    const segs = parseSegments("fnm use; npx tsx foo.ts");
    expect(segs).toHaveLength(2);
  });

  it("strips 2>/dev/null before tokenizing", () => {
    const segs = parseSegments("fnm use 2>/dev/null");
    expect(segs.flat()).not.toContain("/dev/null");
    expect(segs.flat()).toContain("fnm");
  });

  it("strips 2>&1", () => {
    const segs = parseSegments("go test ./... 2>&1 | head -20");
    const flat = segs.flat();
    expect(flat).not.toContain("1");
    expect(flat).toContain("go");
    expect(flat).toContain("head");
  });

  it("handles cat -n correctly", () => {
    const segs = parseSegments("cat -n /tmp/foo.py | sed -n '1,5p'");
    expect(segs[0]).toContain("cat");
    expect(segs[0]).toContain("-n");
    expect(segs[1]).toContain("sed");
  });
});

describe("checkCommand", () => {
  it("allows flags", () => expect(checkCommand("-n", [])).toBe("allow"));
  it("allows control flow: for", () => expect(checkCommand("for", [])).toBe("allow"));
  it("allows control flow: if", () => expect(checkCommand("if", [])).toBe("allow"));
  it("allows control flow: do", () => expect(checkCommand("do", [])).toBe("allow"));
  it("allows variable assignment", () => expect(checkCommand("FOO=bar", [])).toBe("allow"));
  it("allows env-prefixed command: GONOSUMCHECK=* go", () => expect(checkCommand("GONOSUMCHECK=* go", [])).toBe("allow"));
  it("allows annotation line", () => expect(checkCommand("Verify page-4 quality", [])).toBe("allow"));
  it("allows known tools: git", () => expect(checkCommand("git", [])).toBe("allow"));
  it("allows known tools: fnm", () => expect(checkCommand("fnm", [])).toBe("allow"));
  it("allows known tools: npx", () => expect(checkCommand("npx", [])).toBe("allow"));
  it("allows known tools: make", () => expect(checkCommand("make", [])).toBe("allow"));
  it("allows known tools: go", () => expect(checkCommand("go", [])).toBe("allow"));
  it("allows known tools: rm", () => expect(checkCommand("rm", [])).toBe("allow"));
  it("allows known tools: pip", () => expect(checkCommand("pip", [])).toBe("allow"));
  it("allows known tools: bash", () => expect(checkCommand("bash", [])).toBe("allow"));
  it("allows localhost curl", () => expect(checkCommand("curl", ["curl", "http://localhost:8080/api"])).toBe("allow"));
  it("blocks external curl", () => expect(checkCommand("curl", ["curl", "https://example.com"])).toBe("skip"));
  it("blocks unknown tool", () => expect(checkCommand("myCustomTool", [])).toBe("skip"));
});

describe("stage1: should allow", () => {
  for (const cmd of SHOULD_ALLOW) {
    it(cmd.slice(0, 80), () => {
      expect(stage1(cmd).decision).toBe("allow");
    });
  }
});

describe("stage1: should skip (fall through to Haiku)", () => {
  for (const cmd of SHOULD_SKIP_STAGE1) {
    it(cmd.slice(0, 80), () => {
      expect(stage1(cmd).decision).toBe("skip");
    });
  }
});

// ---------------------------------------------------------------------------
// stripEnvLoaders
// ---------------------------------------------------------------------------

describe("stripEnvLoaders", () => {
  // Basic stripping
  it("strips source .env &&", () => {
    expect(stripEnvLoaders("source .env && curl -s https://example.com")).toBe("curl -s https://example.com");
  });

  it("strips source .envrc &&", () => {
    expect(stripEnvLoaders("source .envrc && npm run build")).toBe("npm run build");
  });

  it("strips source .env.local &&", () => {
    expect(stripEnvLoaders("source .env.local && node index.js")).toBe("node index.js");
  });

  it("strips source .env.production &&", () => {
    expect(stripEnvLoaders("source .env.production && npm start")).toBe("npm start");
  });

  // Chained loaders
  it("strips multiple chained env sources", () => {
    expect(stripEnvLoaders("source .env.local && source .env && curl https://api.example.com")).toBe("curl https://api.example.com");
  });

  // Whitespace tolerance
  it("handles extra whitespace around &&", () => {
    expect(stripEnvLoaders("source .env  &&  echo hello")).toBe("echo hello");
  });

  // No-op cases
  it("leaves non-env source untouched", () => {
    expect(stripEnvLoaders("source ~/.bashrc && echo hi")).toBe("source ~/.bashrc && echo hi");
  });

  it("leaves plain command untouched", () => {
    expect(stripEnvLoaders("npm run build")).toBe("npm run build");
  });

  it("leaves empty string untouched", () => {
    expect(stripEnvLoaders("")).toBe("");
  });

  // Real-world patterns
  it("real: source .env + curl with basic auth", () => {
    const cmd = 'source .env && curl -s -u "$JIRA_EMAIL:$JIRA_READ_PAT" "https://example.atlassian.net/rest/api/3/myself"';
    expect(stripEnvLoaders(cmd)).toBe('curl -s -u "$JIRA_EMAIL:$JIRA_READ_PAT" "https://example.atlassian.net/rest/api/3/myself"');
  });

  it("real: source .env + echo + curl compound", () => {
    const cmd = 'source .env && echo "=== v2 myself ===" && curl -s -u "$JIRA_EMAIL:$JIRA_READ_PAT" "https://example.atlassian.net/rest"';
    expect(stripEnvLoaders(cmd)).toBe('echo "=== v2 myself ===" && curl -s -u "$JIRA_EMAIL:$JIRA_READ_PAT" "https://example.atlassian.net/rest"');
  });
});

// ---------------------------------------------------------------------------
// stage1 + stripEnvLoaders integration: safe commands that only needed stripping
// ---------------------------------------------------------------------------

describe("stage1 after stripEnvLoaders: should allow", () => {
  const ENV_LOADER_ALLOW = [
    // npm/make/node after source .env — these were manual-approvals before fix
    "source .env && npm run build",
    "source .envrc && make test",
    "source .env.local && node --version",
    "source .env && fnm use && npm install",
    // Chained loaders
    "source .env.local && source .env && npm run dev",
    // With env-var prefix too
    "source .env && NODE_ENV=test npm test",
  ];

  for (const cmd of ENV_LOADER_ALLOW) {
    it(cmd.slice(0, 80), () => {
      expect(stage1(stripEnvLoaders(cmd)).decision).toBe("allow");
    });
  }
});

describe("stage1 after stripEnvLoaders: external curl still skips", () => {
  const ENV_LOADER_SKIP = [
    // External curl — network-remote, intentionally not stage1-approved even after stripping
    'source .env && curl -s "https://example.atlassian.net/rest/api/3/myself"',
    'source .env && curl -s "https://api.atlassian.com/oauth/token/accessible-resources"',
  ];

  for (const cmd of ENV_LOADER_SKIP) {
    it(cmd.slice(0, 80), () => {
      expect(stage1(stripEnvLoaders(cmd)).decision).toBe("skip");
    });
  }
});
