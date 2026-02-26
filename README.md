# 🔨 Peon Notify — Claude Code Sound Notification System

> *"Ready to work!"* — A production-grade audio notification system for Claude Code CLI that keeps you informed of session status, progress, errors, and completions without watching the terminal.

## Architecture

```
~/.claude/
├── hooks/
│   ├── peon-dispatch.sh        # Single entry point — all hooks route here
│   ├── peon-health.sh          # Diagnostics & validation
│   └── lib/
│       ├── config.sh           # Config loader, platform detection, cooldowns
│       ├── logger.sh           # Structured JSON logging (wide events)
│       └── player.sh           # Cross-platform audio playback engine
├── config/
│   └── peon.json               # All tunables (volume, mute, sounds, cooldowns)
├── sounds/
│   └── peon/                   # MP3 sound files (user-supplied)
├── logs/
│   └── peon.log                # Structured JSON event log (auto-rotated)
├── state/
│   └── cooldown_*              # Per-event cooldown timestamps
└── settings.local.json         # Claude Code hook wiring
```

**Design principles applied:**
- **Modular** — each `.sh` in `lib/` owns one responsibility
- **Config-over-Code** — all behavior controlled via `peon.json`, zero code changes needed
- **Structured Logging** — JSON-per-line with session_id, event, timestamps (wide events pattern)
- **Fail Fast** — invalid state exits immediately; missing sounds skip gracefully
- **Idempotent** — installer and dispatcher are safe to run repeatedly
- **Cross-Platform** — auto-detects macOS (`afplay`), Linux (`paplay`/`aplay`/`mpv`), WSL (`powershell.exe`)

## Installation

```bash
git clone <this-repo> ~/peon-notify
cd ~/peon-notify
chmod +x install.sh
./install.sh
```

Flags:
- `--skip-sounds` — Install everything except sound downloads
- `--dry-run` — Preview what would change without touching disk

## Hook Event Coverage

Every Claude Code lifecycle event is wired to the dispatcher. The dispatcher reads the JSON payload on stdin, resolves the event to a sound category, checks cooldowns, and plays asynchronously.

| Hook Event | Matcher | Sound Category | When It Fires |
|---|---|---|---|
| `SessionStart` | `startup` | `session_start` | New session begins — *"Ready to work"* |
| `SessionStart` | `resume` | `session_resume` | Resumed session — *"Okie dokey"* |
| `SessionEnd` | — | `session_end` | Session closes — *"Jobs done"* |
| `UserPromptSubmit` | — | `prompt_submit` | You send a prompt — *"Work work" / "Zug zug" / ...* |
| `PreToolUse` | `Bash` | `tool_bash` | Shell command about to run |
| `PreToolUse` | `Write\|Edit` | `tool_write` | File write/edit starting — *"Okie dokey"* |
| `PreToolUse` | `Task` | `tool_start` | Subagent task starting — *"Work work"* |
| `PostToolUse` | `Write\|Edit` | `tool_done` | File write/edit completed |
| `PostToolUse` | (on failure) | `error` | Tool execution failed — *"Never mind"* |
| `Notification` | `permission_prompt` | `permission_prompt` | Claude needs approval — *"Something need doing?"* |
| `Notification` | `idle_prompt` | `idle_prompt` | Idle >60s, waiting for input — *"Me busy"* |
| `PermissionRequest` | — | `permission_prompt` | Permission dialog shown — *"Hmmm?"* |
| `Stop` | — | `stop` | Agent finished responding — *"Jobs done!"* |
| `SubagentStop` | — | `subagent_stop` | Subagent task completed — *"Zug zug"* |
| `PreCompact` | `manual` | `compact_manual` | Manual `/compact` — *"Work complete"* |
| `PreCompact` | `auto` | `compact_auto` | Auto-compaction (silent by default) |

## Sound Files

Place `.mp3` files in `~/.claude/sounds/peon/`. All 15 files referenced in config:

| File | Peon Quote | Used For |
|---|---|---|
| `ready_to_work.mp3` | "Ready to work" | Session start |
| `okie_dokey.mp3` | "Okie dokey" | Prompt ack, resume, file writes |
| `zug_zug.mp3` | "Zug zug" | Prompt ack, subagent completion |
| `work_work.mp3` | "Work work" | Prompt ack, tool start |
| `ill_try.mp3` | "I'll try" | Prompt ack |
| `be_happy_to.mp3` | "Be happy to" | Prompt ack |
| `something_need_doing.mp3` | "Something need doing?" | Permission prompts |
| `hmmm.mp3` | "Hmmm?" | Permission prompts |
| `yes_what.mp3` | "Yes? What?" | Permission prompts |
| `me_busy.mp3` | "Me busy" | Idle notification |
| `leave_me_alone.mp3` | "Leave me alone" | Idle notification |
| `jobs_done.mp3` | "Jobs done!" | Completion, session end |
| `work_complete.mp3` | "Work complete" | Completion, compaction |
| `more_gold_required.mp3` | "More gold is required" | Errors, limits |
| `never_mind.mp3` | "Never mind" | Tool failures |

### Sourcing sounds

**Option A — WC3 game rip** (best quality): Use CascView on your Warcraft III install → `Sound/Orc/Peon/` → export WAVs → convert:
```bash
for f in *.wav; do ffmpeg -i "$f" -q:a 5 "${f%.wav}.mp3"; done
```

**Option B — Soundboard sites**: 101soundboards.com/boards/warcraft-iii-orc-peon, myinstants.com

**Option C — TTS placeholders** (for testing): The installer prints a script that generates robot-voice stand-ins via `say` (macOS) or `espeak` (Linux).

## Configuration

Edit `~/.claude/config/peon.json`:

```jsonc
{
  "enabled": true,          // Master kill switch
  "volume": 0.6,            // 0.0–1.0
  "mute": false,            // Quick mute without changing volume
  "cooldown_ms": 1500,      // Default gap between sounds
  "log_level": "info",      // debug | info | warn | error
  "sound_pack": "peon",     // Subdirectory under sounds/

  "event_sounds": {         // Map event keys → array of MP3 filenames
    "stop": ["jobs_done.mp3", "work_complete.mp3"],
    // Empty array = silent for that event
    "tool_bash": [],
    // ...
  },

  "event_cooldowns": {      // Override cooldown per event (ms)
    "tool_start": 5000,     // Don't spam during rapid tool calls
    "prompt_submit": 0,     // Always play on prompt
    // ...
  }
}
```

### Quick recipes

**Mute everything:**
```bash
jq '.mute = true' ~/.claude/config/peon.json > /tmp/p.json && mv /tmp/p.json ~/.claude/config/peon.json
```

**Lower volume:**
```bash
jq '.volume = 0.3' ~/.claude/config/peon.json > /tmp/p.json && mv /tmp/p.json ~/.claude/config/peon.json
```

**Silence a noisy event:**
```bash
jq '.event_sounds.tool_start = []' ~/.claude/config/peon.json > /tmp/p.json && mv /tmp/p.json ~/.claude/config/peon.json
```

**Add a custom sound pack:**
```bash
mkdir -p ~/.claude/sounds/halo
# Add your sounds...
jq '.sound_pack = "halo"' ~/.claude/config/peon.json > /tmp/p.json && mv /tmp/p.json ~/.claude/config/peon.json
```

## Observability

### Structured logs

Every sound play emits a JSON line to `~/.claude/logs/peon.log`:

```json
{"ts":"2026-02-26T15:30:00.000Z","level":"info","event":"dispatch.play","session_id":"abc123","pid":42,"event_key":"stop","hook_event":"Stop","tool_name":"","sound":"jobs_done.mp3"}
```

Fields follow the **wide event** pattern — one rich event per action with high-cardinality identifiers (session_id, pid) for precise filtering.

**Query recent events:**
```bash
# Last 20 plays
tail -20 ~/.claude/logs/peon.log | jq .

# Errors only
grep '"level":"error"' ~/.claude/logs/peon.log | jq .

# Events for a specific session
grep 'abc123' ~/.claude/logs/peon.log | jq .

# Count by event type
jq -r '.event_key' ~/.claude/logs/peon.log | sort | uniq -c | sort -rn
```

Logs auto-rotate at 5000 lines (configurable via `log_max_lines`).

### Health check

```bash
~/.claude/hooks/peon-health.sh            # Full diagnostic
~/.claude/hooks/peon-health.sh --play-test # Also test audio playback
~/.claude/hooks/peon-health.sh --fix       # Auto-fix permissions
```

## Troubleshooting

**No sound plays:**
1. Run `~/.claude/hooks/peon-health.sh --play-test`
2. Check `~/.claude/config/peon.json` → `enabled: true`, `mute: false`
3. Verify sound files exist in `~/.claude/sounds/peon/`
4. Check logs: `tail ~/.claude/logs/peon.log | jq .`

**Sounds play too often:**
- Increase `cooldown_ms` in config (default 1500ms)
- Set per-event cooldowns in `event_cooldowns` (e.g., `"tool_start": 10000`)
- Set noisy events to `[]` in `event_sounds`

**Hooks not firing:**
- Run `/hooks` in Claude Code to verify registration
- Check `~/.claude/settings.local.json` references `peon-dispatch.sh`
- Run `claude --debug` to see hook execution traces

**Wrong platform detected:**
- Set `"platform_override": "macos"` (or `"linux"`, `"wsl"`) in config

## Uninstall

```bash
rm -rf ~/.claude/hooks/peon-*.sh ~/.claude/hooks/lib/
rm -rf ~/.claude/config/peon.json
rm -rf ~/.claude/sounds/peon/
rm -rf ~/.claude/state/cooldown_*
rm -rf ~/.claude/logs/peon.log
# Then remove the "hooks" key from ~/.claude/settings.local.json
```

---

*Zug zug!* 🔨
