#!/usr/bin/env bash
# ============================================================
# monAp_pg : construit les 3 paquets de déploiement dans dist/
#
#   packaging/build_packages.sh [VERSION]      (VERSION par défaut : git describe)
#
#   dist/monAp_pg_instance_cible.tgz        VM-Cible : collecteur, échantillonneur, parseur de journaux
#   dist/monAp_pg_instance_monitoring.tgz   VM-Monitoring : repository PostgreSQL, SQL, timers, rétention
#   dist/monAp_pg_grafana.tgz               Grafana : plugins, source de données, dashboards
#   dist/SHA256SUMS                         empreintes des 3 archives
#
# Les fichiers viennent du dépôt (une seule source) ; packaging/templates/ ne contient que ce qui est
# propre aux paquets (LISEZMOI, install.sh, verify.sh, manifeste, cron). Archives reproductibles :
# mêmes sources = mêmes octets (date du dernier commit, tri des fichiers, propriétaire root).
# Nécessite : bash, tar, gzip, sha256sum, python3 ; git (facultatif, pour la version).
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT/packaging/templates"
OUT="${OUT_DIR:-$ROOT/dist}"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo inconnue)"
fi
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo inconnu)"
EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)"

die() { echo "ERREUR : $*" >&2; exit 1; }

# Liste des scripts SQL du repository : lue dans install-monitoring.sh (ordre d'application).
sql_files() {
    awk '/^SQL_FILES=\(/{f=1} f{print} f&&/\)/{exit}' "$ROOT/scripts/install-monitoring.sh" \
        | sed -e 's/^SQL_FILES=(//' -e 's/)//' | tr -s ' \t' '\n' | grep -v '^$'
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# add SRC DST_RELATIF [MODE] : copie un fichier du dépôt dans le paquet en cours.
add() {
    [ -f "$ROOT/$1" ] || die "fichier absent du dépôt : $1"
    install -D -m "${3:-0644}" "$ROOT/$1" "$PKG_DIR/${2:-$1}"
}
# tpl FICHIER [MODE] : copie un fichier de packaging/templates/<paquet>/ (placeholders remplacés).
tpl() {
    [ -f "$TPL/$PKG/$1" ] || die "modèle absent : packaging/templates/$PKG/$1"
    mkdir -p "$(dirname "$PKG_DIR/$1")"
    sed -e "s|{{VERSION}}|$VERSION|g" -e "s|{{NB_DASHBOARDS}}|${NB_DASHBOARDS:-0}|g" "$TPL/$PKG/$1" > "$PKG_DIR/$1"
    chmod "${2:-0644}" "$PKG_DIR/$1"
}

begin() { # begin NOM
    PKG="$1"; PKG_NAME="monAp_pg_$2"; PKG_DIR="$WORK/$PKG_NAME"; mkdir -p "$PKG_DIR"
}

finish() {
    printf 'monAp_pg %s\npaquet : %s\ncommit : %s\n' "$VERSION" "$PKG_NAME" "$COMMIT" > "$PKG_DIR/VERSION"
    ( cd "$PKG_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum | sed 's| \./| |' > SHA256SUMS )
    mkdir -p "$OUT"
    # Archive reproductible : ordre trié, date du commit, propriétaire root.
    ( cd "$WORK" && find "$PKG_NAME" -exec touch -h -d "@$EPOCH" {} + \
        && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$EPOCH" -cf - "$PKG_NAME" | gzip -n -9 > "$OUT/$PKG_NAME.tgz" )
    echo "  $OUT/$PKG_NAME.tgz ($(find "$PKG_DIR" -type f | wc -l) fichiers, $(du -k "$OUT/$PKG_NAME.tgz" | cut -f1) Ko)"
}

echo "monAp_pg : construction des paquets (version $VERSION, commit $COMMIT)"
rm -f "$OUT"/monAp_pg_*.tgz "$OUT"/SHA256SUMS

# ---- 1. Instance cible ---------------------------------------------------------------------
begin cible instance_cible
tpl LISEZMOI.md; tpl install.sh 0755; tpl verify.sh 0755
add python/requirements.txt manifeste.txt
for f in scripts/lib.sh scripts/install-target.sh scripts/verify.sh; do add "$f" "$f" 0755; done
add scripts/asemon.env.example
for f in collector sampler log_parser plan_format backfill_plans instance; do add "python/$f.py"; done
add python/config.py.example
add sql/03-target-user.sql
for u in collector sampler logparser; do add "systemd/asemon-$u.service"; done
finish

# ---- 2. Instance monitoring ---------------------------------------------------------------
begin monitoring instance_monitoring
tpl LISEZMOI.md; tpl install.sh 0755; tpl verify.sh 0755; tpl manifeste.txt; tpl cron/asemon-monitoring.cron
for f in scripts/lib.sh scripts/install-monitoring.sh scripts/verify.sh; do add "$f" "$f" 0755; done
add scripts/asemon.env.example
add python/retention.py
while read -r s; do add "sql/$s.sql"; done < <(sql_files)
for u in rollup.service rollup.timer samples-maintenance.service samples-maintenance.timer retention.service retention.timer; do
    add "systemd/asemon-$u"
done
finish

# ---- 3. Grafana ------------------------------------------------------------------------------
begin grafana grafana
NB_DASHBOARDS="$(ls "$ROOT"/grafana/asemon-*.json | wc -l)"
tpl LISEZMOI.md; tpl install.sh 0755; tpl verify.sh 0755
for f in scripts/lib.sh scripts/install-grafana.sh scripts/grafana-provision.sh scripts/verify.sh; do add "$f" "$f" 0755; done
add scripts/asemon.env.example
add grafana/plugins.txt
for f in "$ROOT"/grafana/asemon-*.json; do add "grafana/$(basename "$f")"; done
finish

( cd "$OUT" && sha256sum monAp_pg_*.tgz > SHA256SUMS )
echo "Terminé. Empreintes : $OUT/SHA256SUMS"
