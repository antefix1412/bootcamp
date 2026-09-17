#!/bin/bash

# ============================================================
# restore_www.sh
# Déchiffrement + restauration de /var/www/html
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

BACKUP_ROOT="/backup"

ARCHIVE_DIR="${BACKUP_ROOT}/archives"
KEY_DIR="${BACKUP_ROOT}/keys"

RESTORE_DIR="/var/www"

# ------------------------------------------------------------
# Vérifications
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[ERREUR] Ce script doit être exécuté avec sudo."
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "[ERREUR] openssl n'est pas installé."
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "[ERREUR] tar n'est pas installé."
    exit 1
fi

if [[ ! -d "$ARCHIVE_DIR" ]]; then
    echo "[ERREUR] Le dossier $ARCHIVE_DIR n'existe pas."
    exit 1
fi

# ------------------------------------------------------------
# Recherche des sauvegardes
# ------------------------------------------------------------

clear

echo "============================================================"
echo "          RESTAURATION D'UNE SAUVEGARDE"
echo "============================================================"
echo
echo "Archives disponibles :"
echo

mapfile -t ARCHIVES < <(
    ls -1t "${ARCHIVE_DIR}"/*.tar.gz.enc 2>/dev/null || true
)

if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
    echo "Aucune sauvegarde trouvée."
    exit 1
fi

# ------------------------------------------------------------
# Affichage des sauvegardes
# ------------------------------------------------------------

for i in "${!ARCHIVES[@]}"; do

    FILE="${ARCHIVES[$i]}"

    SIZE=$(du -h "$FILE" | cut -f1)

    DATE=$(date -r "$FILE" '+%Y-%m-%d %H:%M:%S')

    printf "  %2d) %-50s (%s, %s)\n" \
        "$((i + 1))" \
        "$(basename "$FILE")" \
        "$SIZE" \
        "$DATE"

done

echo
echo "============================================================"

read -rp "Numéro de la sauvegarde à restaurer (q pour quitter) : " SEL

if [[ "$SEL" == "q" ]]; then
    exit 0
fi

if ! [[ "$SEL" =~ ^[0-9]+$ ]]; then
    echo "[ERREUR] Choix invalide."
    exit 1
fi

if (( SEL < 1 || SEL > ${#ARCHIVES[@]} )); then
    echo "[ERREUR] Choix invalide."
    exit 1
fi

# ------------------------------------------------------------
# Sélection de l'archive
# ------------------------------------------------------------

ARCHIVE_ENC="${ARCHIVES[$((SEL - 1))]}"

BASENAME=$(basename "$ARCHIVE_ENC" .tar.gz.enc)

KEY_FILE="${KEY_DIR}/${BASENAME}.key"

ARCHIVE_PLAIN="/tmp/${BASENAME}.tar.gz"

CLEANUP_KEY=0

echo
echo "Archive sélectionnée :"
echo "$ARCHIVE_ENC"

# ------------------------------------------------------------
# Recherche de la clé
# ------------------------------------------------------------

echo

if [[ -f "$KEY_FILE" ]]; then

    echo "Clé trouvée automatiquement :"
    echo "$KEY_FILE"
    echo

    read -rp "Utiliser cette clé ? [O/n] : " USE_KEY

    if [[ "${USE_KEY,,}" == "n" ]]; then
        KEY_FILE=""
    fi

fi

# ------------------------------------------------------------
# Demande manuelle de la clé
# ------------------------------------------------------------

if [[ -z "${KEY_FILE:-}" || ! -f "$KEY_FILE" ]]; then

    echo
    echo "La clé n'a pas été trouvée automatiquement."
    echo
    echo "Entrez la clé de déchiffrement :"

    read -r MANUAL_KEY

    if [[ -z "$MANUAL_KEY" ]]; then
        echo "[ERREUR] Clé vide."
        exit 1
    fi

    TMP_KEY=$(mktemp)

    chmod 600 "$TMP_KEY"

    echo "$MANUAL_KEY" > "$TMP_KEY"

    KEY_FILE="$TMP_KEY"

    CLEANUP_KEY=1

fi

# ------------------------------------------------------------
# Déchiffrement
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Déchiffrement de l'archive..."
echo "============================================================"

if ! openssl enc \
    -d \
    -aes-256-cbc \
    -pbkdf2 \
    -iter 100000 \
    -in "$ARCHIVE_ENC" \
    -out "$ARCHIVE_PLAIN" \
    -pass file:"$KEY_FILE"
then

    echo
    echo "[ERREUR] Le déchiffrement a échoué."
    echo "La clé est probablement incorrecte."

    rm -f "$ARCHIVE_PLAIN"

    if [[ "$CLEANUP_KEY" -eq 1 ]]; then
        rm -f "$KEY_FILE"
    fi

    exit 1

fi

echo
echo "Déchiffrement réussi."
echo "Archive temporaire : $ARCHIVE_PLAIN"

# ------------------------------------------------------------
# Vérification de l'archive
# ------------------------------------------------------------

echo
echo "Vérification de l'archive..."

if ! tar -tzf "$ARCHIVE_PLAIN" >/dev/null; then

    echo "[ERREUR] L'archive est invalide."

    rm -f "$ARCHIVE_PLAIN"

    if [[ "$CLEANUP_KEY" -eq 1 ]]; then
        rm -f "$KEY_FILE"
    fi

    exit 1

fi

echo "Archive valide."

# ------------------------------------------------------------
# Choix du dossier de restauration
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Destination de restauration"
echo "============================================================"
echo
echo "Par défaut : $RESTORE_DIR"
echo

read -rp "Restaurer dans [$RESTORE_DIR] ? (Entrée = oui) : " DEST

DEST="${DEST:-$RESTORE_DIR}"

# ------------------------------------------------------------
# Vérification destination
# ------------------------------------------------------------

if [[ ! -d "$DEST" ]]; then

    echo
    echo "Le dossier $DEST n'existe pas."

    read -rp "Créer ce dossier ? [o/N] : " CREATE_DEST

    if [[ "${CREATE_DEST,,}" == "o" ]]; then
        mkdir -p "$DEST"
    else
        echo "Annulé."

        rm -f "$ARCHIVE_PLAIN"

        if [[ "$CLEANUP_KEY" -eq 1 ]]; then
            rm -f "$KEY_FILE"
        fi

        exit 0
    fi

fi

# ------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------

echo
echo "============================================================"
echo "ATTENTION"
echo "============================================================"
echo
echo "La restauration va remplacer :"
echo
echo "$DEST/html"
echo

if [[ -d "${DEST}/html" ]]; then

    echo "Le dossier html existe actuellement."
    echo "Il sera déplacé en sauvegarde avant restauration."

fi

echo
read -rp "Continuer ? [o/N] : " CONFIRM

if [[ "${CONFIRM,,}" != "o" ]]; then

    echo "Restauration annulée."

    rm -f "$ARCHIVE_PLAIN"

    if [[ "$CLEANUP_KEY" -eq 1 ]]; then
        rm -f "$KEY_FILE"
    fi

    exit 0

fi

# ------------------------------------------------------------
# Sauvegarde de l'ancien dossier
# ------------------------------------------------------------

if [[ -d "${DEST}/html" ]]; then

    SAFE="${DEST}/html.bak.$(date '+%Y%m%d_%H%M%S')"

    echo
    echo "Ancien dossier html :"
    echo "$DEST/html"

    echo
    echo "Déplacement vers :"
    echo "$SAFE"

    mv "${DEST}/html" "$SAFE"

fi

# ------------------------------------------------------------
# Extraction
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Extraction de la sauvegarde..."
echo "============================================================"

tar -xzf "$ARCHIVE_PLAIN" -C "$DEST"

echo "Extraction terminée."

# ------------------------------------------------------------
# Permissions Apache
# ------------------------------------------------------------

if id www-data >/dev/null 2>&1; then

    echo
    echo "Application des permissions Apache..."

    chown -R www-data:www-data "${DEST}/html"

    find "${DEST}/html" \
        -type d \
        -exec chmod 755 {} \;

    find "${DEST}/html" \
        -type f \
        -exec chmod 644 {} \;

    echo "Permissions appliquées."

fi

# ------------------------------------------------------------
# Nettoyage
# ------------------------------------------------------------

rm -f "$ARCHIVE_PLAIN"

if [[ "$CLEANUP_KEY" -eq 1 ]]; then
    rm -f "$KEY_FILE"
fi

# ------------------------------------------------------------
# Fin
# ------------------------------------------------------------

echo
echo "============================================================"
echo "       RESTAURATION TERMINÉE AVEC SUCCÈS"
echo "============================================================"
echo
echo "Contenu restauré dans :"
echo "$DEST/html"
echo
echo "============================================================"