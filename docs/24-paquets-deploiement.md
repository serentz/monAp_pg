# Paquets de déploiement (v2.2)

> **Statut : écrit le 2026-10-18, à valider sur VM neuves.** Testé en local : construction reproductible, contenu des archives, syntaxe des scripts, scripts SQL du paquet monitoring appliqués deux fois sur un PostgreSQL de test, `install-grafana.sh` avec commandes simulées. **Non testé** : installation réelle des paquets `apt` et du venv Python (`manifeste.txt`), unités systemd, API Grafana.

Au lieu de cloner tout le dépôt sur chaque VM, on dépose **une archive par fonction**. Chaque archive contient ce qui est nécessaire à son installation, un `LISEZMOI.md` (composants à installer, SQL à exécuter, planification systemd et cron, vérification, mise à jour, désinstallation) et un fichier `SHA256SUMS`.

| Archive | Où | Contenu |
|---|---|---|
| `monAp_pg_instance_monitoring.tgz` | VM-Monitoring | scripts SQL du repository (`01` à `17`), `retention.py`, timers systemd et équivalent cron, `manifeste.txt` du venv |
| `monAp_pg_instance_cible.tgz` | chaque VM surveillée | collecteur, échantillonneur, parseur de journaux, `03-target-user.sql`, services systemd, `manifeste.txt` du venv |
| `monAp_pg_grafana.tgz` | VM-Monitoring ou autre machine | dashboards JSON, liste des plugins, scripts d'installation de Grafana, de la source de données et de l'import |

## Ordre d'installation

1. `monAp_pg_instance_monitoring` (le repository doit exister avant toute collecte) ;
2. `monAp_pg_grafana` (sur la même VM ou une autre) ;
3. `monAp_pg_instance_cible`, sur chaque machine à surveiller (un `INSTANCE_NAME` différent par machine).

Dans chaque archive : `cp scripts/asemon.env.example scripts/asemon.env`, éditer, puis `sudo ./install.sh` et `sudo ./verify.sh`. Les mots de passe `COLLECTOR_PASSWORD` et `GRAFANA_RO_PASSWORD` doivent être **identiques** dans les archives qui les partagent.

Le détail (variables utiles, étapes manuelles équivalentes, planification, dépannage) est dans le `LISEZMOI.md` de chaque archive.

## Construire les archives

Les archives ne sont pas versionnées dans Git : elles sont fabriquées à partir du dépôt (une seule source de vérité).

```bash
packaging/build_packages.sh            # version = git describe ; ou : packaging/build_packages.sh v2.2
# -> dist/monAp_pg_instance_cible.tgz, dist/monAp_pg_instance_monitoring.tgz, dist/monAp_pg_grafana.tgz, dist/SHA256SUMS
```

Sous Windows : Git Bash ou WSL (le script a besoin de `bash`, `tar`, `gzip`, `sha256sum`, `python3`). Copie vers les VM :

```powershell
scp dist\monAp_pg_instance_monitoring.tgz admin01@192.168.1.28:~/
scp dist\monAp_pg_instance_cible.tgz      admin01@192.168.1.30:~/
```

Les archives sont **reproductibles** : mêmes sources, mêmes octets (`dist/SHA256SUMS` permet de le constater). Ce qui est propre aux archives (LISEZMOI, `install.sh`, `verify.sh`, manifeste, cron) est dans `packaging/templates/`.

## Tests

```bash
sudo packaging/test_packages.sh
```

Contrôle le contenu des archives et leurs empreintes, la syntaxe de tous les scripts, que chaque fichier cité par un script d'installation est bien dans l'archive, le manifeste Python (venv réel, si PyPI est joignable), les scripts SQL sur un cluster PostgreSQL temporaire (root et `pg_createcluster` requis) et `install-grafana.sh` avec des commandes simulées. Les étapes sans prérequis sont signalées `SKIP`.

## Ce que cette version change dans les scripts

| Changement | Pourquoi |
|---|---|
| `scripts/install-grafana.sh` (nouveau) | l'installation de Grafana sort de `install-monitoring.sh` ; elle est appelée automatiquement quand le script est présent (dépôt Git), absente de l'archive monitoring |
| `grafana/plugins.txt` (nouveau) | liste des plugins lue par `install-grafana.sh` |
| `GRAFANA_DB_HOST` dans `asemon.env` (défaut `localhost`) | source de données Grafana vers un repository situé sur une autre machine |
| `scripts/verify.sh grafana` (nouveau) | contrôle Grafana, plugins, source de données, dashboards |
| `verify.sh monitoring` | ne contrôle Grafana que s'il est installé sur la machine |
| `pip_install_manifest` dans `lib.sh` | utilise `manifeste.txt` de l'archive ; dans le dépôt Git, `python/requirements.txt` comme avant |

Le chemin « dépôt Git + `install-monitoring.sh` / `install-target.sh` » (docs/15) fonctionne comme avant.
