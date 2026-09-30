#!/bin/bash
#
# Crea un certificado local de firma de código para que el permiso de
# accesibilidad sobreviva a las recompilaciones.
#
# EL PROBLEMA
#
# macOS asocia el permiso de Accesibilidad a la firma del binario, no a su
# ruta. Con firma ad-hoc (la que se usa por defecto), cada compilación produce
# una firma distinta: el sistema ve otra app, revoca el permiso y el pegado
# automático deja de funcionar sin decir nada. Se concede el permiso, se
# recompila, y ya no pega.
#
# LA SOLUCIÓN
#
# Un certificado propio de firma de código. No hace falta cuenta de Apple ni
# pagar nada: sirve cualquier certificado estable, porque lo que el sistema
# recuerda es la identidad de la firma y esa ya no cambia entre compilaciones.
#
# QUÉ TOCA ESTE SCRIPT
#
# Añade un certificado a TU llavero de inicio de sesión. Nada más: no instala
# nada en el sistema, no necesita administrador y se puede deshacer borrando el
# certificado desde Acceso a Llaveros.
#
# La primera vez que firmes, macOS pedirá permiso para usar la clave privada.
# Pulsa «Permitir siempre» y no volverá a preguntar.
#
set -euo pipefail

IDENTITY_NAME="Ambar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Sin `-v`: un certificado autofirmado no lo firma ninguna CA de confianza, así
# que la evaluación de política lo marca CSSMERR_TP_NOT_TRUSTED y `-v` lo
# esconde. Para firmar da igual —codesign lo acepta— y es lo único que importa
# aquí: que la identidad no cambie entre compilaciones.
# Sin `| grep -q` bajo `pipefail`: SIGPIPE haría que la tubería fallara justo cuando
# encuentra la identidad, y el guion la daría por ausente.
IDENTIDADES="$(security find-identity -p codesigning 2>/dev/null || true)"
case "$IDENTIDADES" in
  *"$IDENTITY_NAME"*)
    echo "✓ El certificado «${IDENTITY_NAME}» ya existe."
    echo
    echo "  Para usarlo:"
    echo "    CODESIGN_IDENTITY=\"$IDENTITY_NAME\" ./Scripts/make-app.sh"
    exit 0
    ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Generando el certificado…"
# `extendedKeyUsage=codeSigning` es lo que lo hace válido para firmar código;
# sin esa extensión, codesign no lo acepta como identidad.
openssl req -x509 -newkey rsa:2048 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes \
  -subj "/CN=$IDENTITY_NAME/O=Ambar/C=ES" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

# `-legacy` y una contraseña real, las dos por el mismo motivo: OpenSSL 3 cifra
# el PKCS#12 con AES-256 y calcula el MAC con SHA-256, y el importador del
# llavero no entiende ninguna de las dos cosas. Falla con «MAC verification
# failed during PKCS12 import (wrong password?)», que apunta a la contraseña
# cuando el problema es el algoritmo. Con contraseña vacía falla igual.
# La contraseña no protege nada: el fichero vive segundos en un mktemp -d.
P12_PASSWORD="ambar-local"

openssl pkcs12 -export -legacy \
  -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout "pass:$P12_PASSWORD" \
  -name "$IDENTITY_NAME"

echo "▸ Importando al llavero de inicio de sesión…"
# `-T /usr/bin/codesign` autoriza a codesign a usar la clave sin preguntar cada
# vez. Puede que aún salga un diálogo la primera vez: acepta con
# «Permitir siempre».
security import "$WORK/identity.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

echo
echo "✓ Certificado «${IDENTITY_NAME}» instalado."
echo
echo "  Compila y firma con él:"
echo "    CODESIGN_IDENTITY=\"$IDENTITY_NAME\" ./Scripts/make-app.sh"
echo
echo "  make-app.sh ya lo detecta solo, así que basta con:"
echo "    ./Scripts/make-app.sh"
echo
echo "  Después, concede el permiso una vez en:"
echo "    Ajustes del Sistema → Privacidad y seguridad → Accesibilidad"
echo
echo "  Si el permiso quedó en un estado raro de intentos anteriores:"
echo "    tccutil reset Accessibility dev.rrios.ambar"
