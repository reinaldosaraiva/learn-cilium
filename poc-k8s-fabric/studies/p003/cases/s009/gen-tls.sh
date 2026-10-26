#!/usr/bin/env bash
# P003-S009 / P006-S001 (A7) — Gera certificados e chaves TLS efêmeros em tempo de
# execução para o caso S009 (Gateway TLS Termination + BackendTLSPolicy), evitando
# versionar chaves privadas estáticas no repositório git.
#
# Uso:
#   bash gen-tls.sh --dry-run
#   bash gen-tls.sh --render > /tmp/10-tls.rendered.yaml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/10-tls.yaml"
MODE="${1:---render}"

if [[ "${MODE}" == "--dry-run" ]]; then
  echo "[DRY-RUN] gen-tls.sh: geraria CA lab + CA foreign + 5 pares TLS efêmeros via openssl e renderizaria ${TEMPLATE}"
  exit 0
fi

if [[ "${MODE}" != "--render" ]]; then
  echo "Uso: $0 [--dry-run|--render]" >&2
  exit 2
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/p003-s009-tls.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

b64_single_line() {
  base64 < "$1" | tr -d '\n'
}

# 1. Lab CA
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj "/CN=p003-s009-lab-ca" \
  -keyout "${WORKDIR}/lab-ca.key" -out "${WORKDIR}/lab-ca.crt" >/dev/null 2>&1

# 2. Foreign CA (negative control)
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj "/CN=p003-s009-foreign-ca" \
  -keyout "${WORKDIR}/foreign-ca.key" -out "${WORKDIR}/foreign-ca.crt" >/dev/null 2>&1

# 3. Edge Gateway cert (edge.p003.study)
openssl req -newkey rsa:2048 -nodes \
  -subj "/CN=edge.p003.study" \
  -keyout "${WORKDIR}/edge.key" -out "${WORKDIR}/edge.csr" >/dev/null 2>&1
cat > "${WORKDIR}/edge.ext" <<'EOF'
subjectAltName = DNS:edge.p003.study,DNS:*.p003.study
EOF
openssl x509 -req -in "${WORKDIR}/edge.csr" -CA "${WORKDIR}/lab-ca.crt" -CAkey "${WORKDIR}/lab-ca.key" \
  -CAcreateserial -days 30 -extfile "${WORKDIR}/edge.ext" -out "${WORKDIR}/edge.crt" >/dev/null 2>&1

# 4. Valid Backend cert (p003-a-backend-tls.p003-tenant-a.svc.cluster.local)
BACKEND_FQDN="p003-a-backend-tls.p003-tenant-a.svc.cluster.local"
openssl req -newkey rsa:2048 -nodes \
  -subj "/CN=${BACKEND_FQDN}" \
  -keyout "${WORKDIR}/backend.key" -out "${WORKDIR}/backend.csr" >/dev/null 2>&1
cat > "${WORKDIR}/backend.ext" <<EOF
subjectAltName = DNS:${BACKEND_FQDN}
EOF
openssl x509 -req -in "${WORKDIR}/backend.csr" -CA "${WORKDIR}/lab-ca.crt" -CAkey "${WORKDIR}/lab-ca.key" \
  -CAcreateserial -days 30 -extfile "${WORKDIR}/backend.ext" -out "${WORKDIR}/backend.crt" >/dev/null 2>&1

# 5. Wrong SAN Backend cert (outro-servico.p003-tenant-a.svc.cluster.local)
WRONGSAN_FQDN="outro-servico.p003-tenant-a.svc.cluster.local"
openssl req -newkey rsa:2048 -nodes \
  -subj "/CN=${WRONGSAN_FQDN}" \
  -keyout "${WORKDIR}/wrongsan.key" -out "${WORKDIR}/wrongsan.csr" >/dev/null 2>&1
cat > "${WORKDIR}/wrongsan.ext" <<EOF
subjectAltName = DNS:${WRONGSAN_FQDN}
EOF
openssl x509 -req -in "${WORKDIR}/wrongsan.csr" -CA "${WORKDIR}/lab-ca.crt" -CAkey "${WORKDIR}/lab-ca.key" \
  -CAcreateserial -days 30 -extfile "${WORKDIR}/wrongsan.ext" -out "${WORKDIR}/wrongsan.crt" >/dev/null 2>&1

# 6. Expired Backend cert (validade no passado: 2020-01-01 .. 2020-01-02 UTC)
openssl req -newkey rsa:2048 -nodes \
  -subj "/CN=${BACKEND_FQDN}" \
  -keyout "${WORKDIR}/expired.key" -out "${WORKDIR}/expired.csr" >/dev/null 2>&1
if ! openssl x509 -req -in "${WORKDIR}/expired.csr" -CA "${WORKDIR}/lab-ca.crt" -CAkey "${WORKDIR}/lab-ca.key" \
  -CAcreateserial -not_before 20200101000000Z -not_after 20200102000000Z \
  -extfile "${WORKDIR}/backend.ext" -out "${WORKDIR}/expired.crt" >/dev/null 2>&1; then
  mkdir -p "${WORKDIR}/ca.db.certs"
  : > "${WORKDIR}/ca.db.index"
  echo "01" > "${WORKDIR}/ca.db.serial"
  cat > "${WORKDIR}/ca.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = ${WORKDIR}
database = \$dir/ca.db.index
new_certs_dir = \$dir/ca.db.certs
certificate = \$dir/lab-ca.crt
private_key = \$dir/lab-ca.key
serial = \$dir/ca.db.serial
default_md = sha256
policy = policy_anything
x509_extensions = usr_cert
[ policy_anything ]
commonName = supplied
[ usr_cert ]
subjectAltName = DNS:${BACKEND_FQDN}
EOF
  openssl ca -batch -config "${WORKDIR}/ca.cnf" \
    -startdate 20200101000000Z -enddate 20200102000000Z \
    -in "${WORKDIR}/expired.csr" -out "${WORKDIR}/expired.crt" \
    -notext >/dev/null 2>&1
fi

# 7. Foreign-CA Backend cert
openssl req -newkey rsa:2048 -nodes \
  -subj "/CN=${BACKEND_FQDN}" \
  -keyout "${WORKDIR}/foreign.key" -out "${WORKDIR}/foreign.csr" >/dev/null 2>&1
openssl x509 -req -in "${WORKDIR}/foreign.csr" -CA "${WORKDIR}/foreign-ca.crt" -CAkey "${WORKDIR}/foreign-ca.key" \
  -CAcreateserial -days 30 -extfile "${WORKDIR}/backend.ext" -out "${WORKDIR}/foreign.crt" >/dev/null 2>&1

EDGE_CRT_B64="$(b64_single_line "${WORKDIR}/edge.crt")"
EDGE_KEY_B64="$(b64_single_line "${WORKDIR}/edge.key")"
BACKEND_CRT_B64="$(b64_single_line "${WORKDIR}/backend.crt")"
BACKEND_KEY_B64="$(b64_single_line "${WORKDIR}/backend.key")"
WRONGSAN_CRT_B64="$(b64_single_line "${WORKDIR}/wrongsan.crt")"
WRONGSAN_KEY_B64="$(b64_single_line "${WORKDIR}/wrongsan.key")"
EXPIRED_CRT_B64="$(b64_single_line "${WORKDIR}/expired.crt")"
EXPIRED_KEY_B64="$(b64_single_line "${WORKDIR}/expired.key")"
FOREIGN_CRT_B64="$(b64_single_line "${WORKDIR}/foreign.crt")"
FOREIGN_KEY_B64="$(b64_single_line "${WORKDIR}/foreign.key")"
FOREIGN_CA_B64="$(b64_single_line "${WORKDIR}/foreign-ca.crt")"

awk \
  -v edge_crt="${EDGE_CRT_B64}" \
  -v edge_key="${EDGE_KEY_B64}" \
  -v backend_crt="${BACKEND_CRT_B64}" \
  -v backend_key="${BACKEND_KEY_B64}" \
  -v wrongsan_crt="${WRONGSAN_CRT_B64}" \
  -v wrongsan_key="${WRONGSAN_KEY_B64}" \
  -v expired_crt="${EXPIRED_CRT_B64}" \
  -v expired_key="${EXPIRED_KEY_B64}" \
  -v foreign_crt="${FOREIGN_CRT_B64}" \
  -v foreign_key="${FOREIGN_KEY_B64}" \
  -v foreign_ca="${FOREIGN_CA_B64}" \
  -v lab_ca_file="${WORKDIR}/lab-ca.crt" '
  /<GENERATED_BY_GEN_TLS_SH:LAB_CA_CRT_PEM>/ {
    while ((getline line < lab_ca_file) > 0) {
      print "    " line
    }
    close(lab_ca_file)
    next
  }
  {
    gsub(/<GENERATED_BY_GEN_TLS_SH:EDGE_TLS_CRT_B64>/, edge_crt)
    gsub(/<GENERATED_BY_GEN_TLS_SH:EDGE_TLS_KEY_B64>/, edge_key)
    gsub(/<GENERATED_BY_GEN_TLS_SH:BACKEND_TLS_CRT_B64>/, backend_crt)
    gsub(/<GENERATED_BY_GEN_TLS_SH:BACKEND_TLS_KEY_B64>/, backend_key)
    gsub(/<GENERATED_BY_GEN_TLS_SH:WRONGSAN_TLS_CRT_B64>/, wrongsan_crt)
    gsub(/<GENERATED_BY_GEN_TLS_SH:WRONGSAN_TLS_KEY_B64>/, wrongsan_key)
    gsub(/<GENERATED_BY_GEN_TLS_SH:EXPIRED_TLS_CRT_B64>/, expired_crt)
    gsub(/<GENERATED_BY_GEN_TLS_SH:EXPIRED_TLS_KEY_B64>/, expired_key)
    gsub(/<GENERATED_BY_GEN_TLS_SH:FOREIGNCA_TLS_CRT_B64>/, foreign_crt)
    gsub(/<GENERATED_BY_GEN_TLS_SH:FOREIGNCA_TLS_KEY_B64>/, foreign_key)
    gsub(/<GENERATED_BY_GEN_TLS_SH:FOREIGN_CA_CRT_B64>/, foreign_ca)
    print
  }
' "${TEMPLATE}"
