# Instalador — Rotina de Backup PostgreSQL MigraTI

Este repositório só distribui o instalador e o pacote **cifrado** da rotina.
O pacote muda todo dia às 00:00 UTC (21:00 em Brasília) e só abre com a chave do dia,
que a equipe MigraTI consulta no repositório privado da rotina.

```bash
curl -fsSLO https://raw.githubusercontent.com/MigraTI/bkp-postgres-instalador/main/install.sh && sudo bash install.sh
```

Arquivos atualizados automaticamente pelo GitHub Actions. Não edite aqui.
