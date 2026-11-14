#!/bin/bash
# ==============================================================================
#  install.sh — Instalador da rotina de backup PostgreSQL · MigraTI · versão 2.6
#
#  Uso:
#    sudo bash install.sh                         baixa o pacote do dia (sem token)
#    sudo bash install.sh --package pacote.tar.gz usa um pacote local
#    sudo bash install.sh --branch BRANCH         baixa de outro branch
#    sudo bash install.sh --uninstall             remove a rotina (mantém backups)
#
#  Modos detectados automaticamente: instalação nova, migração da 1.x e
#  atualização da 2.x. Nada é alterado no servidor antes de o pacote ser
#  baixado e aberto com a chave de distribuição do dia (DIST_KEY_TODAY).
# ==============================================================================
set -o pipefail
umask 077
export LC_ALL=C

VERSAO_INSTALADOR="2.6"
GITHUB_ORG="MigraTI"
GITHUB_REPO="bkp-postgres-instalador"   # público: só install.sh + pacote cifrado (o código fica no repositório privado)
GITHUB_BRANCH="main"
DIR_PADRAO="/etc/migrabkp"
LINK_TOOL="/usr/local/bin/migra-wallet-pg"
CRON_FILE_2X="/etc/cron.d/migrabkp-postgres"   # usado só pela 2.0; a 2.1 agenda no crontab do root
CRON_TAG="# Backup PostgreSQL - MigraTI"         # 2.1 a 2.4 gravavam este comentário acima da linha
# Cabeçalho padrão MigraTI no crontab (entra uma vez, só se ainda não existir)
CRON_HEADER=(
    '##########################################'
    '#  Ambiente gerenciado e monitorado por  #'
    '#        MigraTI Solucoes em TI          #'
    '#      Tel/whats: (47) 3328 0996         #'
    '##########################################'
)
PENDENCIAS=()   # "texto|detalhe": ações que o técnico precisa fazer (mostradas no fim)
CONF_1X_LINK="/etc/migra_postgres.conf"
SCRIPTS=(bkp_postgres.sh migra-wallet-pg)
TS=$(date +%Y%m%d_%H%M%S)

# >>> MIGRA-CRYPT v2 >>>
# ------------------------------------------------------------------------------
# Bloco compartilhado: criptografia da wallet + schema da configuração.
# Fonte de verdade: lib/migra-crypt.sh. Ele é copiado, idêntico, para dentro de
# install.sh, bkp_postgres.sh e migra-wallet-pg por scripts/sync-crypt-block.sh.
# NÃO edite a cópia dentro dos scripts: edite a lib e rode o sync.
# ------------------------------------------------------------------------------
MC_MAGIC='# MIGRA-WALLET-PG v2'
MC_ITER=600000
MC_SECRET_KEYS=" PGPASSWORD AWS_SECRET_ACCESS_KEY "

# CHAVE|tipo|padrão|descrição
#   tipos: txt (livre)  req (obrigatório)  int (inteiro >= 0)  lvl (0-9)
#          yn (S/N)  fmt (sql/directory/custom)  path (absoluto ou vazio)
#          apath (absoluto obrigatório)  secret (senha; mascarada na exibição)
#          multi (pode repetir a linha; os valores ficam juntos, separados por quebra de linha)
MC_SCHEMA=(
    "VERSION|txt|2.6|Versão da rotina que gerou esta wallet"
    "PGHOST|req|localhost|Host do PostgreSQL (ou diretório do socket)"
    "PGPORT|int|5432|Porta do PostgreSQL"
    "PGUSER|req|migrabkp|Usuário do banco usado no backup"
    "PGPASSWORD|secret||Senha do usuário (vira .pgpass temporário em RAM; nunca é exportada)"
    "PGDATABASE|req|postgres|Banco usado para conectar e listar as bases"
    "PG_BIN|apath|/usr/bin|Diretório do pg_dump/psql compatível com a versão do servidor"
    "DIR_BKP|apath|/backup/postgres|Diretório local dos backups"
    "LOG_GERAL|apath|/var/log/backup/bkp_log_geral_postgres.log|Log geral da rotina"
    "BKP_FORMATO|fmt|directory|Formato do backup: sql, directory ou custom"
    "QTDCORES|int|2|Jobs paralelos do pg_dump (só formato directory)"
    "NIVEL_COMPACTACAO|lvl|5|Nível de compactação, de 0 a 9"
    "USE_PIGZ|yn|N|Formato sql: compactar com pigz (paralelo) em vez de gzip"
    "PIGZ_THREADS|int|2|Threads do pigz"
    "BKP_GLOBALS|yn|S|Salvar roles e tablespaces (pg_dumpall --globals-only)"
    "BKP_CONFIG|yn|S|Copiar postgresql.conf, pg_hba.conf e pg_ident.conf em cada execução (só se o PostgreSQL roda nesta máquina)"
    "EXCLUDE_BASES|txt|template0,template1,postgres|Bases ignoradas, separadas por vírgula"
    "EXCLUDE_TABLE|multi||Tabela ignorada no backup, uma linha por tabela: base, schema, tabela, motivo, usuário e data separados por barra vertical (use migra-wallet-pg -excludeTable)"
    "RETENCAO_BKP|int|5|Retenção local em dias"
    "RETENCAO_MIN_COPIAS|int|1|Execuções mais recentes sempre mantidas em cada destino"
    "RETENCAO_ARQ_LOG|int|30|Retenção dos logs por base, em dias"
    "REMOTE_MODE|yn|N|Copiar para storage montado (NFS/CIFS)"
    "REMOTE_STRING|path|/mnt/remoto|Ponto de montagem (precisa estar no fstab ou já montado)"
    "PATH_REMOTO|txt||Subpasta dentro da montagem (vazio = raiz)"
    "RETENCAO_BKP_REMOTO|int|7|Retenção no storage remoto, em dias"
    "REMOTE_EXTRA|yn|N|Copiar também para um segundo storage"
    "REMOTE_STRING2|path|/mnt/bkp2|Ponto de montagem do segundo storage"
    "PATH_REMOTO2|txt||Subpasta dentro da segunda montagem"
    "RETENCAO_BKP_REMOTO2|int|7|Retenção no segundo storage, em dias"
    "IS_S3|yn|N|Enviar para bucket S3"
    "BUCKET_NAME|txt||Nome do bucket"
    "FOLDER_S3|txt||Pasta dentro do bucket (vazio = raiz)"
    "RETENCAO_BKP_S3|int|30|Retenção no S3, em dias"
    "AWS_PROFILE|txt||Perfil do aws cli (vazio = padrão)"
    "AWS_DEFAULT_REGION|txt||Região AWS (vazio = a do perfil)"
    "AWS_ACCESS_KEY_ID|txt||Access key (vazio = usa perfil/IAM role)"
    "AWS_SECRET_ACCESS_KEY|secret||Secret key (vazio = usa perfil/IAM role)"
    "TITAN|yn|N|Enviar status ao Zabbix/Titan"
    "PATH_TITAN|path|/usr/bin|Diretório do zabbix_sender"
    "SENDER|txt|zabbix_sender|Nome do executável do sender"
    "T_CONF|path|/etc/zabbix/zabbix_agentd.conf|Configuração do agente Zabbix"
    "T_IP|txt||Servidor Zabbix/Titan"
    "T_HOST|txt||Hostname cadastrado no Zabbix"
    "T_KEY|txt|Backup_Postgres|Chave do item no Zabbix"
)

# Arquivo temporário em RAM quando possível (chmod 600 garantido pelo umask 077 do chamador
# e reforçado aqui).
_mc_tmp() {
    local t=""
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
        t=$(mktemp -p /dev/shm .migra.XXXXXXXXXX 2>/dev/null)
    fi
    if [ -z "$t" ]; then
        t=$(mktemp "${TMPDIR:-/tmp}/.migra.XXXXXXXXXX") || return 1
    fi
    chmod 600 "$t" && printf '%s\n' "$t"
}

# Chave da máquina = SHA-256 do machine-id. Retorna 1 se não houver machine-id válido
# (arquivo ausente OU vazio — imagens de VM costumam ter o arquivo vazio).
_mc_machine_key() {
    local f m=""
    for f in ${MC_MACHINE_ID_FILES:-/etc/machine-id /var/lib/dbus/machine-id}; do
        [ -r "$f" ] || continue
        m=$(tr -d '[:space:]' < "$f")
        [ -n "$m" ] && break
    done
    [ -n "$m" ] || return 1
    printf '%s' "$m" | openssl dgst -sha256 | awk '{print $NF}'
}

# OpenSSL >= 1.1.1 aceita -pbkdf2/-iter.
_mc_has_pbkdf2() {
    _MC_PASS=teste openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 1 \
        -pass env:_MC_PASS -in /dev/null -out /dev/null 2>/dev/null
}

# _mc_cipher <e|d> <legacy|pbkdf2> <iter> <senha> [entrada] [saida]
# "-" (ou omitido) = stdin/stdout. A senha vai por variável de ambiente, nunca por argumento.
_mc_cipher() {
    local mode="$1" kdf="$2" iter="$3" pass="$4" in="${5:--}" out="${6:--}"
    local -a args=(enc -aes-256-cbc -md sha256)
    if [ "$mode" = d ]; then args+=(-d); fi
    case "$kdf" in
        pbkdf2) args+=(-pbkdf2 -iter "$iter") ;;
        legacy) ;;
        *) return 1 ;;
    esac
    if [ "$in" != "-" ]; then args+=(-in "$in"); fi
    if [ "$out" != "-" ]; then args+=(-out "$out"); fi
    _MC_PASS="$pass" openssl "${args[@]}" -pass env:_MC_PASS 2>/dev/null
}

# _mc_write <arquivo> <WALLET|AUTO> <legacy|pbkdf2> <senha> <arquivo_texto>
# Gravação atômica: cifra num temporário do mesmo diretório e faz mv.
_mc_write() {
    local file="$1" kind="$2" kdf="$3" pass="$4" plain="$5" iter=0 tmp
    if [ "$kdf" = pbkdf2 ]; then iter=$MC_ITER; fi
    tmp=$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX") || return 1
    chmod 600 "$tmp"
    if { printf 'MIGRA%s 2 %s %s\n' "$kind" "$kdf" "$iter" \
         && _mc_cipher e "$kdf" "$iter" "$pass" "$plain" -; } > "$tmp"; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# _mc_read <arquivo> <senha>  -> texto em stdout
# Retorno: 0 ok | 1 senha/chave incorreta | 2 arquivo ausente ou formato inválido
_mc_read() {
    local file="$1" pass="$2" magic ver kdf iter hlen out
    [ -r "$file" ] || return 2
    read -r magic ver kdf iter < "$file" || return 2
    case "$magic" in MIGRAWALLET|MIGRAAUTO) ;; *) return 2 ;; esac
    [ "$ver" = 2 ] || return 2
    case "$kdf" in pbkdf2|legacy) ;; *) return 2 ;; esac
    [[ "$iter" =~ ^[0-9]+$ ]] || return 2
    hlen=$(head -n 1 "$file" | wc -c)
    # tr remove NUL: só aparece quando a chave está errada e o resultado é lixo.
    out=$(tail -c +"$((hlen + 1))" "$file" | _mc_cipher d "$kdf" "$iter" "$pass" | tr -d '\000') || return 1
    [ "${out%%$'\n'*}" = "$MC_MAGIC" ] || return 1
    printf '%s\n' "$out"
}

# Tipo de criptografia que a wallet deve usar nesta máquina.
_mc_wallet_kdf() {
    if _mc_has_pbkdf2; then echo pbkdf2; else echo legacy; fi
}

_mc_schema_field() { # <CHAVE> <n: 2=tipo 3=padrão 4=descrição>
    local e k t d s
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        if [ "$k" = "$1" ]; then
            case "$2" in 2) printf '%s' "$t" ;; 3) printf '%s' "$d" ;; 4) printf '%s' "$s" ;; esac
            return 0
        fi
    done
    return 1
}

_mc_known_key() { _mc_schema_field "$1" 2 >/dev/null; }
_mc_is_secret() { [[ "$MC_SECRET_KEYS" == *" $1 "* ]]; }

# Define todas as variáveis do schema com o valor padrão.
_mc_defaults() {
    local e k t d s
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        printf -v "$k" '%s' "$d"
    done
}

# _mc_parse <texto> : atribui CHAVE=valor (literal, sem expansão). Nunca usa source/eval.
# Retorna 1 (com mensagens em stderr) se houver linha inválida ou chave desconhecida.
_mc_parse() {
    local line key val n=0 rc=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! "$line" =~ ^[A-Z][A-Z0-9_]*= ]]; then
            echo "linha $n: formato inválido (use CHAVE=valor)" >&2
            rc=1; continue
        fi
        key="${line%%=*}"
        if ! _mc_known_key "$key"; then
            echo "linha $n: chave desconhecida: $key" >&2
            rc=1; continue
        fi
        val="${line#*=}"
        if [ "$(_mc_schema_field "$key" 2)" = multi ]; then   # linhas repetidas se acumulam
            [ -n "$val" ] || continue
            if [ -n "${!key}" ]; then printf -v "$key" '%s\n%s' "${!key}" "$val"
            else printf -v "$key" '%s' "$val"; fi
            continue
        fi
        printf -v "$key" '%s' "$val"
    done <<< "$1"
    return $rc
}

# Valida os valores já carregados nas variáveis. Mensagens em stderr; retorna 1 se inválido.
_mc_validate() {
    local e k t d s v l a b c x n rc=0
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        v="${!k}"
        case "$t" in
            req)   [ -n "$v" ] || { echo "$k: obrigatório" >&2; rc=1; } ;;
            int)   [[ "$v" =~ ^[0-9]+$ ]] || { echo "$k: precisa ser número inteiro (atual: '$v')" >&2; rc=1; } ;;
            lvl)   [[ "$v" =~ ^[0-9]$ ]] || { echo "$k: precisa ser de 0 a 9 (atual: '$v')" >&2; rc=1; } ;;
            yn)    [[ "$v" =~ ^[SN]$ ]] || { echo "$k: use S ou N (atual: '$v')" >&2; rc=1; } ;;
            fmt)   [[ "$v" =~ ^(sql|directory|custom)$ ]] || { echo "$k: use sql, directory ou custom (atual: '$v')" >&2; rc=1; } ;;
            path)  [ -z "$v" ] || [[ "$v" == /* ]] || { echo "$k: precisa ser caminho absoluto (atual: '$v')" >&2; rc=1; } ;;
            apath) [[ "$v" == /* ]] || { echo "$k: precisa ser caminho absoluto (atual: '$v')" >&2; rc=1; } ;;
            multi)
                n=0
                while IFS= read -r l; do
                    [ -n "$l" ] || continue
                    n=$((n + 1))
                    IFS='|' read -r a b c x <<< "$l"
                    if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ]; then
                        echo "$k (item $n): use base|schema|tabela|motivo|usuário|data (atual: '$l')" >&2; rc=1
                    fi
                done <<< "$v" ;;
        esac
    done
    if [ "$REMOTE_MODE" = S ]; then
        [ -n "$REMOTE_STRING" ] && [ "$REMOTE_STRING" != / ] || { echo "REMOTE_STRING: obrigatório com REMOTE_MODE=S (e não pode ser /)" >&2; rc=1; }
    fi
    if [ "$REMOTE_MODE" = S ] && [ "$REMOTE_EXTRA" = S ]; then
        [ -n "$REMOTE_STRING2" ] && [ "$REMOTE_STRING2" != / ] || { echo "REMOTE_STRING2: obrigatório com REMOTE_EXTRA=S (e não pode ser /)" >&2; rc=1; }
    fi
    if [ "$IS_S3" = S ]; then
        [ -n "$BUCKET_NAME" ] || { echo "BUCKET_NAME: obrigatório com IS_S3=S" >&2; rc=1; }
    fi
    if [ "$TITAN" = S ]; then
        [ -n "$T_IP" ] || { echo "T_IP: obrigatório com TITAN=S" >&2; rc=1; }
        [ -n "$T_HOST" ] || { echo "T_HOST: obrigatório com TITAN=S" >&2; rc=1; }
    fi
    [ "$DIR_BKP" != / ] || { echo "DIR_BKP: não pode ser /" >&2; rc=1; }
    return $rc
}

# _mc_txt_set <texto> <CHAVE> <valor> -> texto com a linha CHAVE= trocada (ou acrescentada)
_mc_txt_set() {
    local line found=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == "$2="* ]]; then
            printf '%s=%s\n' "$2" "$3"; found=1
        else
            printf '%s\n' "$line"
        fi
    done <<< "$1"
    if [ "$found" = 0 ]; then printf '%s=%s\n' "$2" "$3"; fi
}

# _mc_txt_get <texto> <CHAVE> -> valor (vazio se ausente)
_mc_txt_get() {
    local line v=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ "$line" == "$2="* ]]; then v="${line#*=}"; fi
    done <<< "$1"
    printf '%s' "$v"
}

# _mc_txt_merge <texto> -> acrescenta as chaves do schema que faltam (com o padrão)
_mc_txt_merge() {
    local e k t d s out="$1"
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        [ "$t" = multi ] && continue          # lista: ausente = vazia
        if ! grep -q "^${k}=" <<< "$out"; then
            out="${out}"$'\n\n'"# ${s}"$'\n'"${k}=${d}"
        fi
    done
    printf '%s\n' "$out"
}

# Gera o texto da wallet a partir das variáveis atuais (com comentários do schema).
_mc_render() {
    local e k t d s l
    printf '%s\n' "$MC_MAGIC"
    printf '# Gerado em %s. Formato: CHAVE=valor (valor literal, sem aspas).\n' "$(date '+%d/%m/%Y %T')"
    for e in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d s <<< "$e"
        if [ "$t" = multi ]; then
            printf '\n# %s\n# Exemplo: %s=vendas|public|log_auditoria|histórico sem uso no restore|vitor|12/11/2026\n' "$s" "$k"
            if [ -n "${!k}" ]; then
                while IFS= read -r l; do [ -n "$l" ] && printf '%s=%s\n' "$k" "$l"; done <<< "${!k}"
            fi
            continue
        fi
        printf '\n# %s\n%s=%s\n' "$s" "$k" "${!k}"
    done
}

# Lista de tabelas ignoradas: helpers de texto (EXCLUDE_TABLE=base|schema|tabela|motivo|usuário|data)
# _mc_et_has <texto> <base> <schema> <tabela> : 0 se a tabela já está na lista
_mc_et_has() {
    local line a b c x
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == EXCLUDE_TABLE=* ]] || continue
        IFS='|' read -r a b c x <<< "${line#EXCLUDE_TABLE=}"
        [ "$a" = "$2" ] && [ "$b" = "$3" ] && [ "$c" = "$4" ] && return 0
    done <<< "$1"
    return 1
}

# _mc_et_del <texto> <base> <schema> <tabela> -> texto sem a linha da tabela
_mc_et_del() {
    local line a b c x
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == EXCLUDE_TABLE=* ]]; then
            IFS='|' read -r a b c x <<< "${line#EXCLUDE_TABLE=}"
            [ "$a" = "$2" ] && [ "$b" = "$3" ] && [ "$c" = "$4" ] && continue
        fi
        printf '%s\n' "$line"
    done <<< "$1"
}
# <<< MIGRA-CRYPT v2 <<<

# ------------------------------------------------------------------------------
# Interface
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi
log()    { echo -e "  ${GREEN}✔${NC}  $*"; }
info()   { echo -e "  ${CYAN}•${NC}  $*"; }
warn()   { echo -e "  ${YELLOW}▲${NC}  $*"; }
err()    { echo -e "  ${RED}✖  $*${NC}" >&2; }
abort()  { err "$*"; exit 1; }

LINHA='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
header() {   # faixa de seção
    echo
    echo -e "  ${BLUE}${LINHA}${NC}"
    echo -e "   ${BOLD}$*${NC}"
    echo -e "  ${BLUE}${LINHA}${NC}"
}
dica_voltar() { echo -e "  ${DIM}Enter mantém o valor entre [ ]   ·   ← (seta para a esquerda) volta à pergunta anterior${NC}"; echo; }

como_responder() { # aviso mostrado logo no início
    echo
    echo -e "   ${BOLD}Como responder${NC}"
    echo -e "     ${CYAN}Enter${NC}   aceita o valor sugerido entre [ ]"
    echo -e "     ${CYAN}←${NC}       (seta para a esquerda, com o campo vazio) volta à pergunta anterior"
    echo -e "     ${CYAN}<${NC}       e Enter faz o mesmo, se a seta não funcionar no seu terminal"
    echo -e "     ${CYAN}Ctrl+C${NC}  cancela; nada é alterado até você confirmar o resumo no final"
}

banner() {   # só ASCII dentro da moldura, para as bordas alinharem em qualquer terminal
    echo
    echo -e "  ${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "  ${BLUE}║${NC}  ${BOLD}%-46s${NC}%14s${BLUE}║${NC}\n" "MigraTI  -  Backup PostgreSQL" "versao $VERSAO_INSTALADOR  "
    printf "  ${BLUE}║${NC}  %-60s${BLUE}║${NC}\n" "Instalador da rotina"
    echo -e "  ${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
}

# Largura visível de um texto UTF-8 (com LC_ALL=C, ${#s} conta bytes)
_vlen() { local s="$1" c; c="${s//[^$'\x80'-$'\xbf']/}"; echo $(( ${#s} - ${#c} )); }
linha_resumo() { # <rótulo> <valor> : coluna de valores alinhada
    local pad=$(( 24 - $(_vlen "$1") )); [ "$pad" -lt 1 ] && pad=1
    printf "   ${DIM}%s${NC}%*s%b\n" "$1" "$pad" "" "$2"
}

TTY=/dev/tty
STTY_ORIG=""
_restaura_tty() { [ -n "$STTY_ORIG" ] && stty "$STTY_ORIG" < "$TTY" 2>/dev/null; STTY_ORIG=""; }

# Lê uma linha do terminal, tecla por tecla, para reconhecer a seta ←.
#   ← com o campo vazio (ou "<" + Enter) = voltar (retorno 2). Backspace apaga; Ctrl+U limpa.
#   Sem terminal interativo (stty falha), cai no read comum.
_le_linha() { # <variável> <oculto 0|1>
    local _ll_b="" _ll_c _ll_r _ll_x _ll_u
    if ! STTY_ORIG=$(stty -g < "$TTY" 2>/dev/null) || ! stty -echo -icanon min 1 time 0 < "$TTY" 2>/dev/null; then
        STTY_ORIG=""
        if [ "$2" = 1 ]; then IFS= read -rs _ll_b < "$TTY"; printf '\n' > "$TTY"; else IFS= read -r _ll_b < "$TTY"; fi
        [ "$_ll_b" = "<" ] && return 2
        printf -v "$1" '%s' "$_ll_b"; return 0
    fi
    while IFS= read -r -n1 -d '' _ll_c < "$TTY"; do
        case "$_ll_c" in
            $'\n'|$'\r') break ;;
            $'\x7f'|$'\b')
                [ -n "$_ll_b" ] || continue
                while :; do   # tira um caractere UTF-8 inteiro
                    _ll_u="${_ll_b: -1}"; _ll_b="${_ll_b%?}"
                    [[ "$_ll_u" == [$'\x80'-$'\xbf'] ]] && [ -n "$_ll_b" ] || break
                done
                [ "$2" = 1 ] || printf '\b \b' > "$TTY" ;;
            $'\x15')
                [ "$2" = 1 ] || printf '\r\033[K%b' "$PROMPT_ATUAL" > "$TTY"
                _ll_b="" ;;
            $'\e')
                _ll_r=""; IFS= read -r -n2 -t 0.05 -d '' _ll_r < "$TTY"
                if [[ "$_ll_r" == "["[0-9] ]]; then   # sequências longas (Delete, Home...): descarta até o "~"
                    while IFS= read -r -n1 -t 0.05 -d '' _ll_x < "$TTY" && [ "$_ll_x" != "~" ]; do :; done
                fi
                if { [ "$_ll_r" = "[D" ] || [ "$_ll_r" = "OD" ]; } && [ -z "$_ll_b" ]; then
                    _restaura_tty; printf '\n' > "$TTY"; return 2
                fi ;;
            [[:cntrl:]]) ;;
            *) _ll_b+="$_ll_c"; [ "$2" = 1 ] || printf '%s' "$_ll_c" > "$TTY" ;;
        esac
    done
    _restaura_tty
    printf '\n' > "$TTY"
    [ "$_ll_b" = "<" ] && return 2
    printf -v "$1" '%s' "$_ll_b"
}

PROMPT_ATUAL=""
_prompt() { PROMPT_ATUAL="$1"; printf '%b' "$1" > "$TTY"; }

ask() {      # <variável> <pergunta> [padrão] ; retorna 2 para voltar (← ou "<")
    local __v=""
    if [ -n "${3:-}" ]; then
        _prompt "  ${CYAN}›${NC} $2 ${DIM}[${3}]${NC}: "
    else
        _prompt "  ${CYAN}›${NC} $2: "
    fi
    _le_linha __v 0 || return 2
    printf -v "$1" '%s' "${__v:-${3:-}}"
}

askyn() {    # <pergunta> <padrão S|N> ; retorna 0 para sim
    local __r="" __d="$2"
    while true; do
        _prompt "  ${CYAN}›${NC} $1 ${DIM}[$( [ "$__d" = S ] && echo 'S/n' || echo 's/N')]${NC}: "
        _le_linha __r 0 || { warn "Aqui não dá para voltar: responda S ou N."; continue; }
        __r="${__r:-$__d}"
        [[ "$__r" =~ ^[sSnN]$ ]] && break
        warn "Responda S ou N."
    done
    [[ "$__r" =~ ^[sS]$ ]]
}

askpass() {  # <variável> <pergunta> ; retorna 2 para voltar (← ou "<")
    local __v=""
    _prompt "  ${CYAN}›${NC} $2: "
    _le_linha __v 1 || return 2
    printf -v "$1" '%s' "$__v"
}

# Pergunta uma variável com validação pelo tipo (do schema ou informado). Usa o valor atual
# como padrão. Retorna 2 quando o usuário digita "<".
askkey() {   # <CHAVE> <pergunta> [tipo]
    local k="$1" q="$2" t="${3:-}" v
    [ -n "$t" ] || t=$(_mc_schema_field "$k" 2)
    while true; do
        ask v "$q" "${!k}" || return 2
        case "$t" in
            yn)    v="${v^^}"; [[ "$v" =~ ^[SN]$ ]] || { warn "Responda S ou N."; continue; } ;;
            int)   [[ "$v" =~ ^[0-9]+$ ]] || { warn "Informe um número inteiro."; continue; } ;;
            lvl)   [[ "$v" =~ ^[0-9]$ ]] || { warn "Informe um nível de 0 a 9."; continue; } ;;
            fmt)   v="${v,,}"; [[ "$v" =~ ^(sql|directory|custom)$ ]] || { warn "Use sql, directory ou custom."; continue; } ;;
            req)   [ -n "$v" ] || { warn "Valor obrigatório."; continue; } ;;
            apath) [[ "$v" == /* ]] || { warn "Informe um caminho absoluto."; continue; } ;;
            path)  [ -z "$v" ] || [[ "$v" == /* ]] || { warn "Informe um caminho absoluto."; continue; } ;;
            hora)  [[ "$v" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || { warn "Use HH:MM, de 00:00 a 23:59."; continue; }
                   v=$(printf '%02d:%02d' "$((10#${v%%:*}))" "$((10#${v##*:}))") ;;
        esac
        [[ "$v" != *$'\n'* ]] || continue
        printf -v "$k" '%s' "$v"
        return 0
    done
}

# ------------------------------------------------------------------------------
# Assistente de perguntas com "voltar"
#   Cada etapa: "condição|CHAVE|pergunta|tipo"
#     condição: vazia ou VAR=VALOR (várias com &) — etapa pulada se não valer
#     tipo:     vazio (schema) | yn | secret | mount | exclude | fmt
#   "<" volta para a última etapa respondida (as puladas não contam).
# ------------------------------------------------------------------------------
_cond() {
    local c="$1" p var val
    [ -z "$c" ] && return 0
    IFS='&' read -ra _cs <<< "$c"
    for p in "${_cs[@]}"; do
        var="${p%%=*}"; val="${p#*=}"
        [ "${!var}" = "$val" ] || return 1
    done
}

_etapa() { # <definição> ; 0 respondida | 2 voltar | 3 não se aplica
    local cond k q t
    IFS='|' read -r cond k q t <<< "$1"
    _cond "$cond" || return 3
    case "$t" in
        secret)
            local __s
            if [ -n "${!k}" ]; then askpass __s "$q (Enter mantém a atual)" || return 2
            else askpass __s "$q" || return 2; fi
            [ -n "$__s" ] && printf -v "$k" '%s' "$__s"
            return 0 ;;
        mount)   _pergunta_montagem "$k" "$q"; return $? ;;
        exclude) _pergunta_exclusoes; return $? ;;
        fmt)
            info "sql = texto compactado  ·  directory = paralelo (-Fd)  ·  custom = restore seletivo (-Fc)"
            askkey "$k" "$q"; return $? ;;
        yn)      askkey "$k" "$q" yn; return $? ;;
        hora)    askkey "$k" "$q" hora; return $? ;;
        *)       askkey "$k" "$q"; return $? ;;
    esac
}

_assistente() { # <etapas...> ; retorna 2 quando o usuário volta da primeira pergunta
    local -a et=("$@") hist=()
    local i=0 rc n j c
    if [ "${ASSIST_DO_FIM:-0}" = 1 ]; then   # voltando da etapa seguinte: começa pela última pergunta
        for j in "${!et[@]}"; do
            IFS='|' read -r c _ <<< "${et[$j]}"
            _cond "$c" && hist+=("$j")
        done
        n=${#hist[@]}
        if [ "$n" -gt 0 ]; then i="${hist[$((n - 1))]}"; unset "hist[$((n - 1))]"; hist=("${hist[@]}"); fi
    fi
    while [ "$i" -lt "${#et[@]}" ]; do
        _etapa "${et[$i]}"; rc=$?
        case $rc in
            0) hist+=("$i"); i=$((i + 1)) ;;
            3) i=$((i + 1)) ;;
            2) n=${#hist[@]}
               if [ "$n" -gt 0 ]; then
                   i="${hist[$((n - 1))]}"; unset "hist[$((n - 1))]"; hist=("${hist[@]}")
                   echo -e "  ${DIM}↑ voltando${NC}"
               else
                   return 2
               fi ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Temporários (sempre em RAM quando possível) e limpeza
# ------------------------------------------------------------------------------
WORK=""
TMPS=()
cleanup() {
    local t
    _restaura_tty
    for t in "${TMPS[@]}"; do rm -f -- "$t"; done
    [ -n "$WORK" ] && rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'echo; err "Instalação interrompida."; exit 130' INT TERM

_tmp() { # <variável> : cria temporário em RAM, registra para limpeza (sem subshell)
    local __t; __t=$(_mc_tmp) || abort "Falha ao criar temporário"; TMPS+=("$__t"); printf -v "$1" "%s" "$__t"
}

# ------------------------------------------------------------------------------
# Argumentos e verificações iniciais
# ------------------------------------------------------------------------------
PACOTE=""; UNINSTALL=0
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --package)   PACOTE="${2:-}"; [ -n "$PACOTE" ] || abort "--package exige um arquivo"; shift 2 ;;
            --branch)    GITHUB_BRANCH="${2:-}"; [ -n "$GITHUB_BRANCH" ] || abort "--branch exige um nome"; shift 2 ;;
            --uninstall) UNINSTALL=1; shift ;;
            -h|--help)   sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) abort "Argumento desconhecido: $1 (use --help)" ;;
        esac
    done
    if [ -n "$PACOTE" ]; then
        [ -f "$PACOTE" ] || abort "Pacote não encontrado: $PACOTE"
        PACOTE=$(readlink -f -- "$PACOTE")
    fi
}

OS_ID=""; OS_NOME=""; PM=""
check_basico() {
    [ "$(id -u)" -eq 0 ] || abort "Execute como root: sudo bash install.sh"
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || abort "É necessário bash 4 ou superior."
    { : < "$TTY"; } 2>/dev/null || abort "O instalador é interativo e precisa de um terminal."

    if [ -r /etc/os-release ]; then
        OS_ID=$(. /etc/os-release; echo "${ID:-}")
        OS_NOME=$(. /etc/os-release; echo "${PRETTY_NAME:-$ID}")
    fi
    if command -v apt-get >/dev/null 2>&1; then PM=apt-get
    elif command -v dnf >/dev/null 2>&1; then PM=dnf
    elif command -v yum >/dev/null 2>&1; then PM=yum
    elif command -v zypper >/dev/null 2>&1; then PM=zypper
    fi
    info "Sistema: ${OS_NOME:-desconhecido} · gerenciador de pacotes: ${PM:-nenhum}"

    local c falta=()
    for c in openssl tar gzip awk sed grep find flock sha256sum mktemp readlink stat; do
        command -v "$c" >/dev/null 2>&1 || falta+=("$c")
    done
    if [ -z "$PACOTE" ] && [ "$UNINSTALL" = 0 ]; then
        command -v curl >/dev/null 2>&1 || falta+=(curl)
    fi
    [ "${#falta[@]}" -eq 0 ] || abort "Comandos básicos ausentes: ${falta[*]}. Instale-os e execute novamente."

    MACHINE_KEY=$(_mc_machine_key) \
        || abort "/etc/machine-id ausente ou vazio. Gere um com 'systemd-machine-id-setup' e execute novamente."
    if _mc_has_pbkdf2; then
        info "OpenSSL $(openssl version | awk '{print $2}'): wallet com PBKDF2 ($MC_ITER iterações)"
    else
        warn "OpenSSL $(openssl version | awk '{print $2}') sem PBKDF2: wallet no formato compatível (legacy)"
    fi
}

_dir_seguro() { # rejeita diretórios do sistema e caracteres problemáticos
    local d="${1%/}"
    [[ "$d" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    case "$d" in
        /|/etc|/usr|/usr/*bin|/var|/var/log|/bin|/sbin|/lib|/lib64|/root|/home|/opt|/tmp|/boot|/dev|/proc|/sys|/run) return 1 ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
# Detecção do modo
# ------------------------------------------------------------------------------
MODO=""; DIR=""; CONF_1X=""
declare -A V1=()

_le_conf_1x() { # lê o conf da 1.x sem executá-lo
    local line k v ref i
    V1=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ "$line" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        k="${BASH_REMATCH[2]}"; v="${BASH_REMATCH[3]}"
        if [[ "$v" =~ ^\"([^\"]*)\" ]]; then v="${BASH_REMATCH[1]}"
        elif [[ "$v" =~ ^\'([^\']*)\' ]]; then v="${BASH_REMATCH[1]}"
        else v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"
        fi
        for i in 1 2 3 4 5; do
            [[ "$v" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]] || break
            ref="${BASH_REMATCH[1]}"
            v="${v/"${BASH_REMATCH[0]}"/${V1[$ref]:-}}"
        done
        V1["$k"]="$v"
    done < "$1"
}

_dir_da_1x() { # <conf resolvido> -> diretório base da 1.x
    local d="${V1[DIR]:-}"
    if [ -z "$d" ]; then
        d=$(dirname -- "$1")
        [ "$(basename -- "$d")" = bin ] && d=$(dirname -- "$d")
    fi
    printf '%s' "${d%/}"
}

detecta_modo() { # [passo] : 4 = volta direto à pergunta do diretório (instalação nova)
    local dir2="" alvo resp passo="${1:-1}"
    if [ "$passo" = 4 ]; then _pergunta_dir_nova; return $?; fi
    header "Instalação existente"
    if [ -L "$LINK_TOOL" ]; then
        alvo=$(readlink -f -- "$LINK_TOOL")
        dir2=$(dirname -- "$(dirname -- "$alvo")")
    elif [ -f "$DIR_PADRAO/wallet/migra.wallet" ]; then
        dir2="$DIR_PADRAO"
    fi
    if [ -n "$dir2" ] && [ -f "$dir2/wallet/migra.wallet" ]; then
        info "Rotina 2.x encontrada em ${BOLD}$dir2${NC}"
        if askyn "Atualizar esta instalação (a configuração é mantida)?" S; then
            MODO=atualizacao; DIR="$dir2"; return
        fi
        abort "Instalação cancelada. Para reinstalar do zero, use --uninstall antes."
    fi

    if [ -e "$CONF_1X_LINK" ]; then
        CONF_1X=$(readlink -f -- "$CONF_1X_LINK")
        info "Rotina 1.x encontrada: $CONF_1X_LINK -> $CONF_1X"
    else
        while true; do
            askyn "Existe uma instalação 1.x desta rotina neste servidor?" N || break
            while true; do
                ask resp "Caminho do arquivo de configuração da 1.x (ex.: /etc/zabbix/migrabkp/bin/migra_postgres.conf)" || continue 2
                [ -f "$resp" ] && break
                warn "Arquivo não encontrado: $resp"
            done
            CONF_1X=$(readlink -f -- "$resp")
            break
        done
    fi

    if [ -n "$CONF_1X" ]; then
        [ -f "$CONF_1X" ] || abort "Configuração da 1.x não encontrada: $CONF_1X"
        _le_conf_1x "$CONF_1X"
        DIR=$(_dir_da_1x "$CONF_1X")
        _dir_seguro "$DIR" || abort "Diretório da 1.x inválido ou de sistema: '$DIR'"
        [ -d "$DIR" ] || abort "Diretório da 1.x não existe: $DIR"
        info "Diretório da rotina 1.x: ${BOLD}$DIR${NC} (versão ${V1[VERSION]:-?})"
        info "A $VERSAO_INSTALADOR será instalada neste mesmo diretório. Dumps e logs atuais são mantidos."
        askyn "Migrar esta instalação para a $VERSAO_INSTALADOR?" S || abort "Instalação cancelada."
        MODO=migracao
        return
    fi

    MODO=nova
    _pergunta_dir_nova || detecta_modo
}

_pergunta_dir_nova() { # 2 = voltar
    local d
    while true; do
        ask d "Diretório da rotina" "${DIR:-$DIR_PADRAO}" || return 2
        d="${d%/}"
        if ! _dir_seguro "$d"; then
            warn "Diretório inválido ou de sistema. Use algo como $DIR_PADRAO."
        elif [ -e "$d/bin/bkp_postgres" ] || [ -e "$d/wallet" ]; then
            warn "$d já contém arquivos da rotina. Escolha outro diretório (ou use --uninstall antes)."
        else
            DIR="$d"; return 0
        fi
    done
}

# ------------------------------------------------------------------------------
# Pacote: download/validação/decifragem (nada é alterado no servidor aqui)
# ------------------------------------------------------------------------------
declare -A PLAIN=() SUMS=()
PKG_VERSAO="?"

# Primeiro passo do instalador: sem a chave do dia válida, encerra antes de qualquer pergunta.
obter_pacote() {
    local dist pkg code url name enc plain entrada
    until askpass dist "Chave do dia"; do :; done   # primeira pergunta: não há para onde voltar
    [ -n "$dist" ] || abort "Chave não informada. Instalação encerrada."

    WORK=$(mktemp -d) || abort "Falha ao criar diretório temporário"
    pkg="$WORK/migrabkp.tar.gz"
    if [ -n "$PACOTE" ]; then
        cp -- "$PACOTE" "$pkg" || abort "Falha ao ler $PACOTE"
    else
        # API do GitHub (e não raw.githubusercontent): sem cache, sempre o pacote do dia
        url="https://api.github.com/repos/$GITHUB_ORG/$GITHUB_REPO/contents/migrabkp.tar.gz?ref=$GITHUB_BRANCH"
        code=$(curl -sSL -H 'Accept: application/vnd.github.v3.raw' -o "$pkg" -w '%{http_code}' "$url" 2>/dev/null) || true
        case "$code" in
            200) ;;
            403|429) abort "O GitHub limitou os downloads deste IP (HTTP $code). Tente de novo em alguns minutos." ;;
            *) abort "Falha ao baixar o pacote (HTTP ${code:-sem resposta}). Verifique o acesso a api.github.com." ;;
        esac
    fi

    tar -tzf "$pkg" > "$WORK/lista" 2>/dev/null || abort "O pacote não é um tar.gz válido."
    while IFS= read -r entrada; do
        [[ "$entrada" =~ ^migrabkp/([A-Za-z0-9._-]+/?)*$ ]] && [[ "$entrada" != *..* ]] \
            || abort "Pacote com entrada inesperada: $entrada"
    done < "$WORK/lista"
    mkdir -p "$WORK/pkg"
    tar -xzf "$pkg" -C "$WORK/pkg" --no-same-owner --no-same-permissions || abort "Falha ao extrair o pacote."
    [ -f "$WORK/pkg/migrabkp/VERSION" ] && PKG_VERSAO=$(head -n1 "$WORK/pkg/migrabkp/VERSION")

    for name in "${SCRIPTS[@]}"; do
        enc="$WORK/pkg/migrabkp/bin/$name.enc"
        [ -f "$enc" ] || abort "Pacote incompleto: falta bin/$name.enc"
        _tmp plain
        if ! _mc_cipher d legacy 0 "$dist" "$enc" "$plain" \
           || [ "$(head -n1 "$plain")" != "#!/bin/bash" ] \
           || ! grep -qxF '# >>> MIGRA-CRYPT v2 >>>' "$plain"; then
            unset dist
            abort "Chave do dia inválida. Instalação encerrada."
        fi
        PLAIN["$name"]="$plain"
        SUMS["$name"]=$(openssl dgst -sha256 < "$plain" | awk '{print $NF}')
    done
    unset dist
    rm -f -- "$pkg"
    log "Chave válida. Rotina versão $PKG_VERSAO."
}

# ------------------------------------------------------------------------------
# PostgreSQL: binários, conexão e versão
# ------------------------------------------------------------------------------
_versao_bin() { # <dir> -> número major (90600, 160000) ou vazio
    local out
    out=$("$1/pg_dump" --version 2>/dev/null) || return 1
    [[ "$out" =~ \)\ ([0-9]+)(\.([0-9]+))? ]] || return 1
    local maj="${BASH_REMATCH[1]}" min="${BASH_REMATCH[3]:-0}"
    if [ "$maj" -ge 10 ]; then echo $((maj * 10000)); else echo $((maj * 10000 + min * 100)); fi
}

_versao_txt() { local n="$1"; if [ "$n" -ge 100000 ]; then echo $((n / 10000)); else echo "$((n / 10000)).$(( (n / 100) % 100 ))"; fi; }

declare -A CAND=()
_candidatos_pg() {
    local d v
    local -a dirs=()
    command -v pg_dump >/dev/null 2>&1 && dirs+=("$(dirname -- "$(readlink -f -- "$(command -v pg_dump)")")")
    for d in /usr/pgsql-*/bin /usr/lib/postgresql/*/bin /usr/local/pgsql*/bin /opt/PostgreSQL/*/bin /usr/bin; do
        [ -d "$d" ] && dirs+=("$d")
    done
    CAND=()
    for d in "${dirs[@]}"; do
        [ -x "$d/pg_dump" ] && [ -x "$d/psql" ] || continue
        v=$(_versao_bin "$d") || continue
        CAND["$d"]="$v"
    done
}

_pgpass_tmp() { # <variável> <usuario> <senha> : .pgpass temporário em RAM (limpo na saída)
    local __f __u __p
    _tmp __f
    __u=${2//\\/\\\\}; __u=${__u//:/\\:}
    __p=${3//\\/\\\\}; __p=${__p//:/\\:}
    printf '*:*:*:%s:%s\n' "$__u" "$__p" > "$__f"
    printf -v "$1" '%s' "$__f"
}

# psql com a credencial informada, sem expor a senha no ambiente/argumentos
_psql() {
    env -u PGPASSWORD PGPASSFILE="$PGPASSFILE_INST" "$PSQL_INST" -X -qAt -w \
        -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "$@"
}

SERVER_NUM=""; PSQL_INST=""; PGPASSFILE_INST=""
configura_conexao() {
    header "Conexão com o PostgreSQL"
    _candidatos_pg
    if [ "${#CAND[@]}" -eq 0 ]; then
        err "Nenhum cliente PostgreSQL (pg_dump + psql) encontrado."
        case "$PM" in
            apt-get) info "Instale o cliente da mesma versão do servidor, ex.: apt-get install postgresql-client-16 (repositório PGDG)" ;;
            dnf|yum) info "Instale o cliente da mesma versão do servidor, ex.: $PM install postgresql16 (repositório PGDG)" ;;
        esac
        abort "O instalador não instala pacotes do PostgreSQL. Instale o cliente e execute novamente."
    fi
    local d melhor="" mv=0
    for d in "${!CAND[@]}"; do
        if [ "${CAND[$d]}" -gt "$mv" ]; then mv="${CAND[$d]}"; melhor="$d"; fi
    done
    PSQL_INST="$melhor/psql"

    local out errf fase=1 do_fim=0
    _tmp errf
    dica_voltar
    # Voltando da etapa seguinte: reabre direto na última pergunta (diretório do pg_dump)
    [ "${CONEXAO_DO_FIM:-0}" = 1 ] && [ -n "$SERVER_NUM" ] && fase=2
    while true; do
        if [ "$fase" = 1 ]; then
            ASSIST_DO_FIM=$do_fim _assistente \
                "|PGHOST|Host do PostgreSQL|" \
                "|PGPORT|Porta|" \
                "|PGUSER|Usuário do backup|" \
                "|PGDATABASE|Banco para conexão|" \
                "|PGPASSWORD|Senha do usuário do banco|secret" || return 2
            do_fim=0
            [ -n "$PGPASSFILE_INST" ] && rm -f -- "$PGPASSFILE_INST"
            _pgpass_tmp PGPASSFILE_INST "$PGUSER" "$PGPASSWORD"
            # stderr separado: avisos do psql não podem se misturar ao número da versão
            if out=$(_psql -c 'SHOW server_version_num' 2> "$errf") && [[ "$out" =~ ^[0-9]+$ ]]; then
                SERVER_NUM="$out"
                log "Conexão OK — servidor PostgreSQL $(_versao_txt "$(( SERVER_NUM >= 100000 ? SERVER_NUM / 10000 * 10000 : SERVER_NUM / 100 * 100 ))") ($SERVER_NUM)"
            else
                err "Falha na conexão: $(head -n 1 "$errf")${out:+ $out}"
                if ! askyn "Corrigir os dados e tentar de novo?" S; then
                    [ "${CONEXAO_OPCIONAL:-0}" = 1 ] && return 1
                    abort "Instalação cancelada."
                fi
                PGPASSWORD=""
                continue
            fi
            fase=2
        fi

        local smaj escolhido="" ev=999999999
        if [ "$SERVER_NUM" -ge 100000 ]; then smaj=$(( SERVER_NUM / 10000 * 10000 )); else smaj=$(( SERVER_NUM / 100 * 100 )); fi
        echo
        info "Clientes PostgreSQL encontrados:"
        for d in "${!CAND[@]}"; do
            printf "       ${DIM}%-34s${NC} pg_dump %s\n" "$d" "$(_versao_txt "${CAND[$d]}")"
            if [ "${CAND[$d]}" -ge "$smaj" ] && [ "${CAND[$d]}" -lt "$ev" ]; then ev="${CAND[$d]}"; escolhido="$d"
            elif [ "${CAND[$d]}" -eq "$ev" ] && [ "$escolhido" = /usr/bin ]; then escolhido="$d"   # prefere o diretório da versão
            fi
        done
        if [ -z "$escolhido" ]; then
            abort "Nenhum pg_dump é da versão do servidor ($(_versao_txt "$smaj")) ou mais nova. Instale o cliente $(_versao_txt "$smaj") e execute novamente."
        fi
        # mantém a escolha anterior se ainda for válida
        if [ "${PG_BIN_ESCOLHIDO:-0}" != 1 ] || [ -z "${CAND[${PG_BIN%/}]:-}" ] || [ "${CAND[${PG_BIN%/}]}" -lt "$smaj" ]; then
            PG_BIN="$escolhido"
        fi
        while true; do
            if ! askkey PG_BIN "Diretório do pg_dump a usar"; then
                fase=1; do_fim=1; echo -e "  ${DIM}↑ voltando${NC}"; continue 2
            fi
            PG_BIN="${PG_BIN%/}"
            if [ -n "${CAND[$PG_BIN]:-}" ] && [ "${CAND[$PG_BIN]}" -ge "$smaj" ]; then PG_BIN_ESCOLHIDO=1; break 2; fi
            warn "Escolha um diretório da lista com pg_dump $(_versao_txt "$smaj") ou mais novo."
        done
    done
    PSQL_INST="$PG_BIN/psql"

    local sup
    sup=$(_psql -c "SELECT rolsuper FROM pg_roles WHERE rolname = current_user" 2>/dev/null)
    if [ "$sup" != t ]; then
        warn "$PGUSER não é superuser. O backup exige leitura em todas as bases (superuser ou pg_read_all_data no PG 14+)."
    fi
}

# ------------------------------------------------------------------------------
# Configuração da rotina
# ------------------------------------------------------------------------------
importa_1x() { # mapeia o conf 1.x para as chaves da 2.0
    local v
    [ -n "${V1[PGHOST]:-}" ] && PGHOST="${V1[PGHOST]}"
    [ -n "${V1[PGPORT]:-}" ] && PGPORT="${V1[PGPORT]}"
    [ -n "${SCRIPT1X_USER:-}" ] && PGUSER="$SCRIPT1X_USER"
    [ -n "${V1[DIR_BKP]:-}" ] && DIR_BKP="${V1[DIR_BKP]}"
    [ -n "${V1[ARQ_LOG_GERAL]:-}" ] && LOG_GERAL="${V1[ARQ_LOG_GERAL]}"
    if [ "${V1[BKP_DIRETORIO]:-}" = S ]; then
        BKP_FORMATO=directory
        [ -n "${V1[QTDCOMPACT]:-}" ] && NIVEL_COMPACTACAO="${V1[QTDCOMPACT]}"
    elif [ "${V1[BKP_DIRETORIO]:-}" = N ]; then
        BKP_FORMATO=sql
        [ "${V1[USE_PIGZ]:-}" = S ] && [ -n "${V1[PIGZ_LEVEL]:-}" ] && NIVEL_COMPACTACAO="${V1[PIGZ_LEVEL]}"
    fi
    for v in QTDCORES USE_PIGZ PIGZ_THREADS RETENCAO_BKP RETENCAO_ARQ_LOG REMOTE_MODE REMOTE_STRING \
             PATH_REMOTO RETENCAO_BKP_REMOTO REMOTE_EXTRA REMOTE_STRING2 PATH_REMOTO2 RETENCAO_BKP_REMOTO2 \
             IS_S3 BUCKET_NAME FOLDER_S3 RETENCAO_BKP_S3 TITAN PATH_TITAN SENDER T_CONF T_IP; do
        [ -n "${V1[$v]+x}" ] && printf -v "$v" '%s' "${V1[$v]}"
    done
    [ -n "${V1[T_Host]:-}" ] && T_HOST="${V1[T_Host]}"
    PATH_TITAN="${PATH_TITAN%/}"; PATH_TITAN="${PATH_TITAN:-/usr/bin}"
    _preenche_padroes
}

# Valores vindos da 1.x podem estar vazios ou fora do formato da 2.x (ex.: PIGZ_THREADS='').
# Nesses casos vale o padrão da 2.x, com aviso quando havia algum valor.
_preenche_padroes() {
    local l k t d v
    for l in "${MC_SCHEMA[@]}"; do
        IFS='|' read -r k t d _ <<< "$l"
        v="${!k}"
        case "$t" in
            int)       [[ "$v" =~ ^[0-9]+$ ]] && continue ;;
            lvl)       [[ "$v" =~ ^[0-9]$ ]] && continue ;;
            yn)        v="${v^^}"; if [[ "$v" =~ ^[SN]$ ]]; then printf -v "$k" '%s' "$v"; continue; fi ;;
            fmt)       [[ "$v" =~ ^(sql|directory|custom)$ ]] && continue ;;
            req)       [ -n "$v" ] && continue ;;
            apath)     [[ "$v" == /* ]] && continue ;;
            *)         continue ;;
        esac
        [ -n "$v" ] && warn "Valor da 1.x fora do formato em $k ('$v'); usando o padrão: $d"
        printf -v "$k" '%s' "$d"
    done
}

# Confere a configuração ANTES do resumo/aplicação (a mesma validação de quando a wallet é gravada).
_config_valida() {
    local out
    if out=$( { _mc_parse "$(_mc_render)" && _mc_validate; } 2>&1 ); then return 0; fi
    err "A configuração tem valores inválidos:"
    sed 's/^/       /' <<< "$out"
    return 1
}

SERVER_BASES=""; SERVER_MODELOS=""
_bases_servidor() { # SERVER_BASES: as que podem entrar no backup; SERVER_MODELOS: template0/1 e afins
    [ -n "$SERVER_BASES$SERVER_MODELOS" ] && return 0
    SERVER_BASES=$(_psql -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1" 2>/dev/null)
    SERVER_MODELOS=$(_psql -c "SELECT datname FROM pg_database WHERE NOT datallowconn OR datistemplate ORDER BY 1" 2>/dev/null)
}

_em_lista() { # <nome> <lista separada por vírgula>
    local x
    IFS=',' read -ra _l <<< "$2"
    for x in "${_l[@]}"; do x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"; [ "$x" = "$1" ] && return 0; done
    return 1
}

# Mostra as bases do servidor, pergunta as ignoradas e lista o resultado na vertical.
_pergunta_exclusoes() {
    local b x n_bkp=0
    _bases_servidor
    if [ -n "$SERVER_BASES" ]; then
        echo
        echo -e "   ${BOLD}Bases no servidor${NC}"
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            if _em_lista "$b" "$EXCLUDE_BASES"; then echo -e "     ${DIM}✖  $b   (ignorada)${NC}"
            else echo -e "     ${GREEN}✔${NC}  $b"; fi
        done <<< "$SERVER_BASES"
        while IFS= read -r b; do
            [ -n "$b" ] && echo -e "     ${DIM}✖  $b   (modelo do PostgreSQL: nunca entra no backup)${NC}"
        done <<< "$SERVER_MODELOS"
        echo
    fi
    askkey EXCLUDE_BASES "Bases a ignorar (separadas por vírgula)" || return 2

    echo
    echo -e "   ${BOLD}Ficam fora do backup${NC}"
    IFS=',' read -ra _l <<< "$EXCLUDE_BASES"
    for x in "${_l[@]}"; do
        x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
        [ -n "$x" ] || continue
        if grep -qxF -- "$x" <<< "$SERVER_MODELOS"; then
            echo -e "     ${DIM}✖  $x   (modelo do PostgreSQL)${NC}"
        elif [ -n "$SERVER_BASES" ] && ! grep -qxF -- "$x" <<< "$SERVER_BASES"; then
            echo -e "     ${DIM}✖  $x   (não existe neste servidor)${NC}"
        else
            echo -e "     ${YELLOW}✖${NC}  $x"
        fi
    done
    if [ -n "$SERVER_BASES" ]; then
        echo -e "   ${BOLD}Entram no backup${NC}"
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            _em_lista "$b" "$EXCLUDE_BASES" && continue
            echo -e "     ${GREEN}✔${NC}  $b"; n_bkp=$((n_bkp + 1))
        done <<< "$SERVER_BASES"
        [ "$n_bkp" -gt 0 ] || warn "Nenhuma base entra no backup com esta lista."
    fi
    echo
    return 0
}

AWS_NA_WALLET=N
coleta_config() {
    header "Configuração do backup"
    if [ "$MODO" = migracao ] && [ -z "${REVISAO:-}" ] && ! askyn "Revisar as configurações importadas da 1.x?" S; then
        return 0
    fi
    dica_voltar
    [ -n "$AWS_ACCESS_KEY_ID" ] && AWS_NA_WALLET=S
    [ -n "$T_HOST" ] || T_HOST=$(hostname -s 2>/dev/null)
    _assistente \
        "|DIR_BKP|Diretório local dos backups|" \
        "|BKP_FORMATO|Formato do backup|fmt" \
        "BKP_FORMATO=directory|QTDCORES|Jobs paralelos do pg_dump|" \
        "|NIVEL_COMPACTACAO|Nível de compactação (0-9)|" \
        "BKP_FORMATO=sql|USE_PIGZ|Compactar com pigz (paralelo)? (S/N)|" \
        "BKP_FORMATO=sql&USE_PIGZ=S|PIGZ_THREADS|Threads do pigz|" \
        "|BKP_GLOBALS|Salvar roles e tablespaces (globals)? (S/N)|" \
        "|BKP_CONFIG|Copiar postgresql.conf, pg_hba.conf e pg_ident.conf a cada backup? (S/N)|" \
        "|EXCLUDE_BASES||exclude" \
        "|RETENCAO_BKP|Retenção local (dias)|" \
        "|RETENCAO_ARQ_LOG|Retenção dos logs (dias)|" \
        "|REMOTE_MODE|Copiar para storage montado (NFS/CIFS)? (S/N)|" \
        "REMOTE_MODE=S|REMOTE_STRING|Ponto de montagem|mount" \
        "REMOTE_MODE=S|PATH_REMOTO|Subpasta dentro da montagem (vazio = raiz)|" \
        "REMOTE_MODE=S|RETENCAO_BKP_REMOTO|Retenção no storage (dias)|" \
        "REMOTE_MODE=S|REMOTE_EXTRA|Copiar também para um segundo storage? (S/N)|" \
        "REMOTE_MODE=S&REMOTE_EXTRA=S|REMOTE_STRING2|Ponto de montagem do segundo storage|mount" \
        "REMOTE_MODE=S&REMOTE_EXTRA=S|PATH_REMOTO2|Subpasta no segundo storage|" \
        "REMOTE_MODE=S&REMOTE_EXTRA=S|RETENCAO_BKP_REMOTO2|Retenção no segundo storage (dias)|" \
        "|IS_S3|Enviar para bucket S3? (S/N)|" \
        "IS_S3=S|BUCKET_NAME|Nome do bucket|" \
        "IS_S3=S|FOLDER_S3|Pasta dentro do bucket (vazio = raiz)|" \
        "IS_S3=S|RETENCAO_BKP_S3|Retenção no S3 (dias)|" \
        "IS_S3=S|AWS_PROFILE|Perfil do aws cli (vazio = padrão ou IAM role)|" \
        "IS_S3=S|AWS_DEFAULT_REGION|Região (vazio = a do perfil)|" \
        "IS_S3=S|AWS_NA_WALLET|Guardar access key e secret na wallet? (S/N)|yn" \
        "IS_S3=S&AWS_NA_WALLET=S|AWS_ACCESS_KEY_ID|AWS access key id|" \
        "IS_S3=S&AWS_NA_WALLET=S|AWS_SECRET_ACCESS_KEY|AWS secret access key|secret" \
        "|TITAN|Enviar status ao Zabbix/Titan? (S/N)|" \
        "TITAN=S|PATH_TITAN|Diretório do zabbix_sender|" \
        "TITAN=S|SENDER|Executável do sender|" \
        "TITAN=S|T_CONF|Configuração do agente Zabbix|" \
        "TITAN=S|T_IP|Servidor Zabbix/Titan (IP ou nome)|" \
        "TITAN=S|T_HOST|Hostname no Zabbix|" \
        "CRON_PERGUNTAR=S|CRON_HM|Horário do backup diário (HH:MM)|hora" || return 2
    # Coerência entre respostas
    [ "$BKP_FORMATO" = sql ] || USE_PIGZ=N
    [ "$REMOTE_MODE" = S ] || REMOTE_EXTRA=N
    if [ "$AWS_NA_WALLET" != S ]; then AWS_ACCESS_KEY_ID=""; AWS_SECRET_ACCESS_KEY=""; fi
    return 0
}

_pergunta_montagem() { # <CHAVE> <pergunta> ; 2 = voltar
    local k="$1" mp
    while true; do
        askkey "$k" "$2" || return 2
        mp="${!k%/}"
        if [ -z "$mp" ] || [ "$mp" = / ]; then warn "Informe um ponto de montagem válido."; continue; fi
        printf -v "$k" '%s' "$mp"
        if command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "$mp"; then
            log "$mp está montado."
        elif awk -v mp="$mp" '$1 !~ /^#/ && $2 == mp {f = 1} END {exit !f}' /etc/fstab 2>/dev/null; then
            info "$mp não está montado agora, mas está no /etc/fstab: a rotina monta e desmonta a cada execução."
        else
            warn "$mp não está montado nem no /etc/fstab. A cópia vai falhar até o storage ser configurado."
            askyn "Manter mesmo assim?" N || continue
        fi
        return 0
    done
}

# ------------------------------------------------------------------------------
# Dependências opcionais (pergunta antes de instalar; nunca mexe no PostgreSQL)
# ------------------------------------------------------------------------------
_pkg_disponivel() {
    case "$PM" in
        apt-get) apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [0-9a-z]' ;;
        dnf|yum) "$PM" -q list available "$1" >/dev/null 2>&1 || "$PM" -q list installed "$1" >/dev/null 2>&1 ;;
        zypper)  zypper -q info "$1" 2>/dev/null | grep -q '^Name' ;;
        *) return 1 ;;
    esac
}

_oferece_pacote() { # <comando> <pacotes candidatos...> ; 0 se o comando ficou disponível
    local cmd="$1" p pkg="" linha; shift
    command -v "$cmd" >/dev/null 2>&1 && return 0
    for p in "$@"; do if _pkg_disponivel "$p"; then pkg="$p"; break; fi; done
    if [ -z "$pkg" ]; then
        warn "'$cmd' não está instalado e nenhum pacote ($*) foi encontrado nos repositórios configurados."
        return 1
    fi
    case "$PM" in
        apt-get) linha="apt-get update && apt-get install -y $pkg" ;;
        zypper)  linha="zypper -n install $pkg" ;;
        *)       linha="$PM install -y $pkg" ;;
    esac
    warn "'$cmd' não está instalado. Comando sugerido: $linha"
    askyn "Instalar agora?" N || return 1
    case "$PM" in
        apt-get) apt-get update && apt-get install -y "$pkg" ;;
        zypper)  zypper -n install "$pkg" ;;
        *)       "$PM" install -y "$pkg" ;;
    esac
    command -v "$cmd" >/dev/null 2>&1
}

dependencias() {
    header "Dependências"
    if [ "$BKP_FORMATO" = sql ] && [ "$USE_PIGZ" = S ]; then
        if ! _oferece_pacote pigz pigz; then
            warn "Sem pigz: USE_PIGZ passa para N (compactação com gzip)."
            USE_PIGZ=N
        fi
    fi
    if [ "$IS_S3" = S ] && ! _oferece_pacote aws awscli awscli2 aws-cli; then
        warn "Sem aws cli o envio ao S3 vai falhar. Instale-o (https://aws.amazon.com/cli/) e rode: migra-wallet-pg -test"
    fi
    if [ "$REMOTE_MODE" = S ] && ! command -v mountpoint >/dev/null 2>&1; then
        warn "'mountpoint' (util-linux) não encontrado; a cópia remota vai falhar."
    fi
    if [ "$TITAN" = S ] && [ ! -x "${PATH_TITAN%/}/$SENDER" ] && ! command -v "$SENDER" >/dev/null 2>&1; then
        warn "$SENDER não encontrado em $PATH_TITAN; o status não chegará ao monitoramento."
    fi
    log "Dependências verificadas."
}

# ------------------------------------------------------------------------------
# Migração 1.x: localizar, guardar (sem senha) e limpar
# ------------------------------------------------------------------------------
SCRIPT1X=(); SCRIPT1X_USER=""; SCRIPT1X_PLAIN=""; CRON1X=()
MGMT1X=()           # management.sh da 1.4 (também tem a senha do banco em texto)

_script_1x_texto() { # <script> <destino> : versão legível (desfaz gzexe)
    if head -n 5 -- "$1" 2>/dev/null | grep -qa '^skip='; then
        local t="$WORK/gzexe.$$"
        cp -- "$1" "$t" || return 1
        if command -v gzexe >/dev/null 2>&1 && gzexe -d "$t" >/dev/null 2>&1; then
            rm -f -- "$t~"; mv -f -- "$t" "$2"; return 0
        fi
        rm -f -- "$t" "$t~"
        # sem gzexe: o conteúdo compactado começa na linha indicada por skip=
        local skip; skip=$(head -n 5 -- "$1" | sed -n 's/^skip=\([0-9][0-9]*\)$/\1/p')
        [ -n "$skip" ] && tail -n +"$skip" -- "$1" | gzip -cd > "$2" 2>/dev/null && [ -s "$2" ] && return 0
        return 1
    fi
    cp -- "$1" "$2"
}

# Scripts da 1.x no cron: bkp_postgres.sh e variações do cliente (bkp_postgres_alterado.sh...).
# A rotina Docker (bkp_postgres_docker.sh) é outro produto e fica de fora.
_RE_1X='bkp_postgres[A-Za-z0-9_-]*\.sh'
_e_1x() { grep -E -- "$_RE_1X" | grep -v 'bkp_postgres_docker'; }

localiza_1x() {
    local c f linha u
    for c in "$DIR/bin/management.sh" "$DIR/management.sh"; do    # só se for o da rotina
        [ -f "$c" ] && grep -qa 'migrabkp.exclude_' "$c" 2>/dev/null && MGMT1X+=("$c")
    done
    CRON1X=()
    for u in root postgres $(getent group migrabkp 2>/dev/null | cut -d: -f4 | tr ',' ' '); do
        while IFS= read -r linha; do
            [[ "$linha" =~ ^[[:space:]]*# ]] && continue
            CRON1X+=("crontab:$u|$linha")
        done < <(crontab -l -u "$u" 2>/dev/null | _e_1x)
    done
    for f in /etc/crontab /etc/cron.d/*; do
        [ -f "$f" ] || continue
        while IFS= read -r linha; do
            [[ "$linha" =~ ^[[:space:]]*# ]] && continue
            CRON1X+=("arquivo:$f|$linha")
        done < <(_e_1x < "$f" 2>/dev/null)
    done
    for linha in "${CRON1X[@]}"; do   # primeiro os scripts que o cron realmente chama
        c=$(grep -oE "/[^[:space:]]*$_RE_1X" <<< "${linha#*|}" | grep -v 'bkp_postgres_docker' | head -n1)
        if [ -n "$c" ] && [ -f "$c" ] && [[ ! " ${SCRIPT1X[*]} " == *" $c "* ]]; then SCRIPT1X+=("$c"); fi
    done
    for c in "$DIR/bin/bkp_postgres.sh" "$DIR/bkp_postgres.sh"; do
        if [ -f "$c" ] && [[ ! " ${SCRIPT1X[*]} " == *" $c "* ]]; then SCRIPT1X+=("$c"); fi
    done

    if [ "${#SCRIPT1X[@]}" -gt 0 ]; then
        _tmp SCRIPT1X_PLAIN
        if _script_1x_texto "${SCRIPT1X[0]}" "$SCRIPT1X_PLAIN"; then
            SCRIPT1X_USER=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?PGUSER="?([^"]*)"?[[:space:]]*$/\2/p' "$SCRIPT1X_PLAIN" | head -n1)
            [ "$SCRIPT1X_USER" = "__PGUSER__" ] && SCRIPT1X_USER=""
        else
            warn "Não foi possível abrir o script 1.x (gzexe). Ele não será copiado para o backup."
            SCRIPT1X_PLAIN=""
        fi
    fi
    info "Scripts 1.x: ${SCRIPT1X[*]:-nenhum encontrado}${MGMT1X[*]:+ · gerenciador: ${MGMT1X[*]}}"
    info "Agendamentos 1.x: ${#CRON1X[@]}"
}

_salva_sem_senha() { # <script em texto> <destino> : troca a senha por um marcador
    local conteudo senha
    senha=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?PGPASSWORD="?([^"]*)"?[[:space:]]*$/\2/p' "$1" | head -n1)
    conteudo=$(sed -E 's/^([[:space:]]*(export[[:space:]]+)?PGPASSWORD=).*/\1"__REMOVIDO_NA_MIGRACAO__"/' "$1")
    # Também troca outras ocorrências da senha, se ela for longa o bastante para não
    # coincidir com nomes do script (a 1.4 usava "migrabkp", igual ao nome do schema).
    if [ "${#senha}" -ge 8 ] && [ "$senha" != "__PGPASSWORD__" ] && [ "$senha" != migrabkp ]; then
        conteudo="${conteudo//"$senha"/__REMOVIDO_NA_MIGRACAO__}"
    fi
    unset senha
    printf '%s\n' "$conteudo" > "$2"
}

backup_1x() {
    header "Backup da instalação 1.x"
    BK1X="$DIR/bkp_v1x_$TS"
    mkdir -m 700 -- "$BK1X" || abort "Falha ao criar $BK1X"

    # Configuração (a 1.x não guardava senha no conf; por segurança, qualquer PGPASSWORD é removido)
    sed -E 's/^([[:space:]]*(export[[:space:]]+)?PGPASSWORD=).*/\1"__REMOVIDO_NA_MIGRACAO__"/' \
        "$CONF_1X" > "$BK1X/migra_postgres.conf"

    # Scripts sem a senha (rotina e, na 1.4, o management.sh)
    if [ -n "$SCRIPT1X_PLAIN" ]; then
        _salva_sem_senha "$SCRIPT1X_PLAIN" "$BK1X/bkp_postgres.sh.sem_senha" && log "Script 1.x salvo sem a senha."
    fi
    if [ "${#MGMT1X[@]}" -gt 0 ]; then
        local mg
        _tmp mg
        if _script_1x_texto "${MGMT1X[0]}" "$mg"; then
            _salva_sem_senha "$mg" "$BK1X/management.sh.sem_senha" && log "management.sh da 1.4 salvo sem a senha."
        fi
        rm -f -- "$mg"
    fi

    {
        echo "# Agendamentos da 1.x encontrados em $(date '+%d/%m/%Y %T')"
        local l
        for l in "${CRON1X[@]}"; do echo "${l%%|*}: ${l#*|}"; done
    } > "$BK1X/cron.txt"

    {
        echo "# Links e arquivos da 1.x"
        ls -l "$CONF_1X_LINK" 2>/dev/null
        echo "conf resolvido: $CONF_1X"
        echo "scripts: ${SCRIPT1X[*]} ${MGMT1X[*]}"
        echo
        echo "# Grupo migrabkp"
        getent group migrabkp 2>/dev/null || echo "(não existe)"
    } > "$BK1X/arquivos.txt"

    local existe
    existe=$(_psql -c "SELECT to_regclass('migrabkp.exclude_bases') IS NOT NULL" 2>/dev/null)
    if [ "$existe" = t ]; then
        _psql -c "COPY (SELECT * FROM migrabkp.exclude_bases ORDER BY 1) TO STDOUT WITH CSV HEADER" \
            > "$BK1X/exclude_bases.csv" 2>/dev/null
        env -u PGPASSWORD PGPASSFILE="$PGPASSFILE_INST" "$PG_BIN/pg_dump" -w -h "$PGHOST" -p "$PGPORT" \
            -U "$PGUSER" -s -n migrabkp -d "$PGDATABASE" > "$BK1X/schema_migrabkp.sql" 2>/dev/null
        log "Tabela migrabkp.exclude_bases salva (estrutura e dados)."
    fi
    existe=$(_psql -c "SELECT to_regclass('migrabkp.exclude_tables') IS NOT NULL" 2>/dev/null)
    if [ "$existe" = t ]; then
        _psql -c "COPY (SELECT * FROM migrabkp.exclude_tables ORDER BY 1) TO STDOUT WITH CSV HEADER" \
            > "$BK1X/exclude_tables.csv" 2>/dev/null
        log "Tabela migrabkp.exclude_tables (1.4) salva."
    fi

    {
        echo "# Inventário em $(date '+%d/%m/%Y %T')"
        for l in "$DIR" "$DIR/bin" "$DIR/log" "$DIR/tmp" "${V1[DIR_BKP]:-}"; do
            [ -n "$l" ] && [ -d "$l" ] || continue
            echo; echo "## $l"; ls -la -- "$l" 2>/dev/null | head -n 200
        done
        echo; echo "## df"; df -h 2>/dev/null
    } > "$BK1X/inventario.txt"

    cat > "$BK1X/README.txt" <<EOF
Backup da rotina de backup PostgreSQL 1.x (MigraTI) feito pelo install.sh $VERSAO_INSTALADOR em $(date '+%d/%m/%Y %T').

Conteúdo
  migra_postgres.conf       configuração da 1.x ($CONF_1X)
  bkp_postgres.sh.sem_senha script da 1.x com a senha do banco removida
  management.sh.sem_senha   gerenciador da 1.4 com a senha removida (se existia)
  cron.txt                  linhas de agendamento encontradas
  arquivos.txt              link $CONF_1X_LINK, scripts e grupo migrabkp
  exclude_bases.csv         bases ignoradas (tabela migrabkp.exclude_bases)
  exclude_tables.csv        tabelas ignoradas (tabela migrabkp.exclude_tables, 1.4)
  schema_migrabkp.sql       estrutura do schema migrabkp
  inventario.txt            listagem dos diretórios da rotina

Os dumps em ${V1[DIR_BKP]:-<DIR_BKP>} e os logs NÃO foram movidos nem apagados.
A senha do banco NÃO está neste backup: ela agora fica só na wallet da 2.x.

Para voltar à 1.x: copiar o conf e o script de volta, recolocar a senha no script e
recriar o link $CONF_1X_LINK. O instalador não altera o agendamento antigo (ver cron.txt).
EOF
    chmod -R go-rwx -- "$BK1X"
    log "Backup da 1.x em ${BOLD}$BK1X${NC}"
}

importa_exclusoes_1x() {
    local existe lista
    existe=$(_psql -c "SELECT to_regclass('migrabkp.exclude_bases') IS NOT NULL" 2>/dev/null)
    if [ "$existe" = t ]; then
        lista=$(_psql -c "SELECT string_agg(name, ',' ORDER BY name) FROM migrabkp.exclude_bases" 2>/dev/null)
        if [ -n "$lista" ]; then
            EXCLUDE_BASES="$lista"
            info "Bases ignoradas importadas da 1.x: $EXCLUDE_BASES"
        fi
    fi
    # 1.4: tabelas ignoradas -> EXCLUDE_TABLE (base|schema|tabela|motivo|usuário|data)
    existe=$(_psql -c "SELECT to_regclass('migrabkp.exclude_tables') IS NOT NULL" 2>/dev/null)
    if [ "$existe" = t ]; then
        lista=$(_psql -F '|' -c "SELECT database_name, schema_name, table_name,
                    translate(coalesce(motivo, ''), E'|\n\r', '/  '), coalesce(usuario, ''),
                    coalesce(to_char(data_inclusao, 'DD/MM/YYYY'), '')
                FROM migrabkp.exclude_tables
                WHERE strpos(database_name || schema_name || table_name, '|') = 0
                ORDER BY 1, 2, 3" 2>/dev/null)
        if [ -n "$lista" ]; then
            EXCLUDE_TABLE="$lista"
            info "Tabelas ignoradas importadas da 1.4: $(grep -c . <<< "$lista")"
        fi
    fi
}

limpa_1x() {
    header "Limpeza da 1.x"
    local f l origem linha u arq rem=()
    for f in "${SCRIPT1X[@]}" "${MGMT1X[@]}" "$CONF_1X"; do [ -f "$f" ] && rem+=("$f"); done
    [ -L "$CONF_1X_LINK" ] && rem+=("$CONF_1X_LINK")
    if [ "${#rem[@]}" -gt 0 ]; then
        info "Arquivos da 1.x (os scripts contêm a senha do banco em texto):"
        for f in "${rem[@]}"; do echo "          $f"; done
        local padrao=S
        [ "$CHECK_OK" = 1 ] || { warn "A verificação da $VERSAO_INSTALADOR falhou; mantenha a 1.x até corrigir."; padrao=N; }
        if askyn "Remover estes arquivos? (cópia sem senha em $BK1X)" "$padrao"; then
            for f in "${rem[@]}"; do rm -f -- "$f" && log "Removido $f"; done
            for f in "${SCRIPT1X[@]}"; do rm -f -- "$f~"; done
        else
            warn "Arquivos da 1.x mantidos. Remova-os depois: a senha continua em texto no script."
        fi
    fi

    # O agendamento antigo não é alterado pelo instalador: fica como pendência para o técnico.
    for l in "${CRON1X[@]}"; do
        origem="${l%%|*}"; linha="${l#*|}"
        if [[ "$origem" == crontab:* ]]; then
            u="${origem#crontab:}"
            PENDENCIAS+=("Remova o agendamento da 1.x do crontab de $u (crontab -e -u $u):|$linha")
        else
            arq="${origem#arquivo:}"
            PENDENCIAS+=("Remova o agendamento da 1.x do arquivo $arq:|$linha")
        fi
    done

    local existe
    existe=$(_psql -c "SELECT to_regclass('migrabkp.exclude_bases') IS NOT NULL OR to_regclass('migrabkp.exclude_tables') IS NOT NULL" 2>/dev/null)
    if [ "$existe" = t ]; then
        info "As listas de exclusão agora ficam na wallet; as tabelas do schema migrabkp não são mais usadas."
        if askyn "Apagar as tabelas e o schema migrabkp do banco $PGDATABASE? (cópia em $BK1X)" N; then
            # Um único comando = uma transação: se o schema tiver outros objetos, nada é apagado.
            if _psql -c "DROP TABLE IF EXISTS migrabkp.exclude_tables, migrabkp.exclude_bases; DROP SCHEMA migrabkp;" >/dev/null 2>&1; then
                log "Schema migrabkp removido."
            else
                warn "Não foi possível remover o schema (há outros objetos nele?). Nada foi apagado."
            fi
        fi
    fi
    if getent group migrabkp >/dev/null 2>&1; then
        info "O grupo 'migrabkp' da 1.x não é mais usado pela 2.x e foi mantido."
        info "  Para removê-lo depois de conferir que nada mais o usa: groupdel migrabkp"
    fi
}

# ------------------------------------------------------------------------------
# Instalação dos arquivos
# ------------------------------------------------------------------------------
_mkdir_rotina() { # <dir> <modo> : cria se não existir; não altera diretórios existentes
    if [ ! -d "$1" ]; then
        mkdir -p -- "$1" && chmod "$2" -- "$1" && log "Criado $1"
    fi
}

# Diretório que já existia e está aberto para outros usuários: só avisa, não altera.
# (Os arquivos da rotina são sempre gravados como 600/700, então continuam protegidos.)
_avisa_permissao() { # <dir> <motivo>
    local perm
    perm=$(stat -c %a -- "$1" 2>/dev/null) || return 0
    [ "${perm: -1}" = 0 ] && return 0
    warn "$1 já existia com permissão $perm (outros usuários têm acesso). Mantida como está."
    info "   $2"
}

cria_diretorios() {
    header "Diretórios"
    _mkdir_rotina "$DIR" 755
    if [ -d "$DIR/bin" ]; then
        _avisa_permissao "$DIR/bin" "Os scripts da rotina dentro dela são gravados cifrados e só para o root."
    else
        _mkdir_rotina "$DIR/bin" 700
    fi
    if [ -d "$DIR/wallet" ]; then
        _avisa_permissao "$DIR/wallet" "A wallet é gravada só para o root (600)."
    else
        _mkdir_rotina "$DIR/wallet" 700
    fi
    _mkdir_rotina "$DIR/log" 750
    _mkdir_rotina "$DIR/tmp" 700
    _mkdir_rotina "$(dirname -- "$LOG_GERAL")" 750
    _mkdir_rotina "$DIR_BKP" 700
    local perm
    perm=$(stat -c %a -- "$DIR_BKP" 2>/dev/null)
    if [ -n "$perm" ] && [ "${perm: -1}" != 0 ]; then
        warn "$DIR_BKP tem permissão $perm: outros usuários do servidor conseguem listar a pasta."
        info "   Os backups novos são gravados só para o root. Backups antigos podem estar legíveis."
        if askyn "Tirar o acesso de 'outros' só deste diretório (chmod o-rwx, sem -R)?" N; then
            chmod o-rwx -- "$DIR_BKP" && log "Permissão de $DIR_BKP ajustada para $(stat -c %a -- "$DIR_BKP")."
        else
            info "Permissão de $DIR_BKP mantida ($perm)."
        fi
    fi
}

_write_loader() { # <enc> <loader> <sha256 do script> <nome>
    local tmp="$2.tmp.$$"
    cat > "$tmp" <<LOADER
#!/bin/bash
# Loader da rotina de backup PostgreSQL MigraTI $VERSAO_INSTALADOR — gerado pelo install.sh. Não edite.
# Decifra $4 com a chave desta máquina, confere a integridade e executa direto da memória.
umask 077
export MIGRA_DIR='$DIR'
_ENC='$1'
_SUM='$3'
_m=""
for _f in /etc/machine-id /var/lib/dbus/machine-id; do
    [ -r "\$_f" ] && _m=\$(tr -d '[:space:]' < "\$_f")
    [ -n "\$_m" ] && break
done
if [ -z "\$_m" ]; then echo "[ERRO] machine-id ausente ou vazio; não é possível carregar $4." >&2; exit 1; fi
_K=\$(printf '%s' "\$_m" | openssl dgst -sha256 | awk '{print \$NF}')
unset _m _f
_dec() { _MC_PASS="\$_K" openssl enc -aes-256-cbc -md sha256 -d -pass env:_MC_PASS -in "\$_ENC" 2>/dev/null; }
if [ "\$(_dec | openssl dgst -sha256 | awk '{print \$NF}')" != "\$_SUM" ]; then
    echo "[ERRO] Falha ao carregar \$_ENC (arquivo alterado/corrompido ou machine-id diferente). Reinstale a rotina." >&2
    exit 1
fi
exec bash <(_dec) "\$@"
LOADER
    chmod 700 -- "$tmp" && mv -f -- "$tmp" "$2"
}

instala_scripts() {
    header "Scripts protegidos"
    if [ "$MODO" = atualizacao ]; then
        local bk="$DIR/bin.bkp.$TS"
        cp -a -- "$DIR/bin" "$bk" && info "Versão anterior dos scripts guardada em $bk"
    fi
    local name base enc
    for name in "${SCRIPTS[@]}"; do
        base="${name%.sh}"
        enc="$DIR/bin/$base.enc"
        _mc_cipher e legacy 0 "$MACHINE_KEY" "${PLAIN[$name]}" "$enc.tmp.$$" \
            || abort "Falha ao cifrar $name"
        chmod 600 -- "$enc.tmp.$$" && mv -f -- "$enc.tmp.$$" "$enc"
        _write_loader "$enc" "$DIR/bin/$base" "${SUMS[$name]}" "$base"
        rm -f -- "${PLAIN[$name]}"
        log "$base instalado (cifrado com a chave desta máquina)"
    done
    if [ -L "$LINK_TOOL" ] || [ ! -e "$LINK_TOOL" ]; then
        mkdir -p -- "$(dirname -- "$LINK_TOOL")"
        ln -sfn -- "$DIR/bin/migra-wallet-pg" "$LINK_TOOL" && log "Comando disponível: migra-wallet-pg"
    else
        warn "$LINK_TOOL já existe e não é um link; use $DIR/bin/migra-wallet-pg"
    fi
}

WALLET_PASS=""
cria_wallet() {
    header "Wallet"
    local wallet="$DIR/wallet/migra.wallet" auto="$DIR/wallet/migra.auto" plain p2
    info "A senha da wallet protege a configuração (inclusive a senha do banco)."
    info "Ela é pedida para ver ou alterar qualquer configuração com migra-wallet-pg."
    info "O backup agendado não precisa dela. Guarde-a no Passbolt agora."
    while true; do
        askpass WALLET_PASS "Senha da wallet (mín. 8 caracteres)"
        [ "${#WALLET_PASS}" -ge 8 ] || { warn "Senha muito curta."; continue; }
        askpass p2 "Confirme a senha"
        [ "$WALLET_PASS" = "$p2" ] || { warn "As senhas não conferem."; continue; }
        break
    done
    unset p2
    VERSION="$VERSAO_INSTALADOR"
    _tmp plain
    _mc_render > "$plain"
    ( _mc_parse "$(cat "$plain")" && _mc_validate ) || abort "Configuração gerada é inválida (veja acima)."
    _mc_write "$wallet" WALLET "$(_mc_wallet_kdf)" "$WALLET_PASS" "$plain" || abort "Falha ao criar a wallet."
    _mc_write "$auto" AUTO legacy "$MACHINE_KEY" "$plain" || abort "Falha ao criar o auto-login."
    rm -f -- "$plain"
    log "Wallet: $wallet"
    log "Auto-login (só abre nesta máquina): $auto"
}

atualiza_wallet() { # modo atualização: abre a wallet, acrescenta chaves novas e regrava
    header "Wallet"
    local wallet="$DIR/wallet/migra.wallet" auto="$DIR/wallet/migra.auto" txt rc plain
    while true; do
        askpass WALLET_PASS "Senha da wallet atual"
        txt=$(_mc_read "$wallet" "$WALLET_PASS"); rc=$?
        [ "$rc" -eq 0 ] && break
        [ "$rc" -eq 1 ] && { warn "Senha incorreta."; continue; }
        abort "Wallet com formato inválido: $wallet"
    done
    txt=$(_mc_txt_merge "$txt")
    txt=$(_mc_txt_set "$txt" VERSION "$VERSAO_INSTALADOR")
    _mc_defaults
    _mc_parse "$txt" || abort "A wallet atual tem linhas inválidas. Corrija com migra-wallet-pg -edit e rode de novo."
    UPDATED_TXT="$txt"
}

# Atualização: confere se a credencial guardada na wallet ainda conecta, ANTES de aplicar.
# Se não conectar, mostra o erro e oferece corrigir (o resultado vai para a wallet).
CONEXAO_STATUS="não verificada"
testa_conexao_wallet() {
    header "Conexão com o PostgreSQL"
    local out errf d mv=0 k falhou=0
    _candidatos_pg
    PSQL_INST="${PG_BIN%/}/psql"
    if [ ! -x "$PSQL_INST" ]; then
        for d in "${!CAND[@]}"; do [ "${CAND[$d]}" -gt "$mv" ] && { mv="${CAND[$d]}"; PSQL_INST="$d/psql"; }; done
    fi
    if [ ! -x "$PSQL_INST" ]; then
        warn "psql não encontrado; a conexão será conferida na verificação final."
        return 0
    fi
    _tmp errf
    _pgpass_tmp PGPASSFILE_INST "$PGUSER" "$PGPASSWORD"
    if out=$(_psql -c 'SHOW server_version_num' 2> "$errf") && [[ "$out" =~ ^[0-9]+$ ]]; then
        SERVER_NUM="$out"; CONEXAO_STATUS="OK"
        log "A configuração atual conecta: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
        return 0
    fi
    err "A configuração atual NÃO conecta ($PGUSER@$PGHOST:$PGPORT/$PGDATABASE):"
    err "  $(head -n 1 "$errf")"
    info "Sem conexão, o backup agendado vai falhar. Dá para corrigir agora: Enter mantém cada valor."
    if askyn "Corrigir a conexão agora?" S; then
        while true; do
            PG_BIN_ESCOLHIDO=1 CONEXAO_OPCIONAL=1 configura_conexao; case $? in 0) break ;; 2) continue ;; *) falhou=1; break ;; esac
        done
        if [ "$falhou" = 0 ]; then
            for k in PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD PG_BIN; do
                UPDATED_TXT=$(_mc_txt_set "$UPDATED_TXT" "$k" "${!k}")
            done
            CONEXAO_STATUS="OK (corrigida; vai para a wallet)"
            return 0
        fi
    fi
    CONEXAO_STATUS="${RED}FALHA${NC} (não corrigida)"
    warn "Seguindo sem corrigir. Depois use: migra-wallet-pg -setCredential"
}

grava_wallet_atualizada() {
    local wallet="$DIR/wallet/migra.wallet" auto="$DIR/wallet/migra.auto" plain
    _tmp plain
    printf '%s\n' "$UPDATED_TXT" > "$plain"
    cp -p -- "$wallet" "$wallet.1"
    _mc_write "$wallet" WALLET "$(_mc_wallet_kdf)" "$WALLET_PASS" "$plain" || abort "Falha ao regravar a wallet."
    _mc_write "$auto" AUTO legacy "$MACHINE_KEY" "$plain" || abort "Falha ao regravar o auto-login."
    rm -f -- "$plain"
    log "Wallet atualizada (versão anterior em $wallet.1)."
}

# Agendamento no crontab do root (padrão MigraTI: crontab -l / crontab -e).
# Uma linha é "da rotina" só se um dos campos for exatamente <dir>/bin/bkp_postgres:
# outras rotinas no mesmo diretório (ex.: bin/bkp_postgres_docker.sh) não contam.
_CRON_AWK_NOSSA='function nossa(l,   n, i, f) {
    if (l ~ /^[[:space:]]*#/) return 0
    n = split(l, f, /[[:space:]]+/)
    for (i = 1; i <= n; i++) if (f[i] == ENVIRON["D"]) return 1
    return 0
}'

_cron_linhas() { # <dir> : linhas ativas do crontab do root que chamam o loader de <dir>
    crontab -l 2>/dev/null | D="$1/bin/bkp_postgres" awk "$_CRON_AWK_NOSSA"' nossa($0)'
}

_cron_grava() { # <dir> <arquivo com o crontab novo> : guarda o crontab atual antes de trocar
    local bk="$1/crontab_root_$TS.bkp"
    crontab -l > "$bk" 2>/dev/null || : > "$bk"
    chmod 600 -- "$bk"
    if crontab "$2"; then
        info "Crontab anterior guardado em $bk"
        return 0
    fi
    err "Falha ao gravar o crontab do root (o anterior está em $bk)."
    return 1
}

# Tira do crontab do root só as linhas da rotina de <dir> e o comentário logo acima delas.
_cron_remove_linha() { # <dir>
    command -v crontab >/dev/null 2>&1 || return 0
    [ -n "$(_cron_linhas "$1")" ] || return 0
    local novo; _tmp novo
    crontab -l 2>/dev/null | D="$1/bin/bkp_postgres" T="$CRON_TAG" awk "$_CRON_AWK_NOSSA"'
        {
            if (pend != "") { if (!nossa($0)) print pend; pend = "" }
            if ($0 == ENVIRON["T"]) { pend = $0; next }
            if (nossa($0)) next
            print
        }
        END { if (pend != "") print pend }' > "$novo"
    _cron_grava "$1" "$novo" && log "Linha da rotina removida do crontab do root"
}

# O /etc/cron.d/migrabkp-postgres da 2.0 não é apagado: vira pendência para o técnico.
_cron_pendencia_2x() {
    [ -f "$CRON_FILE_2X" ] && grep -q 'MigraTI' "$CRON_FILE_2X" || return 0
    PENDENCIAS+=("Remova o agendamento antigo da 2.0 (senão a rotina é chamada duas vezes):|rm -f $CRON_FILE_2X")
}

_cron_linha_nova() { # linha no padrão MigraTI: "MM HH * * * comando >>/dev/null"
    printf '%02d %02d * * * %s/bin/bkp_postgres >>/dev/null' "$((10#${CRON_HM#*:}))" "$((10#${CRON_HM%%:*}))" "$DIR"
}

_cron_hm() { # <minuto> <hora> -> HH:MM, ou falha se não forem números simples
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "${2:-}" =~ ^[0-9]+$ ]] && [ "$((10#$2))" -le 23 ] && [ "$((10#$1))" -le 59 ] || return 1
    printf '%02d:%02d' "$((10#$2))" "$((10#$1))"
}

# Decide o agendamento antes do resumo (nada é gravado aqui).
#   CRON_ORIGEM: crontab (já existe, mantido) | 2x (vem do /etc/cron.d) | nova
CRON_HM="18:00"; CRON_PERGUNTAR=S; CRON_ORIGEM=nova; CRON_EXISTENTE=""
_cron_prepara() {
    local l hm
    local -a c
    CRON_PERGUNTAR=S; CRON_ORIGEM=nova; CRON_EXISTENTE=""
    if command -v crontab >/dev/null 2>&1; then CRON_EXISTENTE=$(_cron_linhas "$DIR"); fi
    if [ -n "$CRON_EXISTENTE" ]; then
        read -ra c <<< "$(head -n1 <<< "$CRON_EXISTENTE")"
        hm=$(_cron_hm "${c[0]:-}" "${c[1]:-}") && CRON_HM="$hm"
        CRON_PERGUNTAR=N; CRON_ORIGEM=crontab; return 0
    fi
    if [ -f "$CRON_FILE_2X" ]; then
        l=$(grep -F -- '/bin/bkp_postgres' "$CRON_FILE_2X" | grep -v '^[[:space:]]*#' | head -n1)
        read -ra c <<< "$l"
        if hm=$(_cron_hm "${c[0]:-}" "${c[1]:-}"); then
            CRON_HM="$hm"; CRON_PERGUNTAR=N; CRON_ORIGEM=2x; return 0
        fi
    fi
    for l in "${CRON1X[@]}"; do               # 1.x: sugere o mesmo horário
        read -ra c <<< "${l#*|}"
        if hm=$(_cron_hm "${c[0]:-}" "${c[1]:-}"); then CRON_HM="$hm"; break; fi
    done
}

_cron_resumo() {
    case "$CRON_ORIGEM" in
        crontab) echo "já existe no crontab do root (mantido)" ;;
        2x)      echo "diário às $CRON_HM · crontab do root (o /etc/cron.d antigo fica para você remover)" ;;
        *)       echo "diário às $CRON_HM · crontab do root" ;;
    esac
}

configura_cron() {
    header "Agendamento"
    local linha; linha=$(_cron_linha_nova)
    if ! command -v crontab >/dev/null 2>&1; then
        warn "Comando crontab não encontrado. Agende no crontab do root (crontab -e):"
        echo "          $linha"
        return 0
    fi
    local atual; atual=$(_cron_linhas "$DIR")
    if [ -n "$atual" ]; then
        info "Agendamento existente mantido (crontab -l):"
        sed 's/^/          /' <<< "$atual"
        _cron_pendencia_2x
        return 0
    fi
    local novo ct; _tmp novo
    ct=$(crontab -l 2>/dev/null)
    {
        if ! grep -qF 'MigraTI Solucoes em TI' <<< "$ct"; then printf '%s
' "${CRON_HEADER[@]}" ""; fi
        [ -n "$ct" ] && printf '%s
' "$ct"
        echo "$linha"
    } > "$novo"
    if _cron_grava "$DIR" "$novo"; then
        log "Agendado no crontab do root, diário às $CRON_HM:"
        echo "          $linha"
        _cron_pendencia_2x
    else
        warn "Sem agendamento. Para criar depois: crontab -e e adicione a linha acima."
    fi
}

CHECK_OK=0
verifica() {
    header "Verificação"
    while true; do
        if "$DIR/bin/bkp_postgres" --check; then
            CHECK_OK=1
            log "Rotina verificada com sucesso."
            return 0
        fi
        warn "A verificação apontou problemas (acima). Os scripts já foram instalados; falta só ajustar a configuração."
        if ! askyn "Abrir o menu do migra-wallet-pg para corrigir agora?" S; then
            warn "Corrija depois com migra-wallet-pg e confira com: migra-wallet-pg -test"
            return 0
        fi
        "$DIR/bin/migra-wallet-pg" < "$TTY" || true
        header "Verificação"
    done
}

resumo() {
    header "Instalação concluída"
    linha_resumo "Rotina" "bkp_postgres $VERSAO_INSTALADOR · modo $MODO"
    linha_resumo "Diretório" "$DIR"
    linha_resumo "Backups" "$DIR_BKP"
    linha_resumo "Log geral" "$LOG_GERAL"
    if command -v crontab >/dev/null 2>&1 && [ -n "$(_cron_linhas "$DIR")" ]; then
        linha_resumo "Agendamento" "crontab do root · $(_cron_linhas "$DIR" | head -n1 | awk '{printf "%02d:%02d", $2, $1}')"
    fi
    [ -n "${BK1X:-}" ] && linha_resumo "Backup da 1.x" "$BK1X"
    echo
    echo -e "   ${BOLD}Comandos${NC}"
    linha_resumo "migra-wallet-pg" "menu de configuração"
    linha_resumo "migra-wallet-pg -list" "ver a configuração"
    linha_resumo "migra-wallet-pg -test" "validar sem fazer backup"
    linha_resumo "$DIR/bin/bkp_postgres" "rodar o backup agora"
    echo
    if [ "${#PENDENCIAS[@]}" -gt 0 ]; then
        local p
        echo -e "   ${YELLOW}${BOLD}Falta você fazer${NC}"
        for p in "${PENDENCIAS[@]}"; do
            warn "${p%%|*}"
            echo -e "        ${BOLD}${p#*|}${NC}"
        done
        echo
    fi
    warn "Guarde a senha da wallet no Passbolt."
    warn "Apague o instalador: rm -f install.sh"
    echo
}

# ------------------------------------------------------------------------------
# Remoção
# ------------------------------------------------------------------------------
desinstala() {
    header "Remoção da rotina"
    local d=""
    if [ -L "$LINK_TOOL" ]; then d=$(dirname -- "$(dirname -- "$(readlink -f -- "$LINK_TOOL")")"); fi
    [ -n "$d" ] || d="$DIR_PADRAO"
    ask d "Diretório da rotina 2.x" "$d"
    d="${d%/}"
    _dir_seguro "$d" || abort "Diretório inválido: $d"
    [ -e "$d/bin/bkp_postgres" ] || [ -e "$d/wallet/migra.wallet" ] || abort "Rotina 2.x não encontrada em $d"
    info "Serão removidos: a linha da rotina no crontab do root, $LINK_TOOL e os scripts em $d/bin"
    info "NÃO serão tocados: backups, logs e bkp_v1x_*"
    askyn "Continuar?" N || abort "Cancelado."
    _cron_remove_linha "$d"
    if [ -f "$CRON_FILE_2X" ] && grep -q 'MigraTI' "$CRON_FILE_2X"; then
        warn "Existe o agendamento antigo da 2.0. Remova-o com: rm -f $CRON_FILE_2X"
    fi
    if [ -L "$LINK_TOOL" ]; then rm -f -- "$LINK_TOOL" && log "Removido $LINK_TOOL"; fi
    rm -f -- "$d/bin/bkp_postgres" "$d/bin/bkp_postgres.enc" "$d/bin/migra-wallet-pg" "$d/bin/migra-wallet-pg.enc"
    rm -rf -- "$d"/bin.bkp.*
    rmdir -- "$d/bin" 2>/dev/null
    log "Scripts removidos."
    if [ -d "$d/wallet" ]; then
        warn "A wallet guarda toda a configuração. Sem ela, uma reinstalação começa do zero."
        if askyn "Apagar também a wallet ($d/wallet)?" N; then
            rm -f -- "$d/wallet/migra.wallet" "$d/wallet/migra.wallet".[0-9] "$d/wallet/migra.auto" "$d/wallet/.migra.lock"
            rmdir -- "$d/wallet" 2>/dev/null
            log "Wallet removida."
        fi
    fi
    rm -f -- "$d/tmp/bkp_postgres.lock"
    log "Remoção concluída."
}

mostra_resumo() {
    local f x primeiro=1
    header "Resumo antes de aplicar"
    linha_resumo "Modo" "$MODO"
    linha_resumo "Diretório da rotina" "$DIR"
    if [ "$MODO" = atualizacao ]; then
        linha_resumo "Nova versão" "$PKG_VERSAO (a configuração atual é mantida)"
        linha_resumo "Banco" "$PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
        linha_resumo "Conexão" "$CONEXAO_STATUS"
        linha_resumo "Agendamento" "$(_cron_resumo)"
        echo; return 0
    fi
    linha_resumo "Banco" "$PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
    linha_resumo "pg_dump" "$PG_BIN"
    linha_resumo "Backups em" "$DIR_BKP"
    f="$BKP_FORMATO · compactação $NIVEL_COMPACTACAO"
    [ "$BKP_FORMATO" = directory ] && f+=" · $QTDCORES jobs"
    [ "$USE_PIGZ" = S ] && f+=" · pigz $PIGZ_THREADS threads"
    linha_resumo "Formato" "$f · globals $BKP_GLOBALS · config $BKP_CONFIG"
    linha_resumo "Retenção" "$RETENCAO_BKP dia(s) local · logs $RETENCAO_ARQ_LOG dia(s)"
    if [ "$REMOTE_MODE" = S ]; then
        linha_resumo "Storage remoto" "$REMOTE_STRING${PATH_REMOTO:+/$PATH_REMOTO} · $RETENCAO_BKP_REMOTO dia(s)"
        [ "$REMOTE_EXTRA" = S ] && linha_resumo "Segundo storage" "$REMOTE_STRING2${PATH_REMOTO2:+/$PATH_REMOTO2} · $RETENCAO_BKP_REMOTO2 dia(s)"
    else
        linha_resumo "Storage remoto" "${DIM}não${NC}"
    fi
    if [ "$IS_S3" = S ]; then linha_resumo "S3" "s3://$BUCKET_NAME/$FOLDER_S3 · $RETENCAO_BKP_S3 dia(s)"
    else linha_resumo "S3" "${DIM}não${NC}"; fi
    if [ "$TITAN" = S ]; then linha_resumo "Zabbix" "$T_IP · host $T_HOST"
    else linha_resumo "Zabbix" "${DIM}não${NC}"; fi
    IFS=',' read -ra _l <<< "$EXCLUDE_BASES"
    for x in "${_l[@]}"; do
        x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
        [ -n "$x" ] || continue
        if [ "$primeiro" = 1 ]; then linha_resumo "Bases ignoradas" "$x"; primeiro=0
        else printf '%27s%s\n' "" "$x"; fi
    done
    [ "$primeiro" = 1 ] && linha_resumo "Bases ignoradas" "${DIM}nenhuma${NC}"
    if [ -n "$EXCLUDE_TABLE" ]; then linha_resumo "Tabelas ignoradas" "$(grep -c . <<< "$EXCLUDE_TABLE")"; fi
    linha_resumo "Agendamento" "$(_cron_resumo)"
    echo
}

# Perguntas da instalação nova/migração, com "voltar" entre as etapas:
#   diretório (só nova) ← conexão ← configuração do backup
_perguntas() {
    local e=1 rc exclusoes_importadas=0
    while [ "$e" -le 2 ]; do
        case $e in
            1)  configura_conexao; rc=$?
                CONEXAO_DO_FIM=0
                if [ "$rc" = 0 ]; then e=2
                elif [ "$MODO" = nova ]; then
                    if ! detecta_modo 4; then
                        detecta_modo
                        if [ "$MODO" = migracao ]; then localiza_1x; importa_1x; _cron_prepara; fi
                    fi
                else warn "Esta é a primeira pergunta da migração."
                fi ;;
            2)  if [ "$MODO" = migracao ] && [ "$exclusoes_importadas" = 0 ]; then
                    importa_exclusoes_1x; exclusoes_importadas=1
                fi
                if coleta_config; then e=3
                else e=1; CONEXAO_DO_FIM=1; echo -e "  ${DIM}↑ voltando${NC}"; fi ;;
        esac
    done
    dependencias
}

# ------------------------------------------------------------------------------
# Principal
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"
    banner
    check_basico
    if [ "$UNINSTALL" = 1 ]; then desinstala; exit 0; fi
    como_responder

    obter_pacote                         # 1º: chave do dia; inválida = encerra sem perguntas
    detecta_modo                         # até a confirmação do resumo, nada é alterado no servidor
    _mc_defaults

    case "$MODO" in
        atualizacao)
            atualiza_wallet
            testa_conexao_wallet
            _cron_prepara
            if [ "$CRON_PERGUNTAR" = S ]; then
                info "Esta instalação não tem agendamento."
                until askkey CRON_HM "Horário do backup diário (HH:MM)" hora; do :; done
            fi
            ;;
        migracao)
            localiza_1x
            importa_1x
            _cron_prepara
            _perguntas
            ;;
        nova)
            _cron_prepara
            _perguntas
            ;;
    esac

    local resp valida padrao
    while true; do
        mostra_resumo
        if [ "$MODO" = atualizacao ]; then
            if ! ( _mc_parse "$UPDATED_TXT" && _mc_validate ) > /dev/null 2>&1; then
                ( _mc_parse "$UPDATED_TXT" && _mc_validate ) 2>&1 | sed 's/^/       /'
                warn "A wallet atual tem valores inválidos (acima). Depois da atualização, corrija com migra-wallet-pg."
            fi
            askyn "Aplicar a atualização?" S || abort "Cancelado. Nada foi alterado."
            break
        fi
        valida=1; padrao=S
        _config_valida || { valida=0; padrao=B; }
        echo -e "   ${BOLD}S${NC} aplicar   ${BOLD}B${NC} revisar o backup   ${BOLD}C${NC} revisar a conexão   ${BOLD}N${NC} cancelar"
        ask resp "Escolha" "$padrao" || continue
        case "${resp^^}" in
            S) [ "$valida" = 1 ] && break
               warn "Corrija os valores acima (B ou C) antes de aplicar. Nada foi alterado." ;;
            B) REVISAO=1 coleta_config; dependencias ;;
            C) REVISAO=1 configura_conexao ;;
            N) abort "Cancelado. Nada foi alterado." ;;
            *) warn "Responda S, B, C ou N." ;;
        esac
    done

    [ "$MODO" = migracao ] && backup_1x
    cria_diretorios
    instala_scripts
    if [ "$MODO" = atualizacao ]; then grava_wallet_atualizada; else cria_wallet; fi
    unset PGPASSWORD AWS_SECRET_ACCESS_KEY
    configura_cron
    verifica
    [ "$MODO" = migracao ] && limpa_1x
    resumo
}

# Carregado com "source" (testes): só define as funções.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
main "$@"
