#!/usr/bin/env bash
# lib/validators.sh - Multi-layer validators for data files
# Sources: logger.sh must be sourced first
#
# JSON validation layers:
#   L1 — Syntax:    parse errors, encoding issues, BOM detection
#   L2 — Integrity: duplicate key detection (silent data loss prevention)
#   L3 — Structure: deep nesting, mixed-type arrays, oversized strings
#   L4 — Schema:    known-file validation (package.json, tsconfig.json)
#
# Also validates: YAML, TOML, JSONL/NDJSON

# ── JSON Validation (multi-layer) ─────────────────────────────────
# Returns 0 if valid, 1 if invalid. Errors/warnings on stdout.
# Warnings alone (structural, schema) do NOT fail the check.
peon_validate_json() {
  local file="$1"
  local output=""
  local exit_code=0

  if command -v python3 &>/dev/null; then
    output=$(python3 - "$file" <<'PYEOF'
import json, sys, os

# ── L2: Duplicate key detector ─────────────────────────────────
def check_duplicates(pairs):
    """object_pairs_hook — raises ValueError on duplicate keys."""
    seen = {}
    dupes = []
    for key, value in pairs:
        if key in seen:
            dupes.append(key)
        seen[key] = value
    if dupes:
        unique = list(dict.fromkeys(dupes))  # preserve order, deduplicate
        raise ValueError("duplicate keys: " + ", ".join(repr(k) for k in unique))
    return seen

# ── L3: Structural analysis ───────────────────────────────────
def structural_warnings(data, path="$", depth=0):
    """Walk the parsed tree looking for structural red flags."""
    warnings = []
    if depth > 20:
        warnings.append(f"deeply nested structure (depth {depth}) at '{path}'")
        return warnings  # don't recurse further

    if isinstance(data, dict):
        if len(data) > 500:
            warnings.append(f"very wide object ({len(data)} keys) at '{path}'")
        for key, value in data.items():
            child = f"{path}.{key}"
            warnings.extend(structural_warnings(value, child, depth + 1))

    elif isinstance(data, list):
        if len(data) > 1:
            types = set()
            for item in data:
                if item is None:
                    continue
                types.add(type(item).__name__)
            # Mixed types (excluding null) in a data array is often a bug
            if len(types) > 1:
                type_list = ", ".join(sorted(types))
                warnings.append(f"mixed types in array at '{path}': [{type_list}]")
        for i, item in enumerate(data[:50]):  # sample first 50 elements
            warnings.extend(structural_warnings(item, f"{path}[{i}]", depth + 1))

    elif isinstance(data, str) and len(data) > 100_000:
        warnings.append(f"very large string ({len(data):,} chars) at '{path}'")

    elif isinstance(data, float):
        if data != data:  # NaN check
            warnings.append(f"NaN value at '{path}'")
        elif abs(data) == float("inf"):
            warnings.append(f"Infinity value at '{path}'")

    return warnings

# ── L4: Known-file schema checks ──────────────────────────────
def schema_warnings(data, basename):
    """Check for common issues in well-known JSON config files."""
    warnings = []

    if basename == "package.json" and isinstance(data, dict):
        if "name" not in data:
            warnings.append("package.json: missing 'name' field")
        if "version" not in data and not data.get("private", False):
            warnings.append("package.json: missing 'version' (required for published packages)")
        for dep_key in ("dependencies", "devDependencies", "peerDependencies"):
            deps = data.get(dep_key, {})
            if isinstance(deps, dict):
                for pkg, ver in deps.items():
                    if ver == "*":
                        warnings.append(f"package.json: {dep_key}.{pkg} = '*' (wildcard — non-deterministic)")
                    elif ver == "latest":
                        warnings.append(f"package.json: {dep_key}.{pkg} = 'latest' (non-deterministic)")
                    elif isinstance(ver, str) and ver.startswith("git"):
                        warnings.append(f"package.json: {dep_key}.{pkg} uses git URL (not reproducible across environments)")

    if basename == "tsconfig.json" and isinstance(data, dict):
        co = data.get("compilerOptions")
        if co is not None and not isinstance(co, dict):
            warnings.append("tsconfig.json: 'compilerOptions' must be an object")
        extends = data.get("extends")
        if isinstance(extends, str) and extends.startswith("/"):
            warnings.append("tsconfig.json: 'extends' uses absolute path (not portable)")

    return warnings

# ── Main ──────────────────────────────────────────────────────
filepath = sys.argv[1]
basename = os.path.basename(filepath).lower()

# L1: Read with encoding check
try:
    with open(filepath, "rb") as f:
        raw_bytes = f.read()
except FileNotFoundError:
    print(f"{filepath}: file not found")
    sys.exit(1)

# BOM detection
has_bom = raw_bytes[:3] == b"\xef\xbb\xbf"
try:
    raw = raw_bytes.decode("utf-8")
except UnicodeDecodeError as e:
    print(f"{filepath}: encoding error — not valid UTF-8: {e}")
    sys.exit(1)

if has_bom:
    raw = raw.lstrip("\ufeff")

# Empty file check
stripped = raw.strip()
if not stripped:
    print(f"{filepath}:1:1: empty file (not valid JSON)")
    sys.exit(1)

# L1 + L2: Parse with duplicate detection
try:
    data = json.loads(raw, object_pairs_hook=check_duplicates)
except json.JSONDecodeError as e:
    print(f"{filepath}:{e.lineno}:{e.colno}: {e.msg}")
    sys.exit(1)
except ValueError as e:
    # Raised by check_duplicates
    print(f"{filepath}: {e}")
    sys.exit(1)

# L3: Structural warnings
warnings = []
if has_bom:
    warnings.append("file starts with UTF-8 BOM (may break strict parsers)")
warnings.extend(structural_warnings(data))

# L4: Schema warnings for known files
warnings.extend(schema_warnings(data, basename))

# Output warnings (informational — do not fail the check)
for w in warnings:
    print(f"{filepath}: warning: {w}")

sys.exit(0)
PYEOF
    ) || exit_code=$?
  elif command -v jq &>/dev/null; then
    # Fallback: jq catches syntax errors but no duplicate/structural analysis
    output=$(jq empty "$file" 2>&1) || exit_code=$?
  else
    peon_log debug "validator.no_json_tool" "file=$file"
    return 0
  fi

  if [[ $exit_code -ne 0 ]]; then
    [[ -n "$output" ]] && echo "$output"
    return 1
  fi
  # Print warnings even on success (they're informational)
  [[ -n "$output" ]] && echo "$output"
  return 0
}

# ── JSONL / NDJSON Validation ─────────────────────────────────────
# Validates each line as independent JSON. Reports first N errors.
# Returns 0 if valid, 1 if any line is invalid.
peon_validate_jsonl() {
  local file="$1"
  local output=""
  local exit_code=0

  if command -v python3 &>/dev/null; then
    output=$(python3 - "$file" <<'PYEOF'
import json, sys

filepath = sys.argv[1]
max_lines = 10000   # don't read forever
max_errors = 5      # stop after this many
errors = []
line_count = 0
empty_lines = 0

try:
    with open(filepath, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            if i > max_lines:
                break
            line_count = i
            stripped = line.rstrip("\n\r")
            if not stripped:
                empty_lines += 1
                continue
            try:
                json.loads(stripped)
            except json.JSONDecodeError as e:
                errors.append(f"{filepath}:{i}:{e.colno}: {e.msg}")
                if len(errors) >= max_errors:
                    errors.append(f"  ... stopped after {max_errors} errors (checked {i} of {line_count}+ lines)")
                    break
except UnicodeDecodeError as e:
    print(f"{filepath}: encoding error — not valid UTF-8: {e}")
    sys.exit(1)
except FileNotFoundError:
    print(f"{filepath}: file not found")
    sys.exit(1)

if errors:
    for err in errors:
        print(err)
    sys.exit(1)

# Warn if file looks suspicious
if line_count == 0:
    print(f"{filepath}: warning: empty file")
elif line_count == 1 and empty_lines == 0:
    # Single-line file — might be regular JSON saved as .jsonl
    print(f"{filepath}: warning: only 1 line — may be regular JSON, not JSONL")

sys.exit(0)
PYEOF
    ) || exit_code=$?
  elif command -v jq &>/dev/null; then
    # Fallback: use jq in slurp-raw mode to parse each line
    output=$(jq -R -e 'fromjson' "$file" > /dev/null 2>&1) || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      output="$file: invalid JSONL (jq parse error)"
    fi
  else
    peon_log debug "validator.no_jsonl_tool" "file=$file"
    return 0
  fi

  if [[ $exit_code -ne 0 ]]; then
    [[ -n "$output" ]] && echo "$output"
    return 1
  fi
  [[ -n "$output" ]] && echo "$output"
  return 0
}

# ── YAML Validation ────────────────────────────────────────────────
# Requires python3 with PyYAML. Skips gracefully if unavailable.
peon_validate_yaml() {
  local file="$1"
  local output=""
  local exit_code=0

  if command -v python3 &>/dev/null; then
    output=$(python3 - "$file" <<'PYEOF'
import sys

try:
    import yaml
except ImportError:
    sys.exit(0)  # pyyaml not installed, skip gracefully

filepath = sys.argv[1]
try:
    with open(filepath) as f:
        docs = list(yaml.safe_load_all(f))  # handle multi-doc YAML
except yaml.YAMLError as e:
    print(f"{filepath}: {e}")
    sys.exit(1)
except Exception as e:
    print(f"{filepath}: {e}")
    sys.exit(1)

# Structural warnings for YAML
warnings = []
for doc in docs:
    if doc is None:
        continue
    if isinstance(doc, dict) and len(doc) > 500:
        warnings.append(f"very wide mapping ({len(doc)} keys)")

for w in warnings:
    print(f"{filepath}: warning: {w}")

sys.exit(0)
PYEOF
    ) || exit_code=$?
  else
    peon_log debug "validator.no_yaml_tool" "file=$file"
    return 0
  fi

  if [[ $exit_code -ne 0 ]]; then
    [[ -n "$output" ]] && echo "$output"
    return 1
  fi
  [[ -n "$output" ]] && echo "$output"
  return 0
}

# ── TOML Validation ────────────────────────────────────────────────
# Requires python3 >= 3.11 (tomllib) or the tomli package.
peon_validate_toml() {
  local file="$1"
  local output=""
  local exit_code=0

  if command -v python3 &>/dev/null; then
    output=$(python3 -c "
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        sys.exit(0)  # no toml parser, skip gracefully
try:
    with open(sys.argv[1], 'rb') as f:
        tomllib.load(f)
except Exception as e:
    print(f'{sys.argv[1]}: {e}')
    sys.exit(1)
" "$file" 2>&1) || exit_code=$?
  else
    peon_log debug "validator.no_toml_tool" "file=$file"
    return 0
  fi

  if [[ $exit_code -ne 0 ]]; then
    [[ -n "$output" ]] && echo "$output"
    return 1
  fi
  return 0
}

# ── Router ─────────────────────────────────────────────────────────
# peon_validate_data <file_path>
# Dispatches to the correct validator based on file extension.
# Returns 0=valid/skipped, 1=invalid. Details on stdout.
peon_validate_data() {
  local file="$1"
  local ext="${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  case "$ext" in
    json)         peon_validate_json "$file" ;;
    jsonl|ndjson) peon_validate_jsonl "$file" ;;
    yaml|yml)     peon_validate_yaml "$file" ;;
    toml)         peon_validate_toml "$file" ;;
    *)            return 0 ;;
  esac
}
