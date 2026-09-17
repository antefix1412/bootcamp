#!/bin/bash

# ============================================================
# backup_www.sh
#
# Sauvegarde automatique et chiffrée de /var/www/html
#
# Fonctionnement :
# 1. Création d'une archive tar.gz
# 2. Calcul du SHA-256 AVANT chiffrement
# 3. Génération d'une nouvelle clé AES-256
# 4. Chiffrement de l'archive
# 5. Suppression de l'archive temporaire en clair
#
# Les archives, clés, hashes et logs sont conservés.
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

SOURCE_DIR="/var/www/html"

BACKUP_ROOT="/backup"

ARCHIVE_DIR="${BACKUP_ROOT}/archives"
KEY_DIR="${BACKUP_ROOT}/keys"
HASH_DIR="${BACKUP_ROOT}/hashes"
LOG_DIR="${BACKUP_ROOT}/logs"

# ------------------------------------------------------------
# Vérifications
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[ERREUR] Le script doit être exécuté avec sudo." >&2
    exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "[ERREUR] Le dossier $SOURCE_DIR n'existe pas." >&2
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "[ERREUR] openssl n'est pas installé." >&2
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "[ERREUR] tar n'est pas installé." >&2
    exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
    echo "[ERREUR] sha256sum n'est pas disponible." >&2
    exit 1
fi

# ------------------------------------------------------------
# Création des dossiers
# ------------------------------------------------------------

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$KEY_DIR"
mkdir -p "$HASH_DIR"
mkdir -p "$LOG_DIR"

chmod 700 "$BACKUP_ROOT"
chmod 700 "$ARCHIVE_DIR"
chmod 700 "$KEY_DIR"
chmod 700 "$HASH_DIR"
chmod 700 "$LOG_DIR"

# ------------------------------------------------------------
# Horodatage
# ------------------------------------------------------------

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

BASENAME="backup_www_html_${TIMESTAMP}"

ARCHIVE_PLAIN="${ARCHIVE_DIR}/${BASENAME}.tar.gz"
ARCHIVE_ENC="${ARCHIVE_DIR}/${BASENAME}.tar.gz.enc"

KEY_FILE="${KEY_DIR}/${BASENAME}.key"

HASH_FILE="${HASH_DIR}/${BASENAME}.sha256"

LOG_FILE="${LOG_DIR}/${BASENAME}.log"

# ------------------------------------------------------------
# Fonction de log
# ------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ------------------------------------------------------------
# Début
# ------------------------------------------------------------

log "============================================================"
log "DÉBUT DE LA SAUVEGARDE"
log "Source : $SOURCE_DIR"
log "ID     : $BASENAME"
log "============================================================"

# ------------------------------------------------------------
# Génération de la clé AES-256
# ------------------------------------------------------------

log "Génération d'une nouvelle clé AES-256..."

openssl rand -base64 32 > "$KEY_FILE"

chmod 600 "$KEY_FILE"

log "Clé créée : $KEY_FILE"

# ------------------------------------------------------------
# Création de l'archive temporaire
# ------------------------------------------------------------

log "Création de l'archive tar.gz..."

tar -czf "$ARCHIVE_PLAIN" \
    -C "$(dirname "$SOURCE_DIR")" \
    "$(basename "$SOURCE_DIR")"

log "Archive créée : $ARCHIVE_PLAIN"

# ------------------------------------------------------------
# Calcul du SHA-256 AVANT chiffrement
# ------------------------------------------------------------

log "Calcul du SHA-256 de l'archive AVANT chiffrement..."

sha256sum "$ARCHIVE_PLAIN" > "$HASH_FILE"

chmod 600 "$HASH_FILE"

HASH_VALUE=$(cut -d ' ' -f1 "$HASH_FILE")

log "SHA-256 : $HASH_VALUE"

log "Hash enregistré : $HASH_FILE"

# ------------------------------------------------------------
# Chiffrement AES-256-CBC
# ------------------------------------------------------------

log "Chiffrement AES-256-CBC..."

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

# ------------------------------------------------------------
# Vérification que le fichier chiffré existe
# ------------------------------------------------------------

if [[ ! -f "$ARCHIVE_ENC" ]]; then
    log "[ERREUR] L'archive chiffrée n'a pas été créée."
    exit 1
fi

# ------------------------------------------------------------
# Suppression de l'archive temporaire en clair
#
# C'est la SEULE suppression effectuée par le script.
# ------------------------------------------------------------

rm -f "$ARCHIVE_PLAIN"

log "Archive temporaire en clair supprimée."

# ------------------------------------------------------------
# Vérification finale
# ------------------------------------------------------------

if [[ -f "$ARCHIVE_ENC" && -f "$KEY_FILE" && -f "$HASH_FILE" ]]; then

    log "============================================================"
    log "SAUVEGARDE TERMINÉE AVEC SUCCÈS"
    log "Archive : $ARCHIVE_ENC"
    log "Clé     : $KEY_FILE"
    log "Hash    : $HASH_FILE"
    log "============================================================"

else

    log "[ERREUR] Un ou plusieurs fichiers de sauvegarde sont manquants."

    exit 1

fi

exit 0