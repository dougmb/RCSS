#!/usr/bin/env bash
# Sincronização de Backups para Google Drive via rclone
# Uso: ./uploadBackup.sh [-v] [-p] [-o <origin>] [-r <rclone_remote>] [-d <drive_destination>] [-a <arquivo>]
# Este script percorre /opt/backups/<PROJETO> e sobe para o Drive.

set -euo pipefail

# ─────────────────────────────────────────────
# Argumentos
# ─────────────────────────────────────────────

VERBOSE=0
SHOW_PROGRESS=0
BACKUP_ROOT_OVERRIDE=""
RCLONE_REMOTE_OVERRIDE=""
DRIVE_DESTINATION_OVERRIDE=""
SINGLE_FILE=""
while getopts ":vpo:r:d:a:" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        p) SHOW_PROGRESS=1 ;;
        o) BACKUP_ROOT_OVERRIDE="$OPTARG" ;;
        r) RCLONE_REMOTE_OVERRIDE="$OPTARG" ;;
        d) DRIVE_DESTINATION_OVERRIDE="$OPTARG" ;;
        a) SINGLE_FILE="$OPTARG" ;;
        *) echo "Uso: $0 [-v] [-p] [-o <origin>] [-r <rclone_remote>] [-d <drive_destination>] [-a <arquivo>]"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────
# Configuração (Exclusiva do backup.env)
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/backup.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] Arquivo de configuração $ENV_FILE não encontrado." >&2
    exit 1
fi

# Carrega as configurações
# shellcheck source=/dev/null
source "$ENV_FILE"

# Validação das variáveis obrigatórias
: "${BACKUP_ROOT:?Erro: BACKUP_ROOT não definido no backup.env}"
: "${RCLONE_REMOTE:?Erro: RCLONE_REMOTE não definido no backup.env}"
: "${RETENTION_DAYS:?Erro: RETENTION_DAYS não definido no backup.env}"

# Configuração da pasta de destino no Google Drive (ex: Backups)
DRIVE_DESTINATION="${DRIVE_DESTINATION:-Backups}"

# Override via CLI tem prioridade sobre o backup.env
if [ -n "$BACKUP_ROOT_OVERRIDE" ]; then
    BACKUP_ROOT="$BACKUP_ROOT_OVERRIDE"
fi
if [ -n "$RCLONE_REMOTE_OVERRIDE" ]; then
    RCLONE_REMOTE="$RCLONE_REMOTE_OVERRIDE"
fi
if [ -n "$DRIVE_DESTINATION_OVERRIDE" ]; then
    DRIVE_DESTINATION="$DRIVE_DESTINATION_OVERRIDE"
fi

# Log na mesma pasta do script por padrão, se não definido no .env
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/sync.log}"

# Pastas a ignorar (carregadas do .env ou valores padrão de segurança)
IGNORED_FOLDERS="${IGNORED_FOLDERS:-scripts config bin logs lost+found}"

UPLOAD_ERRORS=0
TOTAL_DELETED=0
OVERALL_START=$(date +%s)

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

_log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
    # Append ao final do arquivo de log (EOF)
    echo "$msg" >> "$LOG_FILE"
}

log_info()    { _log "INFO   " "$*"; }
log_warn()    { _log "WARN   " "$*" >&2; }
log_error()   { _log "ERROR  " "$*" >&2; }
log_verbose() {
    if [ "$VERBOSE" = "1" ]; then
        _log "VERBOSE" "$*"
    fi
}

elapsed() {
    local start="$1"
    echo $(( $(date +%s) - start ))
}

rclone_log_level() {
    [ "$VERBOSE" = "1" ] && echo "DEBUG" || echo "NOTICE"
}

# Trap para erros inesperados
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "O script terminou inesperadamente com o código $exit_code"
    fi
}
trap cleanup_on_error EXIT

# ─────────────────────────────────────────────
# Validações iniciais
# ─────────────────────────────────────────────

if ! command -v rclone &>/dev/null; then
    log_error "rclone não encontrado. Instale antes de continuar."
    exit 1
fi

# ─────────────────────────────────────────────
# Modo arquivo avulso (-a)
# ─────────────────────────────────────────────

if [ -n "$SINGLE_FILE" ]; then
    if [ ! -f "$SINGLE_FILE" ]; then
        log_error "Arquivo não encontrado: $SINGLE_FILE"
        exit 1
    fi

    log_info "Enviando arquivo avulso: $SINGLE_FILE"
    RCLONE_FLAGS=("--log-level" "$(rclone_log_level)" "--retries" "3")
    [ "$SHOW_PROGRESS" = "1" ] && RCLONE_FLAGS+=("-P")

    if rclone copy "$SINGLE_FILE" "${RCLONE_REMOTE}/${DRIVE_DESTINATION}/" "${RCLONE_FLAGS[@]}"; then
        log_info "✓ Arquivo enviado com sucesso."
    else
        log_error "Falha ao enviar $SINGLE_FILE"
        trap - EXIT
        exit 1
    fi

    trap - EXIT
    exit 0
fi

# ─────────────────────────────────────────────
# Modo padrão (projetos)
# ─────────────────────────────────────────────

if [ ! -d "$BACKUP_ROOT" ]; then
    log_error "Diretório raiz de backups não encontrado: $BACKUP_ROOT"
    exit 1
fi

log_info "Iniciando sincronização de backups..."
log_verbose "Raiz: $BACKUP_ROOT | Remoto: $RCLONE_REMOTE | Retenção: $RETENTION_DAYS dias"

# ─────────────────────────────────────────────
# Processamento por Projeto
# ─────────────────────────────────────────────

# Loop por cada subdiretório em /opt/backups/
# Usamos nullglob para evitar erro se a pasta estiver vazia
shopt -s nullglob
for project_path in "$BACKUP_ROOT"/*; do
    # 1. Pula se não for um diretório
    [ -d "$project_path" ] || continue
    
    PROJECT_NAME=$(basename "$project_path")

    # 2. SEGURANÇA: Pula pastas que não são projetos de backup
    # Ignora pastas ocultas (que começam com .) e pastas definidas em IGNORED_FOLDERS
    if [[ "$PROJECT_NAME" == .* ]] || [[ " ${IGNORED_FOLDERS} " == *" ${PROJECT_NAME} "* ]]; then
        log_verbose "   - Pulando pasta ignorada/reservada: $PROJECT_NAME"
        continue
    fi
    
    log_info "→ Processando projeto: $PROJECT_NAME"
    STEP_START=$(date +%s)

    # 1. Upload para o Drive (organizado por pasta de projeto)
    # Tentativa de upload com retry simples para resiliência
    RCLONE_FLAGS=("--log-level" "$(rclone_log_level)" "--stats-one-line" "--stats" "10s" "--update" "--use-mmap" "--retries" "3")
    [ "$SHOW_PROGRESS" = "1" ] && RCLONE_FLAGS+=("-P")

    if rclone copy "$project_path" "${RCLONE_REMOTE}/${DRIVE_DESTINATION}/${PROJECT_NAME}" \
        "${RCLONE_FLAGS[@]}"; then

        log_info "   ✓ Sincronizado com sucesso."

        # 2. Limpeza de backups antigos localmente (SÓ após upload bem-sucedido)
        log_verbose "   Limpando arquivos locais com mais de $RETENTION_DAYS dias..."

        DELETED_COUNT=$(find "$project_path" -maxdepth 1 -type f -mtime +"$RETENTION_DAYS" -print -delete 2>/dev/null | wc -l) || DELETED_COUNT=0

        [ "$DELETED_COUNT" -gt 0 ] && log_info "   - Removidos $DELETED_COUNT arquivos antigos."
        TOTAL_DELETED=$((TOTAL_DELETED + DELETED_COUNT))
    else
        log_warn "   ⚠ Falha na sincronização do projeto $PROJECT_NAME. Limpeza local IGNORADA."
        UPLOAD_ERRORS=$((UPLOAD_ERRORS + 1))
    fi
    
    log_verbose "   Tempo do projeto: $(elapsed $STEP_START)s"
done
shopt -u nullglob

# ─────────────────────────────────────────────
# Resumo Final
# ─────────────────────────────────────────────

TOTAL_DURATION=$(elapsed $OVERALL_START)
STATUS=$( [ "$UPLOAD_ERRORS" -eq 0 ] && echo "SUCCESS" || echo "PARTIAL" )

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "✅ Sincronização concluída em ${TOTAL_DURATION}s"

# Bloco de resumo para o log (sempre no final)
{
    echo "════════════════════════════════════════════════"
    echo "  RESUMO DA SINCRONIZAÇÃO — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════"
    echo "  Status         : $STATUS"
    echo "  Duração        : ${TOTAL_DURATION}s"
    echo "  Destino Cloud  : ${RCLONE_REMOTE}/${DRIVE_DESTINATION}/"
    echo "  Projetos c/ Erro: $UPLOAD_ERRORS"
    echo "  Arquivos Removidos (Local): $TOTAL_DELETED"
    echo "════════════════════════════════════════════════"
    echo ""
} >> "$LOG_FILE"

# Remove o trap de erro para saída limpa
trap - EXIT

[ "$UPLOAD_ERRORS" -gt 0 ] && exit 1 || exit 0
