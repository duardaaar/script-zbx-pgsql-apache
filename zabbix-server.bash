#!/usr/bin/env bash
# =============================================================================
#  Instalação do Zabbix 7.0 LTS
#  Stack: Ubuntu 26.04 + PostgreSQL + Apache + Zabbix Agent 2
#
#  Parâmetros (no .env ou como variáveis de ambiente):
#     ZBX_DB_PASS   senha do usuário "zabbix" no PostgreSQL (se vazia, é perguntada)
#     ZBX_DB_NAME   nome do banco               (padrão: zabbix)
#     ZBX_DB_USER   usuário do banco            (padrão: zabbix)
#     ZBX_TZ        timezone do frontend/PHP    (padrão: America/Sao_Paulo)
#     ZBX_NAME      nome exibido no frontend    (padrão: hostname)
#
#  Prioridade: variável de ambiente na linha de comando > .env > padrão.
# =============================================================================
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Arquivo .env
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)   ENV_FILE="${2:?Informe o caminho do arquivo após --env}"; shift 2 ;;
        --env=*) ENV_FILE="${1#*=}"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Parâmetro desconhecido: $1"; exit 1 ;;
    esac
done

# Lê o .env linha a linha (sem "source", para não executar código e para
# aceitar senhas com caracteres especiais). Só aceita chaves ZBX_* e não
# sobrescreve variáveis já definidas na linha de comando.
load_env() {
    local file="$1" line key val n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n+1))
        line="${line%$'\r'}"                                   # arquivos editados no Windows
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue        # comentários / linhas vazias
        line="${line#"${line%%[![:space:]]*}"}"                # remove espaços à esquerda
        line="${line#export }"
        if [[ ! "$line" =~ ^(ZBX_[A-Z0-9_]+)=(.*)$ ]]; then
            echo "[AVISO] .env linha ${n} ignorada (formato esperado ZBX_CHAVE=valor)."
            continue
        fi
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        # remove aspas envolventes: "valor" ou 'valor'
        if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        [[ -n "${!key+x}" ]] && continue                       # linha de comando tem prioridade
        printf -v "$key" '%s' "$val"
    done < "$file"
}

if [[ -f "$ENV_FILE" ]]; then
    echo "[INFO]  Carregando parâmetros de ${ENV_FILE}"
    perms=$(stat -c '%a' "$ENV_FILE")
    [[ "$perms" =~ [1-7]$ ]] && echo "[AVISO] ${ENV_FILE} pode ser lido por outros usuários (permissão ${perms}). Recomendado: chmod 600 ${ENV_FILE}"
    load_env "$ENV_FILE"
else
    echo "[INFO]  Arquivo ${ENV_FILE} não encontrado; usando variáveis de ambiente/padrões."
fi

ZBX_VERSION="7.0"
ZBX_DB_NAME="${ZBX_DB_NAME:-zabbix}"
ZBX_DB_USER="${ZBX_DB_USER:-zabbix}"
ZBX_DB_PASS="${ZBX_DB_PASS:-}"
ZBX_TZ="${ZBX_TZ:-America/Sao_Paulo}"
ZBX_NAME="${ZBX_NAME:-$(hostname -s)}"
LOG_FILE="/var/log/zabbix_install_$(date +%Y%m%d_%H%M%S).log"

# -----------------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $*" | tee -a "$LOG_FILE"; }
fatal() { echo -e "${RED}[ERRO]${NC}  $*" | tee -a "$LOG_FILE"; exit 1; }
trap 'fatal "Falha na linha $LINENO. Veja o log: $LOG_FILE"' ERR

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 1. Verificações iniciais
# -----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "Execute como root (sudo)."; exit 1; }
touch "$LOG_FILE"

. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || fatal "Este script é para Ubuntu (detectado: ${ID})."
if [[ "${VERSION_ID}" != "26.04" ]]; then
    warn "Script feito para Ubuntu 26.04, mas o sistema é ${VERSION_ID}. Continuando mesmo assim..."
fi

if [[ -z "$ZBX_DB_PASS" ]]; then
    while true; do
        read -rsp "Defina a senha do usuário '${ZBX_DB_USER}' no PostgreSQL: " p1; echo
        read -rsp "Confirme a senha: " p2; echo
        [[ -n "$p1" && "$p1" == "$p2" ]] && { ZBX_DB_PASS="$p1"; break; }
        echo "Senhas vazias ou diferentes, tente novamente."
    done
fi
# Aspas simples quebrariam o SQL / arquivos de configuração
[[ "$ZBX_DB_PASS" != *"'"* ]] || fatal "A senha não pode conter aspas simples (')."

# -----------------------------------------------------------------------------
# 2. Pacotes base e locale
# -----------------------------------------------------------------------------
info "Atualizando sistema e instalando dependências básicas..."
apt-get update -y >>"$LOG_FILE" 2>&1
apt-get install -y wget curl gnupg ca-certificates locales >>"$LOG_FILE" 2>&1

info "Gerando locales (en_US e pt_BR)..."
sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(pt_BR.UTF-8\)/\1/' /etc/locale.gen
locale-gen >>"$LOG_FILE" 2>&1

timedatectl set-timezone "$ZBX_TZ" 2>>"$LOG_FILE" || warn "Não foi possível definir o timezone do sistema."

# -----------------------------------------------------------------------------
# 3. Repositório oficial do Zabbix 7.0
#    Tenta o pacote para 26.04; se ainda não existir, usa o de 24.04 (compatível).
# -----------------------------------------------------------------------------
info "Configurando repositório Zabbix ${ZBX_VERSION}..."
REPO_OK=0
TMP_DEB="/tmp/zabbix-release.deb"
for UBU in "${VERSION_ID}" "24.04"; do
    for URL in \
        "https://repo.zabbix.com/zabbix/${ZBX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_VERSION}+ubuntu${UBU}_all.deb" \
        "https://repo.zabbix.com/zabbix/${ZBX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_VERSION}+ubuntu${UBU}_all.deb"
    do
        if wget -q -O "$TMP_DEB" "$URL"; then
            info "Usando: $URL"
            [[ "$UBU" != "$VERSION_ID" ]] && warn "Pacote específico para ${VERSION_ID} não encontrado; usando repositório do Ubuntu ${UBU}."
            REPO_OK=1; break 2
        fi
    done
done
[[ $REPO_OK -eq 1 ]] || fatal "Não foi possível baixar o zabbix-release. Verifique https://repo.zabbix.com/zabbix/${ZBX_VERSION}/"

dpkg -i "$TMP_DEB" >>"$LOG_FILE" 2>&1
rm -f "$TMP_DEB"
apt-get update -y >>"$LOG_FILE" 2>&1

# -----------------------------------------------------------------------------
# 4. Instalação dos pacotes
# -----------------------------------------------------------------------------
info "Instalando PostgreSQL, Apache e Zabbix (server, frontend, agent2)..."
apt-get install -y \
    postgresql \
    apache2 \
    zabbix-server-pgsql \
    zabbix-frontend-php \
    php-pgsql \
    php-fpm \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent2 >>"$LOG_FILE" 2>&1

# Plugins opcionais do agent2 (não falha se não existirem)
apt-get install -y zabbix-agent2-plugin-postgresql >>"$LOG_FILE" 2>&1 \
    || warn "Plugin PostgreSQL do agent2 não instalado (opcional)."

systemctl enable --now postgresql >>"$LOG_FILE" 2>&1

# -----------------------------------------------------------------------------
# 5. Banco de dados
# -----------------------------------------------------------------------------
PG_MAJOR=$(sudo -u postgres psql -tAc "SHOW server_version_num;" | cut -c1-2)
info "PostgreSQL detectado: versão ${PG_MAJOR}"

info "Criando usuário e banco '${ZBX_DB_NAME}'..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ZBX_DB_USER}'" | grep -q 1; then
    warn "Usuário ${ZBX_DB_USER} já existe; atualizando a senha."
    sudo -u postgres psql -qc "ALTER USER ${ZBX_DB_USER} WITH PASSWORD '${ZBX_DB_PASS}';" >>"$LOG_FILE"
else
    sudo -u postgres psql -qc "CREATE USER ${ZBX_DB_USER} WITH PASSWORD '${ZBX_DB_PASS}';" >>"$LOG_FILE"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${ZBX_DB_NAME}'" | grep -q 1; then
    warn "Banco ${ZBX_DB_NAME} já existe; o schema NÃO será reimportado."
    IMPORT_SCHEMA=0
else
    sudo -u postgres createdb -O "${ZBX_DB_USER}" -E Unicode -T template0 "${ZBX_DB_NAME}"
    IMPORT_SCHEMA=1
fi

if [[ $IMPORT_SCHEMA -eq 1 ]]; then
    SQL_FILE=""
    for f in /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz \
             /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz; do
        [[ -f "$f" ]] && { SQL_FILE="$f"; break; }
    done
    [[ -n "$SQL_FILE" ]] || fatal "Arquivo server.sql.gz não encontrado."
    info "Importando schema inicial (pode levar alguns minutos)..."
    zcat "$SQL_FILE" | PGPASSWORD="$ZBX_DB_PASS" psql -q -h localhost -U "$ZBX_DB_USER" "$ZBX_DB_NAME" >>"$LOG_FILE" 2>&1
fi

# -----------------------------------------------------------------------------
# 6. Configuração do Zabbix Server
# -----------------------------------------------------------------------------
info "Configurando /etc/zabbix/zabbix_server.conf..."
ZBX_CONF=/etc/zabbix/zabbix_server.conf
cp -n "$ZBX_CONF" "${ZBX_CONF}.orig" || true

set_conf() {  # set_conf <chave> <valor> <arquivo>
    local k="$1" v="$2" f="$3"
    if grep -qE "^#?\s*${k}=" "$f"; then
        sed -i "0,/^#\?\s*${k}=.*/s||${k}=${v}|" "$f"
    else
        echo "${k}=${v}" >> "$f"
    fi
}
set_conf DBHost     localhost        "$ZBX_CONF"
set_conf DBName     "$ZBX_DB_NAME"   "$ZBX_CONF"
set_conf DBUser     "$ZBX_DB_USER"   "$ZBX_CONF"
set_conf DBPassword "$ZBX_DB_PASS"   "$ZBX_CONF"
chmod 640 "$ZBX_CONF"; chown root:zabbix "$ZBX_CONF"

# O Zabbix 7.0 valida a versão do banco. Se o Ubuntu 26.04 trouxer um
# PostgreSQL mais novo que o oficialmente suportado, o server não sobe.
if [[ "$PG_MAJOR" =~ ^[0-9]+$ && "$PG_MAJOR" -gt 17 ]]; then
    warn "PostgreSQL ${PG_MAJOR} pode não ser oficialmente suportado pelo Zabbix 7.0; habilitando AllowUnsupportedDBVersions=1."
    set_conf AllowUnsupportedDBVersions 1 "$ZBX_CONF"
fi

# -----------------------------------------------------------------------------
# 7. Frontend (PHP/Apache) - pré-configura para pular o assistente web
# -----------------------------------------------------------------------------
info "Configurando frontend web (Apache + PHP-FPM)..."
# Versão do PHP detectada pelo diretório do FPM (não depende do php-cli)
PHP_VER=$(ls -d /etc/php/*/fpm 2>/dev/null | sort -V | tail -n1 | cut -d/ -f4)
[[ -n "$PHP_VER" ]] || fatal "PHP-FPM não encontrado em /etc/php/*/fpm."
PHP_FPM_SVC="php${PHP_VER}-fpm"
info "PHP ${PHP_VER} detectado (serviço ${PHP_FPM_SVC})."

# O zabbix-apache-conf repassa o PHP ao FPM via proxy_fcgi; sem esses
# módulos o Apache não sobe.
a2enmod proxy proxy_fcgi setenvif >>"$LOG_FILE" 2>&1
a2enconf "${PHP_FPM_SVC}" >>"$LOG_FILE" 2>&1 || warn "a2enconf ${PHP_FPM_SVC} não disponível."
a2enconf zabbix >>"$LOG_FILE" 2>&1 || true

# Parâmetros do PHP no FPM (o conf.d do apache2 não é usado com FPM)
for d in "/etc/php/${PHP_VER}/fpm/conf.d" "/etc/php/${PHP_VER}/apache2/conf.d"; do
    [[ -d "$d" ]] || continue
    cat > "${d}/99-zabbix.ini" <<EOF
date.timezone = ${ZBX_TZ}
max_execution_time = 300
max_input_time = 300
memory_limit = 256M
post_max_size = 16M
upload_max_filesize = 2M
EOF
done

# Pool FPM dedicado do Zabbix (se o pacote criou um), ajusta o timezone
for pool in /etc/php/${PHP_VER}/fpm/pool.d/zabbix*.conf /etc/zabbix/php-fpm.conf; do
    [[ -f "$pool" ]] || continue
    if grep -q 'date.timezone' "$pool"; then
        sed -i "s|^;\?\s*php_value\[date.timezone\].*|php_value[date.timezone] = ${ZBX_TZ}|" "$pool"
    else
        echo "php_value[date.timezone] = ${ZBX_TZ}" >> "$pool"
    fi
done

WEB_CONF=/etc/zabbix/web/zabbix.conf.php
if [[ ! -f "$WEB_CONF" ]]; then
    cat > "$WEB_CONF" <<EOF
<?php
// Gerado pelo script de instalação em $(date '+%F %T')
\$DB['TYPE']                     = 'POSTGRESQL';
\$DB['SERVER']                   = 'localhost';
\$DB['PORT']                     = '0';
\$DB['DATABASE']                 = '${ZBX_DB_NAME}';
\$DB['USER']                     = '${ZBX_DB_USER}';
\$DB['PASSWORD']                 = '${ZBX_DB_PASS}';
\$DB['SCHEMA']                   = '';
\$DB['ENCRYPTION']               = false;
\$DB['KEY_FILE']                 = '';
\$DB['CERT_FILE']                = '';
\$DB['CA_FILE']                  = '';
\$DB['VERIFY_HOST']              = false;
\$DB['CIPHER_LIST']              = '';
\$DB['VAULT']                    = '';
\$DB['VAULT_URL']                = '';
\$DB['VAULT_PREFIX']             = '';
\$DB['VAULT_DB_PATH']            = '';
\$DB['VAULT_TOKEN']              = '';
\$DB['VAULT_CERT_FILE']          = '';
\$DB['VAULT_KEY_FILE']           = '';
\$DB['DOUBLE_IEEE754']           = true;

\$ZBX_SERVER_NAME                = '${ZBX_NAME}';

\$IMAGE_FORMAT_DEFAULT           = IMAGE_FORMAT_PNG;
EOF
    chown www-data:www-data "$WEB_CONF"
    chmod 640 "$WEB_CONF"
else
    warn "$WEB_CONF já existe; mantido sem alterações."
fi

# Redireciona a raiz do Apache para /zabbix
if [[ -f /var/www/html/index.html ]]; then
    mv /var/www/html/index.html /var/www/html/index.html.bak
    echo '<?php header("Location: /zabbix/"); ?>' > /var/www/html/index.php
fi

# -----------------------------------------------------------------------------
# 8. Firewall (somente se UFW estiver ativo)
# -----------------------------------------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    info "Liberando portas no UFW (80, 443, 10050, 10051)..."
    ufw allow 80/tcp    >>"$LOG_FILE"
    ufw allow 443/tcp   >>"$LOG_FILE"
    ufw allow 10050/tcp >>"$LOG_FILE"
    ufw allow 10051/tcp >>"$LOG_FILE"
fi

# -----------------------------------------------------------------------------
# 9. Serviços
# -----------------------------------------------------------------------------
info "Validando configuração do Apache..."
apache2ctl configtest >>"$LOG_FILE" 2>&1 \
    || warn "apache2ctl configtest reportou erro — veja o log: $LOG_FILE"

info "Habilitando e iniciando serviços..."
SERVICES=(postgresql "$PHP_FPM_SVC" zabbix-server zabbix-agent2 apache2)
# Reinicia um por um e sem abortar o script: uma falha aqui é reportada
# no resumo abaixo em vez de interromper a instalação.
for svc in "${SERVICES[@]}"; do
    systemctl enable "$svc" >>"$LOG_FILE" 2>&1 || true
    if ! systemctl restart "$svc" >>"$LOG_FILE" 2>&1; then
        warn "Falha ao reiniciar ${svc}; tentando novamente em 5s..."
        sleep 5
        systemctl restart "$svc" >>"$LOG_FILE" 2>&1 || true
    fi
done

sleep 5
for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        info "  ${svc}: ativo"
    else
        warn "  ${svc}: INATIVO — verifique: journalctl -u ${svc} -n 50"
    fi
done
if grep -qi "database version" /var/log/zabbix/zabbix_server.log 2>/dev/null; then
    warn "Mensagens sobre versão do banco no log do server:"
    grep -i "database version" /var/log/zabbix/zabbix_server.log | tail -n 3
fi

# -----------------------------------------------------------------------------
# 10. Resumo
# -----------------------------------------------------------------------------
IP=$(hostname -I | awk '{print $1}')
cat <<EOF | tee -a "$LOG_FILE"

=====================================================================
 Zabbix ${ZBX_VERSION} LTS instalado!

 Frontend : http://${IP}/zabbix
 Login    : Admin
 Senha    : zabbix     (TROQUE IMEDIATAMENTE após o primeiro acesso)

 Banco    : PostgreSQL ${PG_MAJOR} — db=${ZBX_DB_NAME} user=${ZBX_DB_USER}
 Log      : ${LOG_FILE}
=====================================================================
EOF
