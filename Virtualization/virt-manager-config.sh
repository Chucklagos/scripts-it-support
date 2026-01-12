#!/usr/bin/env bash
set -e

echo "=============================================="
echo " Fedora Virtualization Setup (KVM / libvirt)"
echo "=============================================="

# 1. Comprobar si se ejecuta como root
if [[ $EUID -eq 0 ]]; then
  echo "❌ No ejecutes este script como root."
  echo "👉 Ejecútalo como usuario normal (usará sudo cuando sea necesario)."
  exit 1
fi

# 2. Actualizar sistema
echo "🔄 Actualizando sistema..."
sudo dnf update -y

# 3. Instalar virtualización completa
echo "📦 Instalando stack de virtualización..."
sudo dnf install -y \
  @virtualization \
  virt-manager \
  libvirt-daemon-config-network \
  libvirt-daemon-kvm

# 4. Habilitar e iniciar libvirtd
echo "🚀 Habilitando servicios de libvirt..."
sudo systemctl enable --now libvirtd

# 5. Añadir usuario a grupos necesarios
echo "👤 Añadiendo usuario '$USER' a grupos libvirt y kvm..."
sudo usermod -aG libvirt,kvm "$USER"

# 6. Verificación básica
echo "🔍 Verificando estado de libvirtd..."
systemctl status libvirtd --no-pager

# 7. Mensaje final
echo ""
echo "✅ Instalación completada correctamente."
echo ""
echo "⚠️ PASO MUY IMPORTANTE:"
echo "----------------------------------------------"
echo "👉 Cierra sesión o reinicia el sistema"
echo "👉 para que los permisos de grupo tengan efecto"
echo ""
echo "Después podrás ejecutar:"
echo "  virt-manager"
echo ""
echo "=============================================="
