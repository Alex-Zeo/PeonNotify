---
name: Karpathy Ratchet Loop
description: Self-improving knowledge graph based on autoresearch pattern
type: project
---

Inspired by github.com/karpathy/autoresearch. The Obsidian integration uses a ratchet loop:

1. **Measure**: VQI (Vault Quality Index) — composite of link density, orphan rate, freshness, eval confidence
2. **Improve**: Session flush extracts decisions/patterns/pitfalls/bugs as atomic notes
3. **Evaluate**: Cron evaluates notes 2+ days old via claude -p (confidence 0.0-1.0)
4. **Keep/Discard**: confidence >= 0.7 → active. < 0.3 → stale. Auto-archive after 90 days.
5. **Repeat**: High-confidence notes fed back as "validated knowledge" in next extraction prompt

**Why:** Without evaluation, the vault is static — notes accumulate but never improve. With the ratchet, the system learns which extractions are useful and adjusts.

**How to apply:** VQI should trend upward over weeks. If it plateaus, the prompt needs tuning. Check meta/vqi_history.jsonl for the trend.
