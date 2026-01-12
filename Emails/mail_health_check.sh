#!/usr/bin/env bash

# Script para revisar "salud" básica de un correo y su dominio
# - Analiza dominio del correo
# - MX, SPF, DMARC
# - IPs y reverse DNS
# - Chequeo simple de blacklists (DNSBL)
# - Prueba rápida de conexión SMTP
#
# Requisitos:
#   - dig
#   - nc (netcat) para prueba SMTP (opcional pero recomendado)
#   - whois (opcional, solo para info adicional de IP)

########################################
# 0. COMPROBAR DEPENDENCIAS
########################################

for cmd in dig; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' no está instalado."
        echo "En Debian/Ubuntu: sudo apt-get install dnsutils"
        exit 1
    fi
done

HAS_NC=1
if ! command -v nc >/dev/null 2>&1; then
    HAS_NC=0
fi

HAS_WHOIS=1
if ! command -v whois >/dev/null 2>&1; then
    HAS_WHOIS=0
fi

########################################
# 1. PEDIR CORREO
########################################

echo "======================================"
echo "  Comprobación de salud de un correo"
echo "======================================"
read -rp "Introduce la dirección de correo (usuario@dominio.com): " email

email="$(echo "$email" | tr -d '[:space:]')"

if [[ -z "$email" ]]; then
    echo "No has introducido nada. Saliendo."
    exit 1
fi

# Validación sencilla de formato
if ! [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo "Formato de correo no parece válido: $email"
    # seguimos, pero avisamos
fi

user_part="${email%@*}"
domain="${email##*@}"

if [[ -z "$domain" ]]; then
    echo "No se pudo extraer el dominio del correo. Saliendo."
    exit 1
fi

########################################
# 2. ARCHIVO DE SALIDA
########################################

timestamp="$(date +%Y%m%d_%H%M%S)"
outfile="mail_health_${domain}_${timestamp}.txt"

sep() {
    local title="$1"
    echo
    echo "========== $title =========="
}

{
    echo "======================================"
    echo "  INFORME DE SALUD DE CORREO"
    echo "======================================"
    echo "Correo:  $email"
    echo "Usuario: $user_part"
    echo "Dominio: $domain"
    echo "Fecha:   $(date)"
    echo "Archivo: $outfile"
    echo "======================================"
    echo
} | tee "$outfile"

########################################
# 3. DNS DEL DOMINIO (MX, A)
########################################

sep "Registros MX del dominio" | tee -a "$outfile"
dig +nocmd "$domain" MX +noall +answer | tee -a "$outfile"

# Obtener MX en formato simple (hostnames)
mapfile -t mx_list < <(dig +short "$domain" MX | awk '{print $2}' | sed 's/\.$//')

sep "IPs de los servidores MX" | tee -a "$outfile"

all_ips=()

if [[ ${#mx_list[@]} -eq 0 ]]; then
    echo "No se encontraron MX. Se usará el propio dominio para intentar obtener IPs." | tee -a "$outfile"
    mapfile -t all_ips < <( (dig +short "$domain" A; dig +short "$domain" AAAA) | sort -u )
else
    for mx in "${mx_list[@]}"; do
        echo "MX: $mx" | tee -a "$outfile"
        ips_mx=$( (dig +short "$mx" A; dig +short "$mx" AAAA) | sort -u )
        if [[ -z "$ips_mx" ]]; then
            echo "  (Sin IPs A/AAAA para $mx)" | tee -a "$outfile"
        else
            while IFS= read -r ip; do
                echo "  IP: $ip" | tee -a "$outfile"
                all_ips+=("$ip")
            done <<< "$ips_mx"
        fi
    done
fi

# Quitar duplicados de all_ips
if [[ ${#all_ips[@]} -gt 0 ]]; then
    mapfile -t all_ips < <(printf "%s\n" "${all_ips[@]}" | sort -u)
fi

########################################
# 4. SPF Y DMARC
########################################

sep "SPF (TXT con v=spf1)" | tee -a "$outfile"
dig +short "$domain" TXT | grep -i "v=spf1" | tee -a "$outfile"

sep "DMARC (_dmarc.$domain)" | tee -a "$outfile"
dig +short "_dmarc.$domain" TXT | tee -a "$outfile"

########################################
# 5. REVERSE DNS E INFO BÁSICA DE IP
########################################

sep "Información básica de IPs (reverse DNS)" | tee -a "$outfile"

if [[ ${#all_ips[@]} -eq 0 ]]; then
    echo "No se encontraron IPs para analizar." | tee -a "$outfile"
else
    for ip in "${all_ips[@]}"; do
        {
            echo "--------------------------------------"
            echo "IP: $ip"
            echo "Reverse DNS:"
            dig -x "$ip" +short
            if [[ $HAS_WHOIS -eq 1 ]]; then
                echo
                echo "Resumen WHOIS (organización / netname):"
                whois "$ip" 2>/dev/null | grep -iE 'OrgName|org-name|descr|netname' | head -n 10
            fi
            echo
        } | tee -a "$outfile"
    done
fi

########################################
# 6. CHEQUEO DE BLACKLISTS (DNSBL)
########################################

# Algunas listas DNSBL comunes
dnsbls=(
    "zen.spamhaus.org"
    "bl.spamcop.net"
    "dnsbl.sorbs.net"
)

sep "Revisión rápida de blacklists (DNSBL)" | tee -a "$outfile"

if [[ ${#all_ips[@]} -eq 0 ]]; then
    echo "No hay IPs para comprobar en DNSBL." | tee -a "$outfile"
else
    for ip in "${all_ips[@]}"; do
        echo "--------------------------------------" | tee -a "$outfile"
        echo "IP: $ip" | tee -a "$outfile"

        # Solo para IPv4 (para simplificar)
        if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "  (IP no IPv4, se omite de DNSBL en este script)" | tee -a "$outfile"
            continue
        fi

        # Revertir IP (1.2.3.4 => 4.3.2.1)
        rev_ip=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')

        for bl in "${dnsbls[@]}"; do
            query="${rev_ip}.${bl}"
            result=$(dig +short "$query" A)

            if [[ -n "$result" ]]; then
                echo "  [LISTADO] $bl -> $result" | tee -a "$outfile"
            else
                echo "  [OK]      $bl (no listado)" | tee -a "$outfile"
            fi
        done
    done
fi

########################################
# 7. PRUEBA RÁPIDA DE SMTP
########################################

sep "Prueba básica de conexión SMTP (puerto 25)" | tee -a "$outfile"

if [[ $HAS_NC -eq 0 ]]; then
    echo "nc (netcat) no está instalado, no se puede probar conexión SMTP." | tee -a "$outfile"
    echo "En Debian/Ubuntu: sudo apt-get install netcat-openbsd" | tee -a "$outfile"
else
    targets=()
    if [[ ${#mx_list[@]} -gt 0 ]]; then
        targets=("${mx_list[@]}")
    else
        targets=("$domain")
    fi

    for host in "${targets[@]}"; do
        {
            echo "Probando $host:25 ..."
            # Timeout de 5 segundos
            (echo -e "QUIT\r\n" | nc -w 5 "$host" 25) 2>&1 | head -n 5
            echo
        } | tee -a "$outfile"
    done
fi

########################################
# 8. RESUMEN ORIENTATIVO
########################################

sep "Resumen orientativo (servidor vs cliente)" | tee -a "$outfile"

{
    echo "- Si el dominio NO tiene MX o no resuelve, es muy probable que el problema sea de CONFIGURACIÓN DEL SERVIDOR."
    echo "- Si alguna IP de los MX aparece en blacklists, es probable que haya problemas de ENTREGA (spam / bloqueos)."
    echo "- Si MX, SPF, DMARC y SMTP parecen correctos, pero el usuario no puede enviar/recibir,"
    echo "  muchas veces el problema está en el CLIENTE (credenciales, puerto, TLS, antivirus, firewall, etc.)."
    echo
    echo "Este script es solo una ayuda rápida; no sustituye herramientas avanzadas (logs del servidor, cabeceras completas del correo, etc.)."
} | tee -a "$outfile"

########################################
# 9. FINAL
########################################

{
    echo "======================================"
    echo "  Comprobación finalizada."
    echo "  Informe guardado en: $outfile"
    echo "======================================"
} | tee -a "$outfile"

echo
echo "Proceso completado."
echo "Pulsa ENTER para salir."
read -r
