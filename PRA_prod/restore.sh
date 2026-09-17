#!/bin/bash

# ============================================================
# restore_www.sh
#
# Restauration d'une sauvegarde chiffrée de /var/www/html
#
# Fonctionnement :
# 1. Sélection de l'archive
# 2. Recherche automatique de la clé correspondante
# 3. Recherche automatique du SHA-256 correspondant
# 4. Déchiffrement
# 5. Vérification du SHA-256
# 6. Restauration uniquement si le hash correspond
#
# Les sauvegardes existantes ne sont pas supprimées.
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

BACKUP_ROOT="/backup"

ARCHIVE_DIR="${BACKUP_ROOT}/archives"
KEY_DIR="${BACKUP_ROOT}/keys"
HASH_DIR="${BACKUP_ROOT}/hashes"

RESTORE_DIR="/var/www"

# ------------------------------------------------------------
# Vérifications
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[ERREUR] Le script doit être exécuté avec sudo."
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

if ! command -v sha256sum >/dev/null 2>&1; then
    echo "[ERREUR] sha256sum n'est pas disponible."
    exit 1
fi

if [[ ! -d "$ARCHIVE_DIR" ]]; then
    echo "[ERREUR] Le dossier $ARCHIVE_DIR n'existe pas."
    exit 1
fi

# ------------------------------------------------------------
# Recherche des archives
# ------------------------------------------------------------

clear

echo "============================================================"
echo "       RESTAURATION D'UNE SAUVEGARDE CHIFFRÉE"
echo "============================================================"
echo

mapfile -t ARCHIVES < <(
    ls -1t "${ARCHIVE_DIR}"/*.tar.gz.enc 2>/dev/null || true
)

if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
    echo "Aucune archive chiffrée trouvée."
    exit 1
fi

# ------------------------------------------------------------
# Affichage des archives
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

echo
echo "Archive sélectionnée :"
echo "$ARCHIVE_ENC"

# ------------------------------------------------------------
# Recherche de la clé correspondante
# ------------------------------------------------------------

KEY_FILE="${KEY_DIR}/${BASENAME}.key"

if [[ ! -f "$KEY_FILE" ]]; then

    echo
    echo "[ERREUR] La clé correspondante n'existe pas :"
    echo "$KEY_FILE"
    echo
    echo "Impossible de restaurer cette sauvegarde."

    exit 1

fi

echo
echo "Clé trouvée :"
echo "$KEY_FILE"

# ------------------------------------------------------------
# Recherche du hash correspondant
# ------------------------------------------------------------

HASH_FILE="${HASH_DIR}/${BASENAME}.sha256"

if [[ ! -f "$HASH_FILE" ]]; then

    echo
    echo "[ERREUR] Le hash correspondant n'existe pas :"
    echo "$HASH_FILE"
    echo
    echo "Impossible de vérifier l'intégrité de cette sauvegarde."

    exit 1

fi

echo
echo "Hash trouvé :"
echo "$HASH_FILE"

# ------------------------------------------------------------
# Fichier temporaire déchiffré
# ------------------------------------------------------------

ARCHIVE_PLAIN="/tmp/${BASENAME}.tar.gz"

# ------------------------------------------------------------
# Déchiffrement
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Déchiffrement..."
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
    echo "La clé est peut-être incorrecte."

    rm -f "$ARCHIVE_PLAIN"

    exit 1

fi

echo "Déchiffrement réussi."

# ------------------------------------------------------------
# Vérification SHA-256
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Vérification SHA-256..."
echo "============================================================"

if sha256sum -c "$HASH_FILE" 2>/dev/null; then

    echo
    echo "============================================================"
    echo "HASH CORRECT"
    echo "============================================================"
    echo
    echo "L'archive déchiffrée est identique à l'archive"
    echo "qui avait été créée avant le chiffrement."
    echo

else

    echo
    echo "============================================================"
    echo "ERREUR : HASH DIFFÉRENT"
    echo "============================================================"
    echo
    echo "L'archive déchiffrée ne correspond PAS au hash"
    echo "enregistré avant le chiffrement."
    echo
    echo "La restauration est ANNULÉE."
    echo

    rm -f "$ARCHIVE_PLAIN"

    exit 1

fi

# ------------------------------------------------------------
# Vérification supplémentaire de l'archive TAR
# ------------------------------------------------------------

echo "Vérification de l'archive TAR..."

if ! tar -tzf "$ARCHIVE_PLAIN" >/dev/null; then

    echo
    echo "[ERREUR] L'archive TAR est invalide."
    echo "La restauration est annulée."

    rm -f "$ARCHIVE_PLAIN"

    exit 1

fi

echo "Archive TAR valide."

# ------------------------------------------------------------
# Destination
# ------------------------------------------------------------

echo
echo "Destination de restauration :"
echo "$RESTORE_DIR"

# ------------------------------------------------------------
# Confirmation avant remplacement
# ------------------------------------------------------------

echo
echo "ATTENTION :"

if [[ -d "${RESTORE_DIR}/html" ]]; then

    echo "Le dossier suivant existe déjà :"
    echo "${RESTORE_DIR}/html"
    echo
    echo "Il sera déplacé en sauvegarde avant restauration."

else

    echo "Le dossier html n'existe pas actuellement."

fi

echo

read -rp "Continuer la restauration ? [o/N] : " CONFIRM

if [[ "${CONFIRM,,}" != "o" ]]; then

    echo "Restauration annulée."

    rm -f "$ARCHIVE_PLAIN"

    exit 0

fi

# ------------------------------------------------------------
# Sauvegarde de l'ancien dossier
# ------------------------------------------------------------

if [[ -d "${RESTORE_DIR}/html" ]]; then

    SAFE="${RESTORE_DIR}/html.bak.$(date '+%Y%m%d_%H%M%S')"

    echo
    echo "Ancien dossier déplacé vers :"
    echo "$SAFE"

    mv "${RESTORE_DIR}/html" "$SAFE"

fi

# ------------------------------------------------------------
# Extraction
# ------------------------------------------------------------

echo
echo "Extraction de la sauvegarde..."

tar -xzf "$ARCHIVE_PLAIN" -C "$RESTORE_DIR"

echo "Extraction terminée."

# ------------------------------------------------------------
# Permissions Apache
# ------------------------------------------------------------

if id www-data >/dev/null 2>&1; then

    echo
    echo "Application des permissions Apache..."

    chown -R www-data:www-data "${RESTORE_DIR}/html"

    find "${RESTORE_DIR}/html" \
        -type d \
        -exec chmod 755 {} \;

    find "${RESTORE_DIR}/html" \
        -type f \
        -exec chmod 644 {} \;

    echo "Permissions appliquées."

fi

# ------------------------------------------------------------
# Suppression du fichier temporaire
# ------------------------------------------------------------

rm -f "$ARCHIVE_PLAIN"

# ------------------------------------------------------------
# Fin
# ------------------------------------------------------------

echo
echo "============================================================"
echo "       RESTAURATION TERMINÉE AVEC SUCCÈS"
echo "============================================================"
echo
echo "Hash SHA-256 vérifié avec succès."
echo
echo "Contenu restauré dans :"
echo "${RESTORE_DIR}/html"
echo
echo "============================================================"

exit 0