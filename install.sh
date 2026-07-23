#!/usr/bin/env bash
# agman installer. Works two ways:
#   1. From a clone:  ./install.sh
#   2. Piped:         curl -fsSL https://raw.githubusercontent.com/memandip/agman/main/install.sh | bash
#
# Installs a single bash script to ~/.local/bin (override: AGMAN_BIN_DIR).
set -euo pipefail

BIN_DIR="${AGMAN_BIN_DIR:-$HOME/.local/bin}"
RAW_URL="${AGMAN_RAW_URL:-https://raw.githubusercontent.com/memandip/agman/main}"

script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fi

mkdir -p "$BIN_DIR"

if [ -n "$script_dir" ] && [ -f "$script_dir/bin/agman" ]; then
  cp "$script_dir/bin/agman" "$BIN_DIR/agman"
  src="local clone"
else
  command -v curl >/dev/null 2>&1 || { printf 'installer: curl is required for remote install\n' >&2; exit 1; }
  curl -fsSL "$RAW_URL/bin/agman" -o "$BIN_DIR/agman"
  src="$RAW_URL"
fi
chmod +x "$BIN_DIR/agman"

printf 'Installed agman to %s (from %s)\n' "$BIN_DIR/agman" "$src"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf '\nNOTE: %s is not on your PATH. Add this to your shell rc first:\n' "$BIN_DIR"
    printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
    ;;
esac

printf '\nNext steps:\n'
printf '  1. Add shell integration to ~/.zshrc or ~/.bashrc:\n'
printf '       eval "$(agman init zsh)"    # or: init bash\n'
printf '  2. Create profiles:   agman create work && agman create personal\n'
printf '  3. Switch:            agman use work\n'
