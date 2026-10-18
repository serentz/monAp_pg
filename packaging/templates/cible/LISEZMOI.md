# monAp_pg : paquet « instance cible » ({{VERSION}})

Installe sur **VM-Cible** (la machine PostgreSQL à surveiller) tout ce qui collecte et envoie les mesures au repository :

| Composant | Rôle | Fréquence |
|---|---|---|
| `asemon-collector` | instantanés : activité, requêtes, caches, système, tailles | toutes les 15 s |
| `asemon-sampler` | échantillonnage des sessions actives | toutes les 2 s |
| `asemon-logparser` | lecture des journaux JSON PostgreSQL : deadlocks, plans lents, connexions | en continu |

À installer **après** le paquet `monAp_pg_instance_monitoring` (le repository doit exister). Une VM-Cible de plus = ce même paquet sur une autre machine, avec un `INSTANCE_NAME` différent.

## Contenu

| Fichier | Rôle |
|---|---|
| `install.sh` | installation complète (rejouable) |
| `verify.sh` | contrôles après installation |
| `manifeste.txt` | paquets Python du venv (`pip install -r`) |
| `python/` | scripts : `collector.py`, `sampler.py`, `log_parser.py`, `plan_format.py`, `backfill_plans.py`, `instance.py`, modèle `config.py.example` |
| `sql/03-target-user.sql` | rôle de collecte `asemon_collect` (droit `pg_monitor`) et extension `pg_stat_statements` |
| `systemd/` | unités `asemon-collector`, `asemon-sampler`, `asemon-logparser` |
| `scripts/` | scripts appelés par `install.sh` et `asemon.env.example` |
| `SHA256SUMS`, `VERSION` | contrôle d'intégrité, version |

## 1. Prérequis

- Ubuntu Server 24.04 ou plus récent, accès Internet (`apt`, PyPI, dépôt PostgreSQL PGDG).
- Un compte Linux avec `sudo`, qui fera tourner les services (`SERVICE_USER`, `admin01` au POC) : il doit **déjà exister**.
- VM-Monitoring installée, joignable en réseau (IP stable : elle est écrite dans `config.py`).
- RAM fixe sous Hyper-V (pas de mémoire dynamique).

## 2. Installation

```bash
tar xzf monAp_pg_instance_cible.tgz
cd monAp_pg_instance_cible
sha256sum -c SHA256SUMS --quiet && echo "paquet intact"

cp scripts/asemon.env.example scripts/asemon.env
nano scripts/asemon.env          # voir « Paramètres » ci-dessous

sudo ./install.sh
```

> **`install.sh` redémarre PostgreSQL** si sa configuration change (coupure de quelques secondes) : il active `pg_stat_statements`, `auto_explain`, `pg_stat_kcache`, les journaux JSON, `lc_messages = 'C'` et `log_timezone = 'UTC'` dans un fichier unique `conf.d/asemon.conf`. Ne pas utiliser `ALTER SYSTEM` pour ces paramètres.

### Paramètres (`scripts/asemon.env`)

| Variable | À renseigner |
|---|---|
| `MONITORING_IP` | IP de VM-Monitoring |
| `COLLECTOR_PASSWORD` | **le même** que dans le paquet monitoring (compte `collector_writer`) |
| `ASEMON_COLLECT_PASSWORD` | mot de passe du compte `asemon_collect` créé ici |
| `SERVICE_USER` | compte Linux des services |
| `INSTANCE_NAME` | nom de cette machine dans les dashboards (unique ; lettres, chiffres, `. _ -`) |
| `PG_VERSION`, `INSTALL_DIR`, `INTERVAL`, `SAMPLE_INTERVAL`, `TARGET_ALLOW_SUBNET` | facultatifs : valeurs par défaut commentées dans le fichier |

Mots de passe : 8 caractères minimum, lettres, chiffres et `. _ @ % + = -` seulement. Les autres variables du fichier (`GRAFANA_*`, `SUBNET`...) servent aux autres paquets et sont ignorées ici.

## 3. Ce que fait `install.sh`, et son équivalent à la main

**Composants**

```bash
sudo apt install -y postgresql-17 postgresql-17-pg-stat-kcache python3 python3-venv python3-pip
# (dépôt apt PGDG à ajouter avant si besoin : https://www.postgresql.org/download/linux/ubuntu/)
```

**Venv Python** (`manifeste.txt` : `psycopg[binary]`, `psutil`, `sqlparse`)

```bash
sudo mkdir -p /opt/asemon/app
sudo python3 -m venv /opt/asemon/venv
sudo /opt/asemon/venv/bin/pip install -r manifeste.txt
sudo install -m 0644 python/*.py /opt/asemon/app/
sudo cp python/config.py.example /opt/asemon/app/config.py   # puis éditer TARGET_DSN, REPO_DSN, INSTANCE_NAME
```

**SQL** (sur l'instance surveillée ; le script fixe aussi le mot de passe)

```bash
sudo -u postgres psql -d postgres < sql/03-target-user.sql
sudo -u postgres psql -d postgres -c "ALTER USER asemon_collect WITH PASSWORD '<mot de passe>';"
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_kcache CASCADE;"
```

(Le `<` est volontaire : l'utilisateur `postgres` ne peut pas lire un fichier dans `/home`.)

**Services**

```bash
sudo cp systemd/*.service /etc/systemd/system/     # puis adapter User= (SERVICE_USER) dans collector et sampler
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-collector asemon-sampler asemon-logparser
```

## 4. Vérification

Une minute après la fin de `install.sh` :

```bash
sudo ./verify.sh                                   # tous les contrôles doivent être verts
sudo journalctl -u asemon-collector -n 20 --no-pager   # « Snapshot OK » toutes les 15 s
```

Côté VM-Monitoring, `sudo ./verify.sh` du paquet monitoring doit montrer des compteurs de lignes qui montent.

## 5. Planification (systemd, ou cron)

Ces trois composants sont des **services permanents** : systemd les démarre au boot et les relance en cas d'arrêt (`Restart=always`). Commandes utiles :

```bash
systemctl status asemon-collector asemon-sampler asemon-logparser
sudo systemctl restart asemon-collector asemon-sampler       # après modification de config.py
```

Sans systemd (**non testé**, sans relance automatique) : en `crontab -e` de `SERVICE_USER` pour collector et sampler, et de `postgres` pour log_parser :

```cron
@reboot cd /opt/asemon/app && nohup /opt/asemon/venv/bin/python3 collector.py  >> /var/log/asemon-collector.log 2>&1 &
@reboot cd /opt/asemon/app && nohup /opt/asemon/venv/bin/python3 sampler.py    >> /var/log/asemon-sampler.log 2>&1 &
@reboot cd /opt/asemon/app && nohup /opt/asemon/venv/bin/python3 log_parser.py >> /var/log/asemon-logparser.log 2>&1 &
```

## 6. Mise à jour et désinstallation

- **Mise à jour** : extraire le nouveau paquet, recopier `scripts/asemon.env` dedans, relancer `sudo ./install.sh`. Le `config.py` existant est conservé (`sudo FORCE_CONFIG=1 ./install.sh` pour le régénérer).
- **Désinstallation** :

```bash
sudo systemctl disable --now asemon-collector asemon-sampler asemon-logparser
sudo rm /etc/systemd/system/asemon-{collector,sampler,logparser}.service && sudo systemctl daemon-reload
sudo rm -r /opt/asemon
# facultatif : retirer /etc/postgresql/<version>/main/conf.d/asemon.conf (puis redémarrer PostgreSQL)
# facultatif : sudo -u postgres psql -c "DROP ROLE asemon_collect;"
```

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| « postgresql.auto.conf redéfinit … » | un `ALTER SYSTEM` antérieur : `ALTER SYSTEM RESET <paramètre>;` puis relancer |
| PostgreSQL ne redémarre pas | `journalctl -xeu postgresql@17-main` ; paquet `pg_stat_kcache` absent ? |
| Collecteur : `connection refused` / timeout | `MONITORING_IP`, pare-feu, `SUBNET` côté monitoring ; mot de passe `COLLECTOR_PASSWORD` différent |
| Rien dans les dashboards | attendre une minute ; `journalctl -u asemon-collector` |
