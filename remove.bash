#!/usr/bin/env bash
# =============================================================================
#  Remove TUDO que o install_zabbix7_pgsql_apache.sh instalou/configurou:
#  Zabbix, PostgreSQL (com TODOS os bancos), Apache e PHP.
#
#  Uso:
#     sudo bash uninstall_zabbix7_pgsql_apache.sh
#     sudo bash uninstall_zabbix7_pgsql_apache.sh -y   # sem confirmação
# =============================================================================
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "Execute como root (sudo)."; exit 1; }
export DEBIAN_FRONTEND=noninteractive

if [[ "${1:-}" != "-y" ]]; then
    cat <<'EOF'
ATENÇÃO: isto vai remover completamente:
  - Zabbix (server, frontend, agent2, repositório)
  - PostgreSQL e TODOS os bancos de dados deste servidor
  - Apache e PHP (incluindo configurações)
Use apenas em máquina de teste.
EOF
    read -rp "Digite REMOVER para continuar: " ans
    [[ "$ans" == "REMOVER" ]] || { echo "Cancelado."; exit 0; }
fi

echo "[1/6] Parando serviços..."
for svc in zabbix-server zabbix-agent2 apache2 postgresql; do
    systemctl disable --now "$svc" 2>/dev/null || true
done
for svc in $(systemctl list-units --all --plain --no-legend 'php*-fpm.service' | awk '{print $1}'); do
    systemctl disable --now "$svc" 2>/dev/null || true
done

echo "[2/6] Removendo pacotes (purge)..."
apt-get purge -y 'zabbix-*' zabbix-release 'apache2*' 'libapache2-mod-php*' \
    'php*' 'postgresql*' 2>/dev/null || true
apt-get autoremove --purge -y
apt-get clean

echo "[3/6] Removendo diretórios e arquivos restantes..."
rm -rf /etc/zabbix /var/log/zabbix /run/zabbix /usr/share/zabbix /usr/share/zabbix-sql-scripts \
       /etc/apache2 /var/log/apache2 \
       /etc/php /var/lib/php /run/php \
       /etc/postgresql /etc/postgresql-common /var/lib/postgresql /var/log/postgresql
rm -f /var/log/zabbix_install_*.log

# Página padrão do Apache (o instalador renomeou index.html e criou index.php)
rm -f /var/www/html/index.php
[[ -f /var/www/html/index.html.bak ]] && mv /var/www/html/index.html.bak /var/www/html/index.html

echo "[4/6] Removendo repositório do Zabbix..."
rm -f /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources \
      /etc/apt/trusted.gpg.d/zabbix*.gpg /usr/share/keyrings/zabbix*.gpg
apt-get update -y >/dev/null

echo "[5/6] Removendo usuários de sistema..."
for u in zabbix postgres; do
    id "$u" &>/dev/null && userdel "$u" 2>/dev/null || true
done
for g in zabbix postgres; do
    getent group "$g" &>/dev/null && groupdel "$g" 2>/dev/null || true
done

echo "[6/6] Removendo regras do UFW (se ativo)..."
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    for p in 80 443 10050 10051; do
        ufw --force delete allow "${p}/tcp" >/dev/null 2>&1 || true
    done
fi

systemctl daemon-reload
echo
echo "Remoção concluída. Verificação (deve vir vazio):"
dpkg -l | grep -E '^ii\s+(zabbix|apache2|php|postgresql)' || echo "  nenhum pacote restante."
