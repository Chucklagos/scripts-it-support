#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Generador genérico de llave privada + CSR con SAN
#
# Uso:
#   ./generar_csr.sh
#
# El script te irá preguntando:
#   - Prefijo de archivos
#   - CN (dominio principal)
#   - SANs (DNS) adicionales
#   - Datos de la organización (C, ST, L, O, OU, email)
#
# Salida:
#   <prefijo>.key  -> llave privada
#   <prefijo>.csr  -> CSR para enviar a la CA
#   <prefijo>-csr.conf -> config usada por openssl
# ============================================

echo "=== Generador de CSR (llave + solicitud de certificado) ==="
echo

read -rp "Prefijo para los archivos (ej: mi_dominio): " PREFIX
if [[ -z "$PREFIX" ]]; then
  echo "ERROR: El prefijo no puede estar vacío."
  exit 1
fi

KEY_FILE="${PREFIX}.key"
CSR_FILE="${PREFIX}.csr"
CONF_FILE="${PREFIX}-csr.conf"

echo
echo "=== Datos del certificado ==="
read -rp "Common Name (CN) - dominio principal (ej: ejemplo.com o *.ejemplo.com): " CN

if [[ -z "$CN" ]]; then
  echo "ERROR: El CN no puede estar vacío."
  exit 1
fi

echo
echo "Subject Alternative Names (SANs)"
echo "Ejemplo: *.ejemplo.com,ejemplo.com,api.ejemplo.com"
read -rp "Lista de SANs (separadas por coma, dejar vacío para usar solo el CN): " SANS_RAW

if [[ -z "$SANS_RAW" ]]; then
  SANS_RAW="$CN"
fi

echo
echo "=== Datos de organización (puedes dejar en blanco si no aplican) ==="
read -rp "País (C)               [ej: HN]: " COUNTRY
read -rp "Estado/Provincia (ST)  [ej: Francisco Morazan]: " STATE
read -rp "Ciudad/Localidad (L)   [ej: Tegucigalpa]: " LOCALITY
read -rp "Organización (O)       [ej: Mi Empresa S.A.]: " ORG
read -rp "Unidad Organizativa(OU)[ej: IT]: " ORG_UNIT
read -rp "Email (emailAddress)   [ej: admin@ejemplo.com]: " EMAIL

COUNTRY=${COUNTRY:-HN}
STATE=${STATE:-.}
LOCALITY=${LOCALITY:-.}
ORG=${ORG:-.}
ORG_UNIT=${ORG_UNIT:-.}
EMAIL=${EMAIL:-admin@example.com}

echo
echo "Resumen:"
echo "  CN  = ${CN}"
echo "  SAN = ${SANS_RAW}"
echo "  C   = ${COUNTRY}"
echo "  ST  = ${STATE}"
echo "  L   = ${LOCALITY}"
echo "  O   = ${ORG}"
echo "  OU  = ${ORG_UNIT}"
echo "  email = ${EMAIL}"
echo

read -rp "¿Continuar y generar llave + CSR con estos datos? [s/N]: " CONFIRM
CONFIRM=${CONFIRM:-N}
if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
  echo "Cancelado."
  exit 0
fi

# Construir lista SAN en formato openssl
SAN_LINES=""
IFS=',' read -ra SAN_ARR <<< "$SANS_RAW"
IDX=1
for san in "${SAN_ARR[@]}"; do
  SAN_LINES+="DNS.${IDX} = ${san}\n"
  ((IDX++))
done

cat > "$CONF_FILE" <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = v3_req

[ dn ]
C  = ${COUNTRY}
ST = ${STATE}
L  = ${LOCALITY}
O  = ${ORG}
OU = ${ORG_UNIT}
CN = ${CN}
emailAddress = ${EMAIL}

[ v3_req ]
subjectAltName = @alt_names

[ alt_names ]
$(printf "${SAN_LINES}")
EOF

echo "Archivo de configuración de CSR creado: $CONF_FILE"
echo

echo "Generando llave privada (${KEY_FILE}) y CSR (${CSR_FILE})..."
openssl req -new -nodes \
  -config "$CONF_FILE" \
  -keyout "$KEY_FILE" \
  -out "$CSR_FILE"

echo
echo "Listo."
echo "  Llave privada : $KEY_FILE"
echo "  CSR           : $CSR_FILE"
echo
echo "Vista rápida del CSR:"
openssl req -in "$CSR_FILE" -noout -subject -text | sed -n '1,12p'
echo
echo "Envía el archivo ${CSR_FILE} a tu Autoridad Certificadora (CA) para emitir el certificado."
