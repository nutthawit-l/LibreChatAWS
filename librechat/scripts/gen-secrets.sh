#!/usr/bin/env bash
# Fill empty CREDS_* / JWT_* / MEILI_* in librechat/.env
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-$ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT/.env.example" "$ENV_FILE"
fi

python3 - "$ENV_FILE" <<'PY'
import pathlib, re, secrets, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()

def fill(key: str, nbytes: int) -> None:
    global text
    m = re.search(rf"^{re.escape(key)}=(.*)$", text, re.M)
    if not m or m.group(1).strip():
        return
    text = re.sub(rf"^{re.escape(key)}=.*$", f"{key}={secrets.token_hex(nbytes)}", text, count=1, flags=re.M)
    print(f"Generated {key}")

for key, n in (
    ("CREDS_KEY", 32),
    ("CREDS_IV", 16),
    ("JWT_SECRET", 32),
    ("JWT_REFRESH_SECRET", 32),
    ("MEILI_MASTER_KEY", 32),
):
    fill(key, n)

path.write_text(text)
print(f"Updated {path}")
PY
