# Peon Notify — Sound Notifications for Claude Code

> *"Ready to work!"* — Audio feedback for every Claude Code lifecycle event, so you never have to watch the terminal.

## What Are Claude Code Hooks?

Claude Code **hooks** are lifecycle callbacks that let you run shell commands at key moments during an AI coding session. Every hook receives a JSON payload on stdin describing the event — session starts, tool calls, completions, permission prompts, and more.

Hooks are configured in `~/.claude/settings.local.json` under a `"hooks"` key. Each event name maps to an array of matchers, each with a `command` string that runs as a subprocess. The JSON payload always includes `hook_event_name` and `session_id`; tool-related events add `tool_name`, and notifications include `notification_type`.

This makes hooks a clean extension point — no Claude Code source changes, no plugins, just shell scripts reacting to structured events.

## How PeonNotify Uses Hooks

PeonNotify registers a single dispatcher script (`peon-dispatch.sh`) as the command for every hook event. The dispatcher reads the JSON payload, maps the event to a sound category, checks per-event cooldowns, resolves a random `.mp3` from the configured list, and plays it asynchronously. All behavior is driven by one config file (`peon.json`) — changing sounds, volume, cooldowns, or disabling events requires zero code changes.

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

## Quick Start

```bash
git clone <this-repo> ~/PeonNotify
cd ~/PeonNotify && ./install.sh
# Add .mp3 files to ~/.claude/sounds/peon/, then restart Claude Code
```

## Event Coverage

Every Claude Code lifecycle event is wired to the dispatcher. The dispatcher reads the JSON payload on stdin, resolves the event to a sound category, checks cooldowns, and plays asynchronously.

**Session lifecycle**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `SessionStart` | — | *"Ready to work"* | New session begins |
| `SessionStart` | `resume` | *"Okie dokey"* | Resumed session |
| `SessionEnd` | — | *"Jobs done"* | Session closes |

**User interaction**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `UserPromptSubmit` | — | *"Work work" / "Zug zug" / ...* | You send a prompt |
| `Notification` | `permission_prompt` | *"Something need doing?"* | Claude needs approval |
| `PermissionRequest` | — | *"Something need doing?"* | Permission dialog shown |
| `Notification` | `idle_prompt` | *"Hmmm?"* | Idle >60s, waiting for input |

**Tool use**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `PreToolUse` | `Bash` | *(silent)* | Shell command about to run |
| `PreToolUse` | `Write\|Edit` | *"Work work"* | File write/edit starting |
| `PreToolUse` | `Task` | *"Work work"* | Subagent task starting |
| `PostToolUse` | `Write\|Edit` | *"Jobs done"* | File write/edit completed |
| `PostToolUse` | (on failure) | *"Never mind"* | Tool execution failed |
| `PostToolUseFailure` | — | *"Leave me alone"* | System error |

**Completion**

| Hook Event | Matcher | Sound | When It Fires |
|---|---|---|---|
| `Stop` | — | *"Work complete"* | Agent finished full response |
| `SubagentStop` | — | *"Jobs done"* | Subagent task completed |
| `PreCompact` | — | *"Me busy"* | Compaction triggered (manual or auto) |

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
    "stop": ["work_complete.mp3"],
    "tool_bash": [],        // Empty array = silent for that event
  },

  "event_cooldowns": {      // Override cooldown per event (ms)
    "tool_start": 5000,
    "prompt_submit": 0,     // Always play on prompt
  }
}
```

## Sound Files

Place `.mp3` files in `~/.claude/sounds/peon/`. All 15 files referenced in config:

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

Extract from Warcraft III game files with CascView, download from soundboard sites (101soundboards.com, myinstants.com), or use the placeholder TTS script printed by the installer.

## Troubleshooting

- **No sound plays** — Run `~/.claude/hooks/peon-health.sh --play-test`, verify `enabled: true` and `mute: false` in config, check that `.mp3` files exist in `~/.claude/sounds/peon/`
- **Sounds play too often** — Increase `cooldown_ms` or set per-event cooldowns in `event_cooldowns`; set noisy events to `[]` in `event_sounds`
- **Hooks not firing** — Run `/hooks` in Claude Code to verify registration; check that `~/.claude/settings.local.json` references `peon-dispatch.sh`
- **Wrong platform detected** — Set `"platform_override": "macos"` (or `"linux"`, `"wsl"`) in config

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

*Zug zug!*
