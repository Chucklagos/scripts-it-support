#!/usr/bin/env bash

# Script avanzado para generar un informe DNS/WHOIS/ASN de un dominio
# Guardará toda la salida en un archivo TXT y también la mostrará por pantalla.

# Comprobar dependencias básicas
for cmd in dig whois; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: el comando '$cmd' no está instalado."
        echo "Instálalo y vuelve a ejecutar el script."
        [[ "$cmd" == "dig" ]] && echo "En Debian/Ubuntu: sudo apt-get install dnsutils"
        [[ "$cmd" == "whois" ]] && echo "En Debian/Ubuntu: sudo apt-get install whois"
        exit 1
    fi
done

echo "======================================"
echo "  Informe completo de un dominio"
echo "======================================"
read -rp "Introduce el nombre de dominio (ejemplo.com): " domain

# Quitar espacios
domain="$(echo "$domain" | tr -d '[:space:]')"

if [[ -z "$domain" ]]; then
    echo "No has introducido ningún dominio. Saliendo."
    exit 1
fi

# Nombre del archivo de salida
timestamp="$(date +%Y%m%d_%H%M%S)"
outfile="dns_report_${domain}_${timestamp}.txt"

# Función para escribir encabezados bonitos
sep() {
    local title="$1"
    echo
    echo "========== $title =========="
}

# Empezar el informe
{
    echo "======================================"
    echo "  INFORME DNS / WHOIS / ASN"
    echo "======================================"
    echo "Dominio: $domain"
    echo "Fecha:   $(date)"
    echo "Archivo: $outfile"
    echo "======================================"
    echo
} | tee "$outfile"

########################################
# 1. WHOIS DEL DOMINIO
########################################
sep "WHOIS del dominio" | tee -a "$outfile"
whois "$domain" 2>/dev/null | tee -a "$outfile"

########################################
# 2. REGISTROS DNS BÁSICOS
########################################

# Función para mostrar un tipo de registro
mostrar_registro() {
    local type="$1"
    sep "Registros $type" | tee -a "$outfile"
    dig +nocmd "$domain" "$type" +multiline +noall +answer | tee -a "$outfile"
}

# Lista de tipos de registros a consultar
tipos=("A" "AAAA" "MX" "NS" "TXT" "CNAME" "SOA" "CAA")

for t in "${tipos[@]}"; do
    mostrar_registro "$t"
done

# Consulta ANY (si el servidor la permite)
sep "Consulta ANY" | tee -a "$outfile"
dig +nocmd "$domain" ANY +multiline +noall +answer | tee -a "$outfile"

########################################
# 3. DMARC
########################################
dmarc="_dmarc.${domain}"
sep "Registro DMARC (${dmarc})" | tee -a "$outfile"
dig +nocmd "$dmarc" TXT +multiline +noall +answer | tee -a "$outfile"

########################################
# 4. RECOLECCIÓN DE IPs (A y AAAA)
########################################
sep "IPs (A y AAAA) del dominio" | tee -a "$outfile"

# Obtener IPs únicas
mapfile -t all_ips < <( (dig +short "$domain" A; dig +short "$domain" AAAA) | sort -u )

if [[ ${#all_ips[@]} -eq 0 ]]; then
    echo "No se encontraron IPs A/AAAA para el dominio." | tee -a "$outfile"
else
    for ip in "${all_ips[@]}"; do
        echo "IP encontrada: $ip" | tee -a "$outfile"
    done
fi

########################################
# 5. INFORMACIÓN DE IPs: REVERSE DNS + ASN
########################################

get_asn_info() {
    local ip="$1"

    echo "  > Intentando obtener ASN desde whois.cymru.com..."
    # Consulta al servicio de Team Cymru
    local raw
    raw=$(whois -h whois.cymru.com " -v $ip" 2>/dev/null | tail -n 1)

    if [[ -n "$raw" && "$raw" != *"Bulk mode"* ]]; then
        # Formato: AS | IP | BGP Prefix | CC | Registry | Allocated | AS Name
        local as ip_field desc
        as=$(echo "$raw" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
        ip_field=$(echo "$raw" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
        desc=$(echo "$raw" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $7); print $7}')

        echo "    ASN:          $as"
        echo "    IP (Cymru):   $ip_field"
        echo "    Descripción:  $desc"
    else
        echo "  > No se pudo obtener info desde whois.cymru.com, usando whois estándar..."
        # Extraer lo más útil del whois normal
        whois "$ip" 2>/dev/null | grep -iE 'origin|OriginAS|descr|OrgName|netname' | sed 's/^/    /'
    fi
}

sep "Información de IPs (reverse DNS + ASN)" | tee -a "$outfile"

if [[ ${#all_ips[@]} -eq 0 ]]; then
    echo "No hay IPs para analizar." | tee -a "$outfile"
else
    for ip in "${all_ips[@]}"; do
        {
            echo "--------------------------------------"
            echo "IP: $ip"
            echo "Reverse DNS:"
            dig -x "$ip" +short
            echo
            echo "Información ASN / Organización:"
            get_asn_info "$ip"
            echo
        } | tee -a "$outfile"
    done
fi

########################################
# 6. INTENTO DE TRANSFERENCIA DE ZONA (AXFR)
########################################
sep "Intento de transferencia de zona (AXFR)" | tee -a "$outfile"

# Obtener NS en formato simple
mapfile -t ns_list < <(dig +short "$domain" NS)

if [[ ${#ns_list[@]} -eq 0 ]]; then
    echo "No se encontraron servidores NS para el dominio." | tee -a "$outfile"
else
    for ns in "${ns_list[@]}"; do
        ns_clean="${ns%.}"  # quitar punto final si lo hay
        {
            echo "---- Probando NS: $ns_clean ----"
            dig @"$ns_clean" "$domain" AXFR +noall +answer
            echo
        } | tee -a "$outfile"
    done
fi

########################################
# 7. FINAL
########################################
{
    echo "======================================"
    echo "  Informe finalizado."
    echo "  Archivo generado: $outfile"
    echo "======================================"
} | tee -a "$outfile"

echo
echo "Proceso completado."
echo "Pulsa ENTER para salir."
read -r
