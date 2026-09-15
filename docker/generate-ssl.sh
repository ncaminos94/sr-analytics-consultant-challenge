#!/bin/sh
set -e

SSL_DIR="/ssl"
CERT_FILE="${SSL_DIR}/localhost.crt"
KEY_FILE="${SSL_DIR}/localhost.key"

echo "Checking SSL certificates..."
mkdir -p "${SSL_DIR}"

if [ -f "${CERT_FILE}" ] && [ -f "${KEY_FILE}" ]; then
    if openssl x509 -checkend 86400 -noout -in "${CERT_FILE}" > /dev/null 2>&1; then
        echo "SSL certificates already exist and are valid"
        exit 0
    fi
    rm -f "${CERT_FILE}" "${KEY_FILE}"
fi

echo "Generating self-signed SSL certificates..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -subj "/C=US/ST=State/L=City/O=Development/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1" \
    2>/dev/null || {
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "${KEY_FILE}" \
            -out "${CERT_FILE}" \
            -subj "/C=US/ST=State/L=City/O=Development/CN=localhost"
    }

chmod 644 "${CERT_FILE}"
chmod 600 "${KEY_FILE}"
echo "SSL setup complete"
