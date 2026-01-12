#!/usr/bin/env bash
set -euo pipefail

CERT="${1:-certificate.crt}"
KEY="${2:-private.key}"
OUTDIR="${3:-ssl_out}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Falta '$1'"; exit 1; }; }

need openssl
need awk
need sed

if command -v curl >/dev/null 2>&1; then
  DL="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
  DL="wget -qO-"
else
  echo "❌ Necesitas curl o wget"
  exit 1
fi

[[ -f "$CERT" ]] || { echo "❌ No existe $CERT"; exit 1; }
[[ -f "$KEY"  ]] || { echo "❌ No existe $KEY";  exit 1; }

mkdir -p "$OUTDIR/tmp"

# Normalizar cert a PEM
openssl x509 -in "$CERT" -out "$OUTDIR/domain.crt"
cp "$KEY" "$OUTDIR/privkey.key"

cp "$OUTDIR/domain.crt" "$OUTDIR/domain.pem"
cp "$OUTDIR/privkey.key" "$OUTDIR/privkey.pem"

echo "📄 Certificado: $CERT"
echo "🔑 Clave:        $KEY"
echo "📦 Salida:       $OUTDIR"
echo

# Extraer AIA URLs
AIA="$OUTDIR/tmp/aia.txt"
openssl x509 -in "$OUTDIR/domain.crt" -noout -text \
| awk '
/Authority Information Access/ {f=1; next}
/X509v3/ {f=0}
f && /CA Issuers - URI:/ {
  gsub(/.*URI:/,""); print
}' > "$AIA" || true

CHAIN="$OUTDIR/chain.crt"
: > "$CHAIN"

CURRENT="$OUTDIR/domain.crt"
FOUND_CHAIN=0

is_self_signed() {
  [[ "$(openssl x509 -in "$1" -noout -issuer)" == \
     "$(openssl x509 -in "$1" -noout -subject)" ]]
}

for i in 1 2 3 4; do
  is_self_signed "$CURRENT" && break
  [[ -s "$AIA" ]] || break

  while read -r url; do
    echo "⬇️  Descargando CA intermedia: $url"
    if $DL "$url" > "$OUTDIR/tmp/issuer.bin"; then
      if openssl x509 -in "$OUTDIR/tmp/issuer.bin" -inform DER -out "$OUTDIR/tmp/issuer.pem" 2>/dev/null \
      || openssl x509 -in "$OUTDIR/tmp/issuer.bin" -out "$OUTDIR/tmp/issuer.pem" 2>/dev/null; then
        cat "$OUTDIR/tmp/issuer.pem" >> "$CHAIN"
        CURRENT="$OUTDIR/tmp/issuer.pem"
        FOUND_CHAIN=1
        break
      fi
    fi
  done < "$AIA"
done

if [[ $FOUND_CHAIN -eq 1 ]]; then
  cat "$OUTDIR/domain.crt" "$CHAIN" > "$OUTDIR/fullchain.crt"
else
  cp "$OUTDIR/domain.crt" "$OUTDIR/fullchain.crt"
  rm -f "$CHAIN"
fi

cp "$OUTDIR/fullchain.crt" "$OUTDIR/fullchain.pem"
[[ -f "$CHAIN" ]] && cp "$CHAIN" "$OUTDIR/chain.pem"

# ===== PFX MODERNO =====
echo
echo "🧾 Generando PFX moderno (Windows recientes)..."
if [[ -f "$OUTDIR/chain.crt" ]]; then
  openssl pkcs12 -export \
    -inkey "$OUTDIR/privkey.key" \
    -in "$OUTDIR/domain.crt" \
    -certfile "$OUTDIR/chain.crt" \
    -out "$OUTDIR/domain-modern.pfx"
else
  openssl pkcs12 -export \
    -inkey "$OUTDIR/privkey.key" \
    -in "$OUTDIR/domain.crt" \
    -out "$OUTDIR/domain-modern.pfx"
fi

# ===== PFX LEGACY =====
echo
echo "🧾 Generando PFX LEGACY (Windows Server 2016 y anteriores)..."
if [[ -f "$OUTDIR/chain.crt" ]]; then
  openssl pkcs12 -export -legacy \
    -inkey "$OUTDIR/privkey.key" \
    -in "$OUTDIR/domain.crt" \
    -certfile "$OUTDIR/chain.crt" \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -out "$OUTDIR/domain-legacy.pfx"
else
  openssl pkcs12 -export -legacy \
    -inkey "$OUTDIR/privkey.key" \
    -in "$OUTDIR/domain.crt" \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -out "$OUTDIR/domain-legacy.pfx"
fi

# ===== README CLARO PARA CLIENTE =====
cat > "$OUTDIR/README.txt" <<'EOF'
PAQUETE SSL – api.coalsa.rds.hn
========================================

Este paquete contiene todos los formatos necesarios para Linux y Windows (IIS).

----------------------------------------
ARCHIVOS INCLUIDOS
----------------------------------------

domain.crt
- Certificado del dominio (formato PEM)

privkey.key
- Clave privada del certificado
- CONFIDENCIAL: no compartir ni subir a repositorios

chain.crt
- Certificados intermedios (CA)
- Puede no existir si no fue posible reconstruir la cadena automáticamente

fullchain.crt
- domain.crt + chain.crt
- Recomendado para Nginx

*.pem
- Mismo contenido que los .crt/.key, solo cambia la extensión

domain-modern.pfx
- Para Windows Server modernos (2019, 2022)

domain-legacy.pfx
- Para Windows Server 2016 o anteriores
- Usar este si el moderno falla al importar

----------------------------------------
INSTALACIÓN EN LINUX
----------------------------------------

NGINX:
  ssl_certificate     fullchain.crt
  ssl_certificate_key privkey.key

APACHE:
  SSLCertificateFile      domain.crt
  SSLCertificateKeyFile   privkey.key
  SSLCertificateChainFile chain.crt

----------------------------------------
INSTALACIÓN EN WINDOWS (IIS)
----------------------------------------

1. Abrir "IIS Manager"
2. Seleccionar el servidor (no el sitio)
3. Abrir "Server Certificates"
4. Importar:
   - Usar domain-legacy.pfx si es Windows Server 2016 o anterior
   - Usar domain-modern.pfx si es Windows Server 2019+

5. Ingresar la contraseña usada al generar el PFX
6. Asignar el certificado al sitio HTTPS (Bindings → https → Edit)

----------------------------------------
NOTAS IMPORTANTES
----------------------------------------

- Si chain.crt no existe, es posible que el proveedor (CA)
  deba instalar los certificados intermedios manualmente.
- El certificado debe corresponder exactamente con la clave privada.
- Verificación recomendada:
  https://www.ssllabs.com/ssltest/

----------------------------------------
FIN
----------------------------------------
EOF

echo
echo "✅ Paquete generado correctamente:"
ls -la "$OUTDIR" | sed 's/^/  /'
