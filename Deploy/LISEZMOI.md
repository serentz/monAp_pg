# Deploy : archives de déploiement monAp_pg

| Archive | Pour |
|---|---|
| `monAp_pg_instance_monitoring.tgz` | VM-Monitoring (à installer en premier) |
| `monAp_pg_grafana.tgz` | Grafana (même VM ou autre) |
| `monAp_pg_instance_cible.tgz` | chaque VM surveillée |

Contrôle : `sha256sum -c SHA256SUMS`. Dans chaque archive, le `LISEZMOI.md` donne la procédure.
Ces fichiers sont générés par `packaging/build_packages.sh` (ne pas les modifier à la main) ; voir [docs/24-paquets-deploiement.md](../docs/24-paquets-deploiement.md).
