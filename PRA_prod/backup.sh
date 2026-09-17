#!/bin/bash

# ============================================================
# backup_www.sh
#
# Sauvegarde automatique et chiffrée de /var/www/html
#
# - Nouvelle clé AES-256 à chaque exécution
# - Toutes les archives chiffrées sont conservées
# - Toutes les clés sont conservées
# - Toutes les sauvegardes sont identifiées par horodatage
# - Aucune interaction avec l'utilisateur
# - L'archive temporaire non chiffrée est supprimée
#   après chiffrement réussi
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

SOURCE_DIR="/var/www/html"

BACKUP_ROOT="/backup"
ARCHIVE_DIR="${BACKUP_ROOT}/archives"
KEY_DIR="${BACKUP_ROOT}/keys"
LOG_DIR="${BACKUP_ROOT}/logs"

# ------------------------------------------------------------
# Vérification root
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[ERREUR] Le script doit être exécuté avec sudo." >&2
    exit 1
fi

# ------------------------------------------------------------
# Vérification du dossier source
# ------------------------------------------------------------

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "[ERREUR] Le dossier $SOURCE_DIR n'existe pas." >&2
    exit 1
fi

# ------------------------------------------------------------
# Vérification des commandes nécessaires
# ------------------------------------------------------------

if ! command -v openssl >/dev/null 2>&1; then
    echo "[ERREUR] openssl n'est pas installé." >&2
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "[ERREUR] tar n'est pas installé." >&2
    exit 1
fi

# ------------------------------------------------------------
# Création des dossiers
# ------------------------------------------------------------

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$KEY_DIR"
mkdir -p "$LOG_DIR"

# Protection des sauvegardes
chmod 700 "$BACKUP_ROOT"
chmod 700 "$ARCHIVE_DIR"
chmod 700 "$KEY_DIR"
chmod 700 "$LOG_DIR"

# ------------------------------------------------------------
# Horodatage
# ------------------------------------------------------------

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

BASENAME="backup_www_html_${TIMESTAMP}"

ARCHIVE_PLAIN="${ARCHIVE_DIR}/${BASENAME}.tar.gz"
ARCHIVE_ENC="${ARCHIVE_DIR}/${BASENAME}.tar.gz.enc"
KEY_FILE="${KEY_DIR}/${BASENAME}.key"
LOG_FILE="${LOG_DIR}/${BASENAME}.log"

# ------------------------------------------------------------
# Fonction de journalisation
# ------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ------------------------------------------------------------
# Début
# ------------------------------------------------------------

log "============================================================"
log "Début de la sauvegarde"
log "Source : $SOURCE_DIR"
log "ID     : $BASENAME"
log "============================================================"

# ------------------------------------------------------------
# Génération d'une nouvelle clé AES-256
# ------------------------------------------------------------

log "Génération d'une nouvelle clé AES-256..."

openssl rand -base64 32 > "$KEY_FILE"

chmod 600 "$KEY_FILE"

log "Clé créée : $KEY_FILE"

# ------------------------------------------------------------
# Création de l'archive tar.gz
# ------------------------------------------------------------

log "Création de l'archive temporaire..."

tar -czf "$ARCHIVE_PLAIN" \
    -C "$(dirname "$SOURCE_DIR")" \
    "$(basename "$SOURCE_DIR")"

log "Archive temporaire créée : $ARCHIVE_PLAIN"
log "Taille : $(du -h "$ARCHIVE_PLAIN" | cut -f1)"

# ------------------------------------------------------------
# Chiffrement AES-256-CBC
# ------------------------------------------------------------

log "Chiffrement de l'archive..."

openssl enc \
    -aes-256-cbc \
    -salt \
    -pbkdf2 \
    -iter 100000 \
    -in "$ARCHIVE_PLAIN" \
    -out "$ARCHIVE_ENC" \
    -pass file:"$KEY_FILE"

chmod 600 "$ARCHIVE_ENC"

log "Archive chiffrée créée : $ARCHIVE_ENC"
log "Taille : $(du -h "$ARCHIVE_ENC" | cut -f1)"

# ------------------------------------------------------------
# Suppression UNIQUEMENT de l'archive temporaire en clair
# ------------------------------------------------------------

rm -f "$ARCHIVE_PLAIN"

log "Archive temporaire non chiffrée supprimée."

# ------------------------------------------------------------
# Vérification finale
# ------------------------------------------------------------

if [[ ! -f "$ARCHIVE_ENC" ]]; then
    log "[ERREUR] L'archive chiffrée n'existe pas."
    exit 1
fi

if [[ ! -f "$KEY_FILE" ]]; then
    log "[ERREUR] La clé n'existe pas."
    exit 1
fi

# ------------------------------------------------------------
# Fin
# ------------------------------------------------------------

log "============================================================"
log "Sauvegarde terminée avec succès"
log "Archive : $ARCHIVE_ENC"
log "Clé     : $KEY_FILE"
log "============================================================"

exit 0