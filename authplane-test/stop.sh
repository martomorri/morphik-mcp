#!/usr/bin/env bash
# Stop both MCP servers (:8976 secured, :8977 original).
# Leaves the authorization server and any Morphik backend running.

kill_port() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      powershell -NoProfile -Command \
        "\$p = Get-NetTCPConnection -LocalPort $1 -State Listen -EA SilentlyContinue | Select -Expand OwningProcess -Unique; if(\$p){\$p|%{Stop-Process -Id \$_ -Force; \"stopped PID \$_ on $1\"}} else {\"nothing on $1\"}" \
        2>/dev/null
      ;;
    *)
      local pids; pids=$(lsof -ti ":$1" 2>/dev/null || true)
      if [ -n "$pids" ]; then echo "$pids" | xargs kill -9 && echo "stopped $pids on $1"; else echo "nothing on $1"; fi
      ;;
  esac
}

kill_port 8976
kill_port 8977
