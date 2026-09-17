#!/bin/bash

# ============================================================
# restore_www.sh
#
# Restauration d'une sauvegarde chiffrée de /var/www/html
#
# Vérifications :
#
# 1. Hash SHA-256 de l'archive chiffrée
# 2. Déchiffrement
# 3. Hash SHA-256 de l'archive originale
# 4. Vérification de l'archive TAR
# 5. Restauration
#
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
# Vérification root
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[ERREUR] Le script doit être exécuté avec sudo."
    exit 1
fi

# ------------------------------------------------------------
# Vérification des commandes
# ------------------------------------------------------------

for COMMAND in openssl tar sha256sum; do
    if ! command -v "$COMMAND" >/dev/null 2>&1; then
        echo "[ERREUR] La commande '$COMMAND' n'est pas disponible."
        exit 1
    fi
done

# ------------------------------------------------------------
# Vérification des dossiers
# ------------------------------------------------------------

if [[ ! -d "$ARCHIVE_DIR" ]]; then
    echo "[ERREUR] Le dossier $ARCHIVE_DIR n'existe pas."
    exit 1
fi

if [[ ! -d "$KEY_DIR" ]]; then
    echo "[ERREUR] Le dossier $KEY_DIR n'existe pas."
    exit 1
fi

if [[ ! -d "$HASH_DIR" ]]; then
    echo "[ERREUR] Le dossier $HASH_DIR n'existe pas."
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
# Recherche de la clé
# ------------------------------------------------------------

KEY_FILE="${KEY_DIR}/${BASENAME}.key"

if [[ ! -f "$KEY_FILE" ]]; then

    echo
    echo "[ERREUR] Clé correspondante introuvable :"
    echo "$KEY_FILE"

    exit 1

fi

echo
echo "Clé trouvée :"
echo "$KEY_FILE"

# ------------------------------------------------------------
# Recherche du hash AVANT chiffrement
# ------------------------------------------------------------

HASH_FILE="${HASH_DIR}/${BASENAME}.sha256"

if [[ ! -f "$HASH_FILE" ]]; then

    echo
    echo "[ERREUR] Hash original introuvable :"
    echo "$HASH_FILE"

    exit 1

fi

echo
echo "Hash original trouvé :"
echo "$HASH_FILE"

# ------------------------------------------------------------
# Recherche du hash de l'archive chiffrée
# ------------------------------------------------------------

ENC_HASH_FILE="${HASH_DIR}/${BASENAME}.enc.sha256"

if [[ ! -f "$ENC_HASH_FILE" ]]; then

    echo
    echo "[ERREUR] Hash de l'archive chiffrée introuvable :"
    echo "$ENC_HASH_FILE"
    echo
    echo "Cette sauvegarde ne peut pas être vérifiée."
    echo "La restauration est annulée."

    exit 1

fi

echo
echo "Hash de l'archive chiffrée trouvé :"
echo "$ENC_HASH_FILE"

# ------------------------------------------------------------
# Vérification du hash de l'archive CHIFFRÉE
#
# Cette étape ne déchiffre absolument rien.
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Vérification de l'intégrité de l'archive chiffrée..."
echo "============================================================"

EXPECTED_ENC_HASH=$(awk '{print $1}' "$ENC_HASH_FILE")

ACTUAL_ENC_HASH=$(sha256sum "$ARCHIVE_ENC" | awk '{print $1}')

echo
echo "Hash enregistré :"
echo "$EXPECTED_ENC_HASH"

echo
echo "Hash actuel :"
echo "$ACTUAL_ENC_HASH"

echo

if [[ "$EXPECTED_ENC_HASH" != "$ACTUAL_ENC_HASH" ]]; then

    echo "============================================================"
    echo "ERREUR : ARCHIVE CHIFFRÉE MODIFIÉE OU CORROMPUE"
    echo "============================================================"
    echo
    echo "Le hash de l'archive chiffrée ne correspond pas."
    echo
    echo "La restauration est ANNULÉE."

    exit 1

fi

echo "Hash de l'archive chiffrée : OK"

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

    rm -f "$ARCHIVE_PLAIN"

    exit 1

fi

echo "Déchiffrement réussi."

# ------------------------------------------------------------
# Vérification SHA-256 AVANT chiffrement
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Vérification SHA-256 de l'archive originale..."
echo "============================================================"

EXPECTED_HASH=$(awk '{print $1}' "$HASH_FILE")

ACTUAL_HASH=$(sha256sum "$ARCHIVE_PLAIN" | awk '{print $1}')

echo
echo "Hash enregistré AVANT chiffrement :"
echo "$EXPECTED_HASH"

echo
echo "Hash après déchiffrement :"
echo "$ACTUAL_HASH"

echo

if [[ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then

    echo "============================================================"
    echo "ERREUR : HASH DIFFÉRENT"
    echo "============================================================"
    echo
    echo "L'archive déchiffrée ne correspond pas"
    echo "à l'archive créée avant le chiffrement."
    echo
    echo "La restauration est ANNULÉE."

    rm -f "$ARCHIVE_PLAIN"

    exit 1

fi

echo "Hash de l'archive originale : OK"

# ------------------------------------------------------------
# Vérification supplémentaire de l'archive TAR
# ------------------------------------------------------------

echo
echo "Vérification de l'intégrité de l'archive TAR..."

if ! tar -tzf "$ARCHIVE_PLAIN" >/dev/null; then

    echo
    echo "[ERREUR] L'archive TAR est invalide."
    echo
    echo "La restauration est ANNULÉE."

    rm -f "$ARCHIVE_PLAIN"

    exit 1

fi

echo "Archive TAR valide."

# ------------------------------------------------------------
# Destination
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Destination :"
echo "$RESTORE_DIR/html"
echo "============================================================"

# ------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------

echo

if [[ -d "${RESTORE_DIR}/html" ]]; then

    echo "ATTENTION :"
    echo
    echo "Le dossier actuel :"
    echo "${RESTORE_DIR}/html"
    echo
    echo "sera déplacé avant la restauration."

else

    echo "Le dossier ${RESTORE_DIR}/html n'existe pas actuellement."

fi

echo

read -rp "Continuer la restauration ? [o/N] : " CONFIRM

if [[ "${CONFIRM,,}" != "o" ]]; then

    echo
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
# Suppression du fichier temporaire déchiffré
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
echo "✓ Hash de l'archive chiffrée vérifié"
echo "✓ Déchiffrement réussi"
echo "✓ Hash de l'archive originale vérifié"
echo "✓ Archive TAR vérifiée"
echo "✓ Restauration effectuée"
echo
echo "Contenu restauré dans :"
echo "${RESTORE_DIR}/html"
echo
echo "============================================================"

exit 0