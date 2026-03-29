---
name: Profile Merge Strategy
description: How config profiles are merged — event_sounds replaced, everything else deep-merged
type: reference
---

Profile merging happens in config.sh `_peon_apply_profile()`.

- active_profile key or PEON_PROFILE env var selects profile
- "default" = no merge, base config as-is
- Other profiles: jq generates merged JSON file at $PEON_STATE_DIR/peon_merged_<profile>.json
- PEON_CONFIG_FILE redirected to merged file → all downstream scripts read merged values transparently

Merge rules:
- event_sounds: REPLACE entirely (missing keys = silent)
- Everything else (codeguard, docguard, watchdog, obsidian, scalars): DEEP MERGE via jq * operator

**Why:** Developers want quiet mode (3 sounds only). Deep merge for settings avoids specifying every key.
