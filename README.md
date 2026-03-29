<p align="center">
  <img src="docs/PeonNotify.png" alt="PeonNotify" width="600">
</p>

# PeonNotify

**Stop babysitting your terminal. Ship faster. Learn permanently.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-lightgrey)]()
[![Claude Code](https://img.shields.io/badge/Claude%20Code-hooks-blueviolet)]()

You spend hours watching Claude Code's terminal. Alt-tabbing to check if it's done. Missing permission prompts. Shipping unreviewed code. Losing everything you learned when the session ends. Sessions leak memory and crash overnight.

**PeonNotify fixes all of that in one install.** Warcraft III Peon voice lines give you real-time audio awareness while five hook systems work in the background:

| System | What It Does | Why It Matters |
|--------|-------------|----------------|
| **Audio Dispatch** | Plays iconic Peon sounds for every Claude Code event | Know what's happening without looking at your screen |
| **CodeGuard** | Lints every file write + AI code review | Catch bugs before they ship -- automatically |
| **DocGuard** | Auto-generates changelogs from your sessions | Never write "updated stuff" in a commit message again |
| **Watchdog** | Monitors memory, kills and restarts leaked sessions | Leave Claude running overnight without worry |
| **Obsidian** | Builds a knowledge graph from every session | Your decisions, patterns, and lessons compound over time |

**One install. Zero config changes to Claude Code.** Works on macOS, Linux, and WSL.

### What developers are doing with it

- Running Claude overnight and waking up to a knowledge graph of decisions, patterns, and bugs
- Catching security issues and logic errors automatically on every file write
- Never writing another "updated stuff" commit message — changelogs write themselves
- Walking away from the terminal and knowing by sound alone when Claude needs approval
- Leaving sessions running for hours without memory crashes killing their work

## Quick Start

```bash
git clone https://github.com/Alex-Zeo/PeonNotify.git ~/PeonNotify
cd ~/PeonNotify && ./install.sh
# Add .mp3 files to ~/.claude/sounds/peon/, restart Claude Code
```

You'll hear *"Ready to work!"* on your next session. That's it — all five systems are active.

## How It Works

Claude Code has **hooks** — shell commands that fire on every lifecycle event. PeonNotify registers scripts for each one:

```
Claude Code event fires
  → peon-dispatch.sh    plays a Peon sound
  → peon-codeguard.sh   lints + AI reviews the code
  → peon-docguard.sh    logs changes for your changelog
  → peon-watchdog.sh    checks memory usage
  → peon-obsidian.sh    captures knowledge to Obsidian
```

Everything is driven by one config file. Change sounds, volume, thresholds, or disable any feature — zero code changes.

```
~/.claude/
├── bin/
│   └── peon-claude                # Wrapper: auto-restart on memory kill + /exit fix
├── hooks/
│   ├── peon-dispatch.sh           # Audio notifications — all hook events route here
│   ├── peon-codeguard.sh          # Code quality pipeline (lint + AI debug review)
│   ├── peon-docguard.sh           # Auto-documentation (CHANGELOG, CLAUDE.md, MEMORY.md)
│   ├── peon-obsidian.sh           # Knowledge graph builder (Obsidian vault integration)
│   ├── peon-obsidian-cron.sh      # Daily vault maintenance (launchd/cron)
│   ├── peon-watchdog.sh           # Memory leak detector (RSS monitoring)
│   ├── peon-health.sh             # Diagnostics & validation
│   ├── lib/
│   │   ├── config.sh              # Config loader, profiles, platform detection
│   │   ├── docguard.sh            # DocGuard accumulate/flush logic
│   │   ├── linter.sh              # Language detection & linter dispatch
│   │   ├── logger.sh              # Structured JSON logging (wide events)
│   │   ├── obsidian.sh            # Vault operations, note creation, VQI scoring
│   │   ├── player.sh              # Cross-platform audio playback engine (queued)
│   │   └── validators.sh          # JSON/YAML/TOML syntax validation
│   └── templates/
│       └── obsidian/              # Note templates (bug, decision, pattern, pitfall, etc.)
├── config/
│   └── peon.json                  # All tunables (volume, mute, sounds, cooldowns, features)
├── sounds/
│   └── peon/                      # MP3 sound files (user-supplied)
├── logs/
│   └── peon.log                   # Structured JSON event log (auto-rotated)
├── state/
│   └── cooldown_*                 # Per-event cooldown timestamps
└── settings.local.json            # Claude Code hook wiring
```

## Features

### Audio Notifications

Know what Claude is doing without looking at your screen. A distinct Peon sound plays for every lifecycle event — session start, prompt sent, permission needed, task complete, error. Per-event cooldowns prevent spam. Sounds queue and play sequentially (no overlap).

<details>
<summary><strong>Full event coverage (click to expand)</strong></summary>

**Session lifecycle**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `SessionStart` | - | *"Ready to work"* | New session begins |
| `SessionStart` | `resume` | *"Okie dokey"* | Resumed session |
| `SessionEnd` | - | *"Jobs done"* | Session closes |

**User interaction**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `UserPromptSubmit` | - | *"Work work" / "Zug zug" / ...* | You send a prompt |
| `Notification` | `permission_prompt` | *"Something need doing?"* | Claude needs approval |
| `PermissionRequest` | - | *"Something need doing?"* | Permission dialog shown |
| `Notification` | `idle_prompt` | *"Hmmm?"* | Idle >60s, waiting for input |

**Tool use**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `PreToolUse` | `Bash` | *(silent)* | Shell command about to run |
| `PreToolUse` | `Write\|Edit` | *"Work work"* | File write/edit starting |
| `PreToolUse` | `Task` | *"Work work"* | Subagent task starting |
| `PostToolUse` | `Write\|Edit` | *"Jobs done"* | File write/edit completed |
| `PostToolUse` | (on failure) | *"Never mind"* | Tool execution failed |
| `PostToolUseFailure` | - | *"Leave me alone"* | System error |

**Completion**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `Stop` | - | *"Work complete"* | Agent finished full response |
| `SubagentStop` | - | *"Jobs done"* | Subagent task completed |
| `PreCompact` | - | *"Me busy"* | Compaction triggered (manual or auto) |

**CodeGuard**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `PostToolUse` | `Write\|Edit` | *"Jobs done"* | Lint + debug review passed |
| `PostToolUse` | `Write\|Edit` | *"Never mind"* | Lint errors found |
| `PostToolUse` | `Write\|Edit` | *"Leave me alone"* | Debug review found issues |

</details>

### CodeGuard -- Automatic Code Quality

Every file Claude writes gets reviewed before you even see it. CodeGuard runs a two-step pipeline on every `PostToolUse` Write/Edit event -- first a language-aware linter, then an AI debug review. Bugs, security issues, and logic errors surface immediately, not three commits later.

**Step 1 -- Language-aware lint:** Detects the file language by extension and runs the appropriate linter:

| Language | Linter | Secondary (advisory) |
|----------|--------|---------------------|
| JavaScript/TypeScript | `eslint` | -- |
| Python | `ruff` (fallback: `flake8`) | `mypy` / `pyright` |
| Shell | `shellcheck` | -- |
| Go | `go vet` | -- |
| Rust | `cargo clippy` | -- |
| Ruby | `rubocop` | -- |
| SQL | `sqlfluff` | -- |

**Step 2 -- AI debug review:** If lint passes, calls `claude -p` with a language-specific review prompt. Only reports actual bugs, security issues, or logic errors -- not style suggestions. Uses an exact sentinel (`NO_ISSUES_FOUND`) for reliable pass detection.

**Data file validation:** JSON, JSONL, YAML, and TOML files go through a separate 4-layer validation pipeline (syntax, duplicate keys, structure, and schema checks for known files like `package.json` and `tsconfig.json`).

**Skip logic:** Non-code files (`.md`, `.json`, `.yaml`, `.txt`, images, fonts, lockfiles) skip lint but data files still get validated. Vendor directories (`node_modules`, `dist`, `.git`, etc.) are skipped entirely. Minified/bundle files are excluded automatically.

**Guard rails:** Per-file review cap (max 3 per session) prevents correction loops. Per-session API budget (max 20 debug reviews). Content-hash dedup skips files that haven't changed. Both steps have independent timeouts and can be individually enabled/disabled in config.

### DocGuard -- Automatic Documentation

Your changelogs should write themselves. DocGuard uses an accumulate-then-flush architecture: during a session, every file write silently appends to a manifest (under 1ms, no AI call). When Claude finishes (`Stop` event), DocGuard scores the manifest, and if the session was significant enough, makes a single `claude -p` call to generate changelog entries, update `CLAUDE.md`, and sync `memory/MEMORY.md`.

- Significance scoring: Write = +3, Edit = +1 per unique file. Default threshold: 3.
- Backs up every doc before writing. Skips docs the user edited during the session.
- `--dry-run` flag for preview. `--flush` for manual trigger.

### Memory Watchdog

Claude Code sessions can leak memory until they consume your entire system. The watchdog monitors RSS on every prompt and takes action before that happens.

| Threshold | Default | Action |
|---|---|---|
| Warning | 800 MB | Plays *"Me not that kind of orc!"*, logs warning |
| Kill | 1200 MB | Plays Peon death grunt, kills process, flags restart |

**Auto-restart:** Use `peon-claude` instead of `claude` for automatic session recovery after watchdog kills:

```bash
# Add to your shell profile:
alias claude='~/.claude/bin/peon-claude'
```

The wrapper runs `claude` in a loop. After a watchdog kill, it reads the restart flag, waits 2 seconds, and resumes the session with `claude --resume`. Max 5 restarts before giving up. Also sets `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS=10000` which fixes the `/exit` error.

### Obsidian Knowledge Graph

Every session generates knowledge — decisions, patterns, bugs fixed. Without capture, it all vanishes. The Obsidian integration builds your second brain automatically, and it gets smarter over time:

- **Week 1**: Searchable session history across all projects
- **Month 1**: Patterns emerge — Dataview queries surface insights you didn't know existed
- **Month 3**: The AI learns what's useful — validated knowledge feeds back into future extractions

**How it works:** File changes accumulate during the session. On `Stop`, a single `claude -p` call extracts structured JSON — decisions with alternatives considered, patterns with evidence, pitfalls with prevention steps, bugs with root cause analysis. Each becomes a linked Obsidian note with YAML frontmatter.

**What gets created:**

| Note Type | Goes To | Example |
|-----------|---------|---------|
| Daily log | `vault/daily/2026-03-28.md` | Session summary with links to atomic notes |
| Decisions | `vault/projects/<slug>/decisions/` | Architectural choices with alternatives considered |
| Patterns | `vault/patterns/` | Reusable techniques that apply beyond one session |
| Pitfalls | `vault/pitfalls/` | Mistakes made, subtle bugs, time sinks |
| Bugs | `vault/projects/<slug>/bugs/` | Root cause analysis with fix details |
| Project MOC | `vault/projects/<slug>/MOC.md` | Map of Content linking all project knowledge |

**Self-improving quality (Karpathy ratchet):** A daily cron job evaluates notes older than 2 days — scoring confidence and usefulness via AI. High-confidence notes get promoted; low-value notes get archived. A Vault Quality Index (VQI) tracks graph health over time. The loop closes: validated knowledge feeds back into future extractions, so the system learns what matters to you.

**Daily maintenance:** index rebuild, note evaluation, gap detection (missing daily notes, stale projects), trend aggregation, failed manifest retry, lifecycle management, and inbox generation. Skips AI calls on battery power.

### Profiles

Profiles let you switch between named config presets without editing the base config. The `developer` profile plays only essential sounds -- permission prompts, agent completion, and subagent completion -- keeping things quiet while you work. CodeGuard, DocGuard, and Obsidian are disabled.

```bash
# Switch via config (persistent)
# In ~/.claude/config/peon.json: "active_profile": "developer"

# Switch via env var (per-terminal)
export PEON_PROFILE=developer
```

**Built-in profiles:**

| Profile | Behavior |
|---|---|
| `default` | All 20 event sounds active, all subsystems enabled |
| `developer` | 3 sounds only: `something_need_doing` (questions), `work_complete` (done), `jobs_done` (subagent done). CodeGuard, DocGuard, and Obsidian disabled. |

Add custom profiles in the `profiles` object in `peon.json`. Profile `event_sounds` replaces the base entirely (missing keys = silent). All other keys deep-merge.

### Configuration

<details>
<summary><strong>Full config reference (click to expand)</strong></summary>

Edit `~/.claude/config/peon.json`:

```jsonc
{
  "enabled": true,          // Master kill switch
  "volume": 0.6,            // 0.0-1.0
  "mute": false,            // Quick mute without changing volume
  "cooldown_ms": 1500,      // Default gap between sounds
  "log_level": "info",      // debug | info | warn | error
  "sound_pack": "peon",     // Subdirectory under sounds/

  "event_sounds": {         // Map event keys -> array of MP3 filenames
    "stop": ["work_complete.mp3"],
    "tool_bash": [],        // Empty array = silent for that event
  },

  "event_cooldowns": {      // Override cooldown per event (ms)
    "tool_start": 5000,
    "prompt_submit": 0,     // Always play on prompt
  },

  "codeguard": {            // Code quality pipeline settings
    "enabled": true,
    "lint_enabled": true,
    "validate_data_files": true,
    "claude_debug_enabled": true,
    "claude_debug_model": "sonnet",
    "blocking_mode": false,     // Exit non-zero on errors (blocks Claude Code)
    "max_file_size_kb": 100,
    "max_reviews_per_file": 3,
    "max_reviews_per_session": 20,
    "dedup_enabled": true,
    "skip_extensions": [".md", ".json", ".yaml", "..."],
    "skip_directories": ["node_modules", "vendor", "dist", "..."],
    "lint_timeout_sec": 5,
    "debug_timeout_sec": 20
  },

  "docguard": {             // Auto-documentation settings
    "enabled": true,
    "update_changelog": true,
    "update_claude_md": true,
    "sync_memory_md": true,
    "min_score_threshold": 3,
    "flush_model": "sonnet",
    "flush_timeout_sec": 45
  },

  "watchdog": {             // Memory monitoring settings
    "enabled": true,
    "warn_mb": 800,
    "kill_mb": 1200,
    "warn_cooldown_sec": 300,
    "auto_restart": true
  },

  "obsidian": {             // Knowledge graph settings
    "enabled": true,
    "vault_path": "~/Documents/Obsidian",
    "flush_model": "sonnet",
    "create_atomic_notes": true,
    "daily_notes": true,
    "project_tracking": true,
    "goal_tracking": true,
    "max_atomic_notes_per_session": 5,
    "min_score_threshold": 5,
    "cron_enabled": true,
    "auto_archive": true,
    "archive_after_days": 90
  }
}
```

</details>

## Sound Files

Place `.mp3` files in `~/.claude/sounds/peon/`. All 17 files referenced in config:

| File | Peon Quote | Used For |
|---|---|---|
| `ready_to_work.mp3` | "Ready to work" | Session start |
| `okie_dokey.mp3` | "Okie dokey" | Prompt ack, resume, file writes |
| `zug_zug.mp3` | "Zug zug" | Prompt ack |
| `work_work.mp3` | "Work work" | Prompt ack, tool start |
| `ill_try.mp3` | "I'll try" | Prompt ack |
| `be_happy_to.mp3` | "Be happy to" | Prompt ack |
| `something_need_doing.mp3` | "Something need doing?" | Permission prompts |
| `hmmm.mp3` | "Hmmm?" | Permission prompts, idle notification |
| `yes_what.mp3` | "Yes? What?" | Permission prompts |
| `me_busy.mp3` | "Me busy" | Compaction |
| `leave_me_alone.mp3` | "Leave me alone" | System errors |
| `jobs_done.mp3` | "Jobs done!" | Step completion, subagent done, session end |
| `work_complete.mp3` | "Work complete" | Full response complete (Stop) |
| `more_gold_required.mp3` | "More gold is required" | Limits |
| `never_mind.mp3` | "Never mind" | Tool failures (errors) |
| `me_not_that_kind_of_orc.mp3` | "Me not that kind of orc!" | Watchdog memory warning |
| `peon_death.mp3` | *(death grunt)* | Watchdog memory kill |

Extract from Warcraft III game files with CascView, download from soundboard sites (101soundboards.com, myinstants.com), or use the placeholder TTS script printed by the installer.

## Troubleshooting

- **No sound plays** -- Run `~/.claude/hooks/peon-health.sh --play-test`, verify `enabled: true` and `mute: false` in config, check that `.mp3` files exist in `~/.claude/sounds/peon/`
- **Sounds play too often** -- Increase `cooldown_ms` or set per-event cooldowns in `event_cooldowns`; set noisy events to `[]` in `event_sounds`
- **Hooks not firing** -- Run `/hooks` in Claude Code to verify registration; check that `~/.claude/settings.local.json` references `peon-dispatch.sh`
- **Wrong platform detected** -- Set `"platform_override": "macos"` (or `"linux"`, `"wsl"`) in config
- **CodeGuard not running** -- Check `codeguard.enabled` is `true` in `peon.json`; verify `peon-codeguard.sh` is in `settings.local.json` PostToolUse hooks; run `peon-health.sh` to see CodeGuard status
- **Lint errors not showing** -- Ensure the linter is installed (e.g., `eslint`, `ruff`, `shellcheck`); check `codeguard.lint_enabled` is `true`
- **Debug review timing out** -- Increase `codeguard.debug_timeout_sec` (default: 20); check that `claude` CLI is available
- **Sounds overlap** -- The queue system in `player.sh` prevents this; if it happens, delete stale lock files in `~/.claude/state/` (`sound_queue.lk`, `sound_player.lk`)
- **Obsidian notes not appearing** -- Check `obsidian.enabled` is `true`; verify vault path exists; run `peon-obsidian.sh --dry-run` to preview
- **DocGuard not generating** -- Check `docguard.enabled` is `true`; session must meet the significance threshold (default: 3 points)

## Uninstall

```bash
rm -rf ~/.claude/hooks/peon-*.sh ~/.claude/hooks/lib/
rm -rf ~/.claude/config/peon.json
rm -rf ~/.claude/sounds/peon/
rm -rf ~/.claude/state/cooldown_*
rm -rf ~/.claude/logs/peon.log
rm -rf ~/.claude/bin/peon-claude
# macOS: remove the Obsidian cron job
launchctl unload ~/Library/LaunchAgents/com.peonnotify.obsidian-cron.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.peonnotify.obsidian-cron.plist
# Then remove the "hooks" key from ~/.claude/settings.local.json
```

---

*Zug zug!*
