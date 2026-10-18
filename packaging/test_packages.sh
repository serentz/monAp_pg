#!/usr/bin/env bash
# ============================================================
# monAp_pg : tests des paquets de déploiement.
#
#   packaging/test_packages.sh
#
# Construit les 3 paquets dans un dossier temporaire, puis contrôle :
#   - le contenu de chaque archive, les empreintes SHA256SUMS, la reproductibilité du build ;
#   - la syntaxe des scripts shell, des JSON, des scripts Python ;
#   - que chaque fichier cité par les scripts d'installation est bien dans le paquet ;
#   - le manifeste Python (venv réel + import de tous les scripts)         [besoin d'accès à PyPI] ;
#   - les scripts SQL du paquet monitoring appliqués deux fois sur un PostgreSQL de test
#     (cluster Debian temporaire, à lancer en root)                         [besoin de pg_createcluster] ;
#   - install-grafana.sh avec des commandes simulées (plugins, redémarrage).
# Les étapes qui manquent de prérequis sont signalées « SKIP », pas « FAIL ».
# Code de sortie : 0 si aucun échec.
# ============================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
PASS=0 FAIL=0 SKIP=0
PGPORT_TEST="${PGPORT_TEST:-5447}"
CLUSTER=asemonpkg
cleanup() {
    if pg_lsclusters 2>/dev/null | awk '{print $2}' | grep -qx "$CLUSTER"; then
        pg_dropcluster --stop "$(pg_lsclusters -h | awk -v c="$CLUSTER" '$2==c{print $1}')" "$CLUSTER" >/dev/null 2>&1 || true
    fi
    rm -rf "$T"
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -n 8 | sed 's/^/         | /'; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP - $1"; }
check() { # check "libellé" commande...
    local label="$1" out; shift
    if out="$("$@" 2>&1)"; then ok "$label"; else ko "$label" "$out"; fi
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 (attendu '$3', obtenu '$2')"; fi; }

PKGS=(instance_cible instance_monitoring grafana)

echo "== Construction =="
check "build_packages.sh" env OUT_DIR="$T/dist" "$ROOT/packaging/build_packages.sh" vTEST
check "build reproductible (2e build identique)" bash -c "OUT_DIR='$T/dist2' '$ROOT/packaging/build_packages.sh' vTEST >/dev/null && diff '$T/dist/SHA256SUMS' '$T/dist2/SHA256SUMS'"
check "dist/SHA256SUMS valide" bash -c "cd '$T/dist' && sha256sum -c SHA256SUMS --quiet"
mkdir -p "$T/x"
for p in "${PKGS[@]}"; do
    tar xzf "$T/dist/monAp_pg_$p.tgz" -C "$T/x" || ko "extraction de $p"
done

# Fichiers attendus, par paquet (hors SHA256SUMS et VERSION, vérifiés à part).
expected() {
    case "$1" in
    instance_cible) echo LISEZMOI.md install.sh verify.sh manifeste.txt scripts/lib.sh scripts/install-target.sh scripts/verify.sh \
        scripts/asemon.env.example python/collector.py python/sampler.py python/log_parser.py python/plan_format.py \
        python/backfill_plans.py python/instance.py python/config.py.example sql/03-target-user.sql \
        systemd/asemon-collector.service systemd/asemon-sampler.service systemd/asemon-logparser.service ;;
    instance_monitoring) echo LISEZMOI.md install.sh verify.sh manifeste.txt cron/asemon-monitoring.cron scripts/lib.sh \
        scripts/install-monitoring.sh scripts/verify.sh scripts/asemon.env.example python/retention.py \
        systemd/asemon-rollup.service systemd/asemon-rollup.timer systemd/asemon-samples-maintenance.service \
        systemd/asemon-samples-maintenance.timer systemd/asemon-retention.service systemd/asemon-retention.timer ;;
    grafana) echo LISEZMOI.md install.sh verify.sh scripts/lib.sh scripts/install-grafana.sh scripts/grafana-provision.sh \
        scripts/verify.sh scripts/asemon.env.example grafana/plugins.txt ;;
    esac
}

for p in "${PKGS[@]}"; do
    D="$T/x/monAp_pg_$p"
    echo "== Paquet $p =="
    missing=""
    for f in $(expected "$p") VERSION SHA256SUMS; do [ -f "$D/$f" ] || missing="$missing $f"; done
    [ -z "$missing" ] && ok "contenu attendu présent" || ko "fichiers manquants :$missing"
    check "SHA256SUMS valide" bash -c "cd '$D' && sha256sum -c SHA256SUMS --quiet"
    eq "VERSION indique la version" "$(sed -n 1p "$D/VERSION")" "monAp_pg vTEST"
    [ -z "$(find "$D" -name 'asemon.env' -o -name 'config.py')" ] && ok "aucun secret (asemon.env, config.py) dans le paquet" || ko "secret présent dans le paquet"
    grep -rl --exclude='*.json' '{{' "$D" >/dev/null 2>&1 && ko "marqueur {{...}} non remplacé : $(grep -rl --exclude='*.json' '{{' "$D")" || ok "marqueurs de modèle remplacés"
    for s in install.sh verify.sh; do [ -x "$D/$s" ] && ok "$s exécutable" || ko "$s non exécutable"; done
    for f in $(cd "$D" && find . -name '*.sh' | sed 's|^\./||'); do check "bash -n $f" bash -n "$D/$f"; done
    for f in $(cd "$D" && find . -name '*.json' | sed 's|^\./||'); do check "JSON valide : $f" python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$D/$f"; done
    for f in $(cd "$D" && find . -name '*.py' | sed 's|^\./||'); do check "python compile : $f" python3 -m py_compile "$D/$f"; done

    # Fermeture : chaque nom de fichier cité (hors commentaires) par les scripts d'installation doit exister
    # dans le paquet. verify.sh et lib.sh sont communs aux paquets et citent des fichiers des autres : exclus.
    # les install-*.sh se citent entre eux dans des messages ou en option (install-grafana.sh : test -x), t.timer / f.sql viennent de boucles.
    allow='^(install-(grafana|monitoring|target)\.sh|t\.timer|f\.sql|config\.py|asemon\.env|asemon\.conf|postgresql\.conf|pg_hba\.conf|postgresql\.auto\.conf|pgdg\.list|grafana\.list|grafana\.gpg|postgresql\.gpg|gpg\.key|sources\.list|pg_stat_statements|asemon-purge\.(service|timer)|asemon\.env\.example|manifeste\.txt|requirements\.txt)$'
    refs="$(cd "$D" && cat scripts/install-*.sh scripts/grafana-provision.sh 2>/dev/null | sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' \
        | grep -o '[A-Za-z0-9_][A-Za-z0-9_.-]*\.\(py\|sql\|service\|timer\|json\|sh\|txt\|cron\|example\)' | sort -u)"
    unresolved=""
    for r in $refs; do
        echo "$r" | grep -Eq "$allow" && continue
        [ -n "$(find "$D" -name "$r" -print -quit)" ] || unresolved="$unresolved $r"
    done
    [ -z "$unresolved" ] && ok "tout fichier cité par les scripts est dans le paquet" || ko "cités mais absents du paquet :$unresolved"
done

echo "== instance_monitoring : liste SQL =="
D="$T/x/monAp_pg_instance_monitoring"
miss=""
for s in $(awk '/^SQL_FILES=\(/{f=1} f{print} f&&/\)/{exit}' "$D/scripts/install-monitoring.sh" | sed -e 's/^SQL_FILES=(//' -e 's/)//'); do [ -f "$D/sql/$s.sql" ] || miss="$miss $s"; done
[ -z "$miss" ] && ok "les 15 scripts SQL de SQL_FILES sont dans sql/" || ko "SQL_FILES cite des scripts absents :$miss"
eq "nombre de fichiers sql/" "$(ls "$D/sql" | wc -l)" "15"
[ ! -e "$D/sql/07-schema-phase2-brouillon.sql" ] && ok "le brouillon 07 n'est pas livré" || ko "le brouillon 07 est dans le paquet"

echo "== Grafana : dashboards =="
G="$T/x/monAp_pg_grafana"
eq "dashboards dans le paquet = dashboards du dépôt" "$(ls "$G"/grafana/asemon-*.json | wc -l)" "$(ls "$ROOT"/grafana/asemon-*.json | wc -l)"
for f in "$ROOT"/grafana/asemon-*.json; do cmp -s "$f" "$G/grafana/$(basename "$f")" || ko "dashboard modifié dans le paquet : $f"; done

echo "== pip_install_manifest (lib.sh) =="
mkdir -p "$T/venv/bin"; printf '#!/bin/sh\necho "$@" > "%s/pip.args"\n' "$T" > "$T/venv/bin/pip"; chmod +x "$T/venv/bin/pip"
pipcase() { # pipcase RACINE ARGS... : source lib.sh de RACINE/scripts et appelle pip_install_manifest
    local root="$1"; shift
    ( source "$root/scripts/lib.sh" && pip_install_manifest "$T/venv" "$@" ) && cat "$T/pip.args"
}
eq "paquet cible : manifeste.txt du paquet" "$(pipcase "$T/x/monAp_pg_instance_cible" "$ROOT/python/requirements.txt" -- x)" "install -q -r $T/x/monAp_pg_instance_cible/manifeste.txt"
eq "paquet monitoring : manifeste.txt du paquet" "$(pipcase "$T/x/monAp_pg_instance_monitoring" -- "psycopg[binary]")" "install -q -r $T/x/monAp_pg_instance_monitoring/manifeste.txt"
eq "dépôt Git (cible) : python/requirements.txt" "$(pipcase "$ROOT" "$ROOT/python/requirements.txt" -- x)" "install -q -r $ROOT/python/requirements.txt"
eq "dépôt Git (monitoring) : spécification en ligne" "$(pipcase "$ROOT" -- "psycopg[binary]")" "install -q psycopg[binary]"

echo "== Manifeste Python (venv réel) =="
if python3 -m venv "$T/pyvenv" >/dev/null 2>&1 && "$T/pyvenv/bin/pip" install -q -r "$T/x/monAp_pg_instance_cible/manifeste.txt" >"$T/pip.log" 2>&1; then
    ok "pip install -r manifeste.txt (cible)"
    mkdir -p "$T/app"; cp "$T"/x/monAp_pg_instance_cible/python/*.py "$T/app/"; cp "$T/app/config.py.example" "$T/app/config.py" 2>/dev/null || cp "$T/x/monAp_pg_instance_cible/python/config.py.example" "$T/app/config.py"
    check "import de collector, sampler, log_parser, plan_format, instance, backfill_plans" bash -c "cd '$T/app' && '$T/pyvenv/bin/python3' -c 'import collector, sampler, log_parser, plan_format, instance, backfill_plans'"
    "$T/pyvenv/bin/pip" install -q -r "$T/x/monAp_pg_instance_monitoring/manifeste.txt" >/dev/null 2>&1 && \
        check "import de retention.py (manifeste monitoring)" bash -c "cd '$T/x/monAp_pg_instance_monitoring/python' && '$T/pyvenv/bin/python3' -c 'import retention'"
else
    skip "venv ou accès à PyPI indisponible ($(tail -n 1 "$T/pip.log" 2>/dev/null)) : à vérifier sur une VM"
fi

echo "== SQL du paquet monitoring sur un PostgreSQL de test =="
PGV="$(ls /usr/lib/postgresql 2>/dev/null | sort -n | tail -n 1)"
if [ "$(id -u)" -ne 0 ] || [ -z "$PGV" ] || ! command -v pg_createcluster >/dev/null; then
    skip "root et pg_createcluster requis"
else
    pg_createcluster "$PGV" "$CLUSTER" --port "$PGPORT_TEST" -- -A trust >/dev/null 2>&1
    pg_ctlcluster "$PGV" "$CLUSTER" start 2>&1 | tail -n 2
    P="runuser -u postgres -- psql -X -At -p $PGPORT_TEST"
    for i in $(seq 1 20); do $P -d postgres -c 'select 1' >/dev/null 2>&1 && break; sleep 1; done
    cat > "$T/asemon.env" <<ENV
COLLECTOR_PASSWORD=Test_collector_1
GRAFANA_RO_PASSWORD=Test_grafana_1
GRAFANA_THRESHOLDS_PASSWORD=Test_thresholds_1
ENV
    export ASEMON_ENV="$T/asemon.env" PSQL_CMD="runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -p $PGPORT_TEST"
    check "install-monitoring.sh --sql-only (1re passe)" "$D/scripts/install-monitoring.sh" --sql-only
    check "install-monitoring.sh --sql-only (rejeu)" "$D/scripts/install-monitoring.sh" --sql-only
    q() { $P -d monitoring -c "$1"; }
    eq "schéma asemon : tables et vues créées" "$([ "$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='asemon'")" -ge 30 ] && echo oui)" "oui"
    eq "rôles collector_writer, grafana_ro, grafana_thresholds" "$(q "SELECT count(*) FROM pg_roles WHERE rolname IN ('collector_writer','grafana_ro','grafana_thresholds')")" "3"
    eq "grafana_thresholds peut se connecter (mot de passe fourni)" "$(q "SELECT rolcanlogin FROM pg_roles WHERE rolname='grafana_thresholds'")" "t"
    eq "seuils par défaut (>= 6)" "$([ "$(q "SELECT count(*) FROM asemon.kpi_thresholds WHERE instance_id IS NULL")" -ge 6 ] && echo oui)" "oui"
    check "asemon.rollup_hourly() et compute_kpi_values()" $P -d monitoring -c "SELECT asemon.rollup_hourly(); SELECT asemon.compute_kpi_values();"
    check "grafana_ro lit asemon.snap_os" $P -d monitoring -c "SET ROLE grafana_ro; SELECT 1 FROM asemon.snap_os LIMIT 1"
    # Paquet cible : le script SQL du rôle de collecte
    check "sql/03-target-user.sql (paquet cible) appliqué" bash -c "$P -d postgres < '$T/x/monAp_pg_instance_cible/sql/03-target-user.sql'"
    eq "asemon_collect membre de pg_monitor" "$(q "SELECT pg_has_role('asemon_collect','pg_monitor','member')")" "t"
    unset ASEMON_ENV PSQL_CMD
fi

echo "== install-grafana.sh avec commandes simulées =="
if [ "$(id -u)" -ne 0 ]; then
    skip "root requis"
else
    S="$T/stubs"; mkdir -p "$S"
    for c in grafana-server; do printf '#!/bin/sh\nexit 0\n' > "$S/$c"; done
    printf '#!/bin/sh\necho "grafana $*" >> "%s/calls.log"\n' "$T" > "$S/grafana"
    printf '#!/bin/sh\necho "systemctl $*" >> "%s/calls.log"\n' "$T" > "$S/systemctl"
    chmod +x "$S"/*
    printf 'GRAFANA_RO_PASSWORD=Test_grafana_1\nGRAFANA_ADMIN_PASSWORD=\n' > "$T/gf.env"
    rm -f "$T/calls.log"
    out="$(PATH="$S:$PATH" ASEMON_ENV="$T/gf.env" "$G/scripts/install-grafana.sh" 2>&1)"; rc=$?
    eq "install-grafana.sh se termine sans erreur" "$rc" "0"
    grep -q "grafana cli plugins install marcusolsson-dynamictext-panel" "$T/calls.log" && ok "plugin marcusolsson-dynamictext-panel demandé" || ko "plugin dynamictext non demandé" "$out"
    grep -q "grafana cli plugins install volkovlabs-form-panel" "$T/calls.log" && ok "plugin volkovlabs-form-panel demandé" || ko "plugin form-panel non demandé" "$out"
    grep -q "systemctl restart grafana-server" "$T/calls.log" && ok "Grafana redémarré après les plugins" || ko "pas de redémarrage de Grafana" "$out"
    echo "$out" | grep -q "GRAFANA_ADMIN_PASSWORD vide" && ok "mot de passe admin vide : avertissement, pas d'import" || ko "avertissement attendu absent" "$out"
fi

echo
echo "Résultat : $PASS ok, $FAIL échec(s), $SKIP ignoré(s)"
[ "$FAIL" -eq 0 ]
