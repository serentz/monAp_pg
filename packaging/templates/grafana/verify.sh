#!/usr/bin/env bash
# monAp_pg : contrôles après installation (appelle scripts/verify.sh grafana).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/verify.sh" grafana "$@"
