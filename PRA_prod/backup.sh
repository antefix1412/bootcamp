#!/bin/bash

# ============================================================
# backup_www.sh
#
# Sauvegarde automatique et chiffrée de /var/www/html
#
# Fonctionnement :
#
# 1. Création d'une archive .tar.gz
# 2. Calcul SHA-256 AVANT chiffrement
# 3. Génération d'une nouvelle clé AES-256
# 4. Chiffrement de l'archive
# 5. Calcul SHA-256 de l'archive chiffrée
# 6. Suppression de l'archive temporaire en clair
#
# Aucun menu interactif.
#
# Les fichiers suivants sont conservés :
# - archive chiffrée
# - clé
# - hash de l'archive avant chiffrement
# - hash de l'archive chiffrée
# - log
#
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Empêcher deux sauvegardes de tourner simultanément
# ------------------------------------------------------------

LOCK_FILE="/var/run/backup_www.lock"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    exit 0
fi

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
# Vérification des commandes
# ------------------------------------------------------------

for COMMAND in openssl tar sha256sum flock; do
    if ! command -v "$COMMAND" >/dev/null 2>&1; then
        echo "[ERREUR] La commande '$COMMAND' n'est pas disponible." >&2
        exit 1
    fi
done

# ------------------------------------------------------------
# Création des dossiers
# ------------------------------------------------------------

mkdir -p "$BACKUP_ROOT"
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

# Hash de l'archive AVANT chiffrement
HASH_FILE="${HASH_DIR}/${BASENAME}.sha256"

# Hash de l'archive APRÈS chiffrement
ENC_HASH_FILE="${HASH_DIR}/${BASENAME}.enc.sha256"

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

log "Archive temporaire créée : $ARCHIVE_PLAIN"

# ------------------------------------------------------------
# Hash SHA-256 AVANT chiffrement
# ------------------------------------------------------------

log "Calcul du SHA-256 AVANT chiffrement..."

sha256sum "$ARCHIVE_PLAIN" | awk '{print $1}' > "$HASH_FILE"

chmod 600 "$HASH_FILE"

HASH_VALUE=$(cat "$HASH_FILE")

log "SHA-256 avant chiffrement : $HASH_VALUE"
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
# Hash SHA-256 APRÈS chiffrement
# ------------------------------------------------------------

log "Calcul du SHA-256 de l'archive chiffrée..."

sha256sum "$ARCHIVE_ENC" | awk '{print $1}' > "$ENC_HASH_FILE"

chmod 600 "$ENC_HASH_FILE"

ENC_HASH_VALUE=$(cat "$ENC_HASH_FILE")

log "SHA-256 archive chiffrée : $ENC_HASH_VALUE"
log "Hash enregistré : $ENC_HASH_FILE"

# ------------------------------------------------------------
# Vérification des fichiers importants
# ------------------------------------------------------------

if [[ ! -f "$ARCHIVE_ENC" ]]; then
    log "[ERREUR] Archive chiffrée absente."
    exit 1
fi

if [[ ! -f "$KEY_FILE" ]]; then
    log "[ERREUR] Clé absente."
    exit 1
fi

if [[ ! -f "$HASH_FILE" ]]; then
    log "[ERREUR] Hash avant chiffrement absent."
    exit 1
fi

if [[ ! -f "$ENC_HASH_FILE" ]]; then
    log "[ERREUR] Hash après chiffrement absent."
    exit 1
fi

# ------------------------------------------------------------
# Suppression UNIQUEMENT de l'archive temporaire en clair
# ------------------------------------------------------------

rm -f "$ARCHIVE_PLAIN"

log "Archive temporaire en clair supprimée."

# ------------------------------------------------------------
# Fin
# ------------------------------------------------------------

log "============================================================"
log "SAUVEGARDE TERMINÉE AVEC SUCCÈS"
log "Archive chiffrée : $ARCHIVE_ENC"
log "Clé              : $KEY_FILE"
log "Hash avant       : $HASH_FILE"
log "Hash chiffré      : $ENC_HASH_FILE"
log "============================================================"

exit 0