#!/bin/bash

# ============================================================
# backup_www.sh
# Sauvegarde chiffrée de /var/www/html
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
# Fonctions
# ------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

die() {
    echo "[ERREUR] $*" >&2
    exit 1
}

# ------------------------------------------------------------
# Vérifications
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    die "Ce script doit être exécuté avec sudo."
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    die "Le dossier $SOURCE_DIR n'existe pas."
fi

if ! command -v openssl >/dev/null 2>&1; then
    die "openssl n'est pas installé."
fi

if ! command -v tar >/dev/null 2>&1; then
    die "tar n'est pas installé."
fi

# ------------------------------------------------------------
# Création des dossiers
# ------------------------------------------------------------

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$KEY_DIR"
mkdir -p "$LOG_DIR"

chmod 700 "$BACKUP_ROOT"
chmod 700 "$ARCHIVE_DIR"
chmod 700 "$KEY_DIR"
chmod 700 "$LOG_DIR"

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

clear

echo "============================================================"
echo "        SAUVEGARDE CHIFFRÉE DE /var/www/html"
echo "============================================================"
echo
echo "1) Sauvegarde complète"
echo "2) Sauvegarde + suppression de la clé"
echo "3) Quitter"
echo
echo "============================================================"

read -rp "Votre choix [1-3] : " CHOICE

case "$CHOICE" in

    1)
        DELETE_KEY_AFTER=0
        ;;

    2)
        DELETE_KEY_AFTER=1
        ;;

    3)
        echo "Annulé."
        exit 0
        ;;

    *)
        die "Choix invalide."
        ;;

esac

# ------------------------------------------------------------
# Noms des fichiers
# ------------------------------------------------------------

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

BASENAME="backup_www_html_${TIMESTAMP}"

ARCHIVE_PLAIN="${ARCHIVE_DIR}/${BASENAME}.tar.gz"
ARCHIVE_ENC="${ARCHIVE_DIR}/${BASENAME}.tar.gz.enc"
KEY_FILE="${KEY_DIR}/${BASENAME}.key"
LOG_FILE="${LOG_DIR}/${BASENAME}.log"

# ------------------------------------------------------------
# Début
# ------------------------------------------------------------

log "============================================================"
log "Début de la sauvegarde"
log "Sauvegarde : $BASENAME"
log "Source     : $SOURCE_DIR"
log "============================================================"

# ------------------------------------------------------------
# Génération de la clé AES-256
# ------------------------------------------------------------

log "Génération de la clé de chiffrement..."

openssl rand -base64 32 > "$KEY_FILE"

chmod 600 "$KEY_FILE"

log "Clé créée : $KEY_FILE"

# ------------------------------------------------------------
# Création de l'archive
# ------------------------------------------------------------

log "Création de l'archive..."

tar -czf "$ARCHIVE_PLAIN" \
    -C "$(dirname "$SOURCE_DIR")" \
    "$(basename "$SOURCE_DIR")"

log "Archive créée : $ARCHIVE_PLAIN"
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

log "Archive chiffrée : $ARCHIVE_ENC"
log "Taille : $(du -h "$ARCHIVE_ENC" | cut -f1)"

# ------------------------------------------------------------
# Suppression de l'archive en clair
# ------------------------------------------------------------

rm -f "$ARCHIVE_PLAIN"

log "Archive non chiffrée supprimée."

# ------------------------------------------------------------
# Option : suppression de la clé
# ------------------------------------------------------------

if [[ "$DELETE_KEY_AFTER" -eq 1 ]]; then

    echo
    echo "============================================================"
    echo "ATTENTION"
    echo "============================================================"
    echo
    echo "La clé suivante va être supprimée :"
    echo
    cat "$KEY_FILE"
    echo
    echo "============================================================"
    echo

    read -rp "Avez-vous sauvegardé cette clé ailleurs ? [o/N] : " CONFIRM

    if [[ "${CONFIRM,,}" == "o" ]]; then

        shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"

        log "Clé supprimée du serveur."

    else

        log "Clé conservée sur le serveur."

    fi

fi

# ------------------------------------------------------------
# Fin
# ------------------------------------------------------------

log "============================================================"
log "SAUVEGARDE TERMINÉE AVEC SUCCÈS"
log "============================================================"

echo
echo "============================================================"
echo "          SAUVEGARDE TERMINÉE"
echo "============================================================"
echo
echo "Archive chiffrée :"
echo "$ARCHIVE_ENC"
echo
echo "Clé :"
if [[ -f "$KEY_FILE" ]]; then
    echo "$KEY_FILE"
else
    echo "Clé supprimée du serveur."
fi
echo
echo "Log :"
echo "$LOG_FILE"
echo
echo "============================================================"