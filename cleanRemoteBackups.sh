#!/usr/bin/env bash
# Limpeza de Backups Antigos na Nuvem (Google Drive) via rclone
# Uso: ./cleanRemoteBackups.sh [-v] [-d] [-f]

set -euo pipefail

# ─────────────────────────────────────────────
# Argumentos
# ─────────────────────────────────────────────

VERBOSE=0
DRY_RUN=0
FORCE=0
while getopts ":vdf" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        d) DRY_RUN=1 ;;
        f) FORCE=1 ;;
        *) echo "Uso: $0 [-v] [-d] [-f]"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────
# Configuração
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/backup.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] Arquivo de configuração $ENV_FILE não encontrado." >&2
    exit 1
fi

source "$ENV_FILE"

# Validação das variáveis obrigatórias
: "${RCLONE_REMOTE:?Erro: RCLONE_REMOTE não definido no backup.env}"
: "${REMOTE_RETENTION_DAYS:?Erro: REMOTE_RETENTION_DAYS não definido no backup.env}"
REMOTE_CLEANUP_SAFETY_DAYS="${REMOTE_CLEANUP_SAFETY_DAYS:-2}"
DRIVE_DESTINATION="${DRIVE_DESTINATION:-Backups}"

# Log na mesma pasta do script por padrão
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/sync.log}"

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

_log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
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

# ─────────────────────────────────────────────
# Verificação de Segurança
# ─────────────────────────────────────────────

REMOTE_PATH="${RCLONE_REMOTE}/${DRIVE_DESTINATION}"

if [ "$FORCE" = "1" ]; then
    log_warn "--- MODO FORÇADO ATIVADO: Ignorando trava de segurança ---"
else
    log_verbose "Verificando se há backups recentes (últimos $REMOTE_CLEANUP_SAFETY_DAYS dias)..."
    
    # Busca arquivos recentes no Drive
    RECENT_FILES=$(rclone lsf "$REMOTE_PATH" --max-age "${REMOTE_CLEANUP_SAFETY_DAYS}d" --recursive --files-only 2>/dev/null | head -n 1) || true
    
    if [ -z "$RECENT_FILES" ]; then
        log_error "⚠️ SEGURANÇA: Nenhum backup recente encontrado no Drive nos últimos $REMOTE_CLEANUP_SAFETY_DAYS dias!"
        log_error "A limpeza foi ABORTADA para preservar o histórico existente. Verifique se o script de backup está funcionando."
        exit 1
    fi
    log_verbose "   ✓ Backup recente detectado. Prosseguindo..."
fi

# ─────────────────────────────────────────────
# Execução da Limpeza
# ─────────────────────────────────────────────

log_info "Iniciando limpeza na nuvem: $REMOTE_PATH"
log_info "Critério: Arquivos com mais de $REMOTE_RETENTION_DAYS dias."

RCLONE_FLAGS=("--min-age" "${REMOTE_RETENTION_DAYS}d")

if [ "$VERBOSE" = "1" ]; then
    RCLONE_FLAGS+=("--log-level" "INFO")
fi

if [ "$DRY_RUN" = "1" ]; then
    log_warn "--- MODO SIMULAÇÃO (DRY-RUN) ATIVADO ---"
    RCLONE_FLAGS+=("--dry-run")
fi

# Executa a deleção
if rclone delete "$REMOTE_PATH" "${RCLONE_FLAGS[@]}"; then
    [ "$DRY_RUN" = "1" ] && log_info "Simulação concluída. Nenhum arquivo foi deletado." || log_info "Limpeza concluída com sucesso."
else
    log_error "Erro ao executar a limpeza no Drive."
    exit 1
fi

exit 0
