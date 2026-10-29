#!/bin/sh
# Creates a small private CA (first run only) and issues a client certificate
# for the Railway server. Re-run to rotate the client certificate; the CA is reused.
#
#   sh make-certs.sh            -> ./steampipe-pki/
#   CERT_DAYS=180 sh make-certs.sh
#
# Needs OpenSSL 1.1.1+ (on macOS: brew install openssl, then use that openssl).
set -e
DIR="${PKI_DIR:-./steampipe-pki}"
DAYS="${CERT_DAYS:-90}"
CN="${CERT_CN:-steampipe-railway}"

mkdir -p "$DIR"; cd "$DIR"; umask 077

if [ -f ca.pem ] && [ ! -f ca.key ]; then
  echo "ca.pem exists but ca.key is missing. Put ca.key back in $DIR to rotate." >&2
  echo "(Creating a new CA would also mean updating the trust anchor in AWS.)" >&2
  exit 1
fi

if [ ! -f ca.key ]; then
  echo "Creating CA (valid 5 years)..."
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 1825 -subj "/CN=steampipe-railway-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out ca.pem
fi

echo "Issuing client certificate CN=$CN (valid $DAYS days)..."
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out client.key
openssl req -new -key client.key -subj "/CN=$CN" -out client.csr
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' > client.ext
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -sha256 -days "$DAYS" -extfile client.ext -out client.pem 2>/dev/null
rm -f client.csr client.ext
openssl verify -CAfile ca.pem client.pem

echo
echo "Expires: $(openssl x509 -in client.pem -noout -enddate | cut -d= -f2)"
echo
echo "Railway variables:"
echo "RA_CERT_B64=$(base64 < client.pem | tr -d '\n')"
echo
echo "RA_KEY_B64=$(base64 < client.key | tr -d '\n')"
echo
echo "Keep $DIR/ca.key offline (password manager / vault). Never upload it to Railway or git."
