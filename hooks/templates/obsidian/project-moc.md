---
type: project
project: {{project}}
date: {{date}}
tags: [project, {{project}}]
---

# {{project}}

## Overview
Auto-generated project Map of Content.

## Sessions
<!-- peon-obsidian: session list appended below -->

## Decisions
```dataview
TABLE date, status
FROM "projects/{{project}}/decisions" OR (#decision AND #{{project}})
SORT date DESC
```

## Patterns
```dataview
LIST
FROM #pattern AND #{{project}}
SORT date DESC
```

## Bugs Fixed
```dataview
LIST
FROM #bug AND #{{project}}
SORT date DESC
```

## Goal Alignment
<!-- peon-obsidian-cron: goal tracking appended below -->
