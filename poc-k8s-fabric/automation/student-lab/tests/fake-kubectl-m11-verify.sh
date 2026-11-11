#!/usr/bin/env bash
set -euo pipefail

resource=''
name=''
namespace=''
expect_namespace=0
expect_resource=0
expect_name=0
for arg in "$@"; do
  if [[ "${expect_namespace}" == 1 ]]; then
    namespace="${arg}"
    expect_namespace=0
    continue
  fi
  if [[ "${expect_resource}" == 1 ]]; then
    resource="${arg}"
    expect_resource=0
    expect_name=1
    continue
  fi
  if [[ "${expect_name}" == 1 ]]; then
    name="${arg}"
    expect_name=0
    continue
  fi
  case "${arg}" in
    get) expect_resource=1 ;;
    --namespace) expect_namespace=1 ;;
  esac
done

[[ "${resource}" != '' && "${name}" != '' ]] || exit 64
printf '%s|%s|%s\n' "${resource}" "${name}" "${namespace}" >>"${P010_HYBRID_K8S_VERIFY_CALLS:?}"
case "${resource}" in
  deployments) kind=Deployment; api_version=apps/v1 ;;
  ciliumbgpclusterconfigs) kind=CiliumBGPClusterConfig; api_version=cilium.io/v2 ;;
  ciliumbgpadvertisements) kind=CiliumBGPAdvertisement; api_version=cilium.io/v2 ;;
  ciliumbgppeerconfigs) kind=CiliumBGPPeerConfig; api_version=cilium.io/v2 ;;
  namespaces) kind=Namespace; api_version=v1 ;;
  *) exit 65 ;;
esac
case "${name}" in
  *-server) uid=11111111-1111-4111-8111-111111111111 ;;
  *-client) uid=22222222-2222-4222-8222-222222222222 ;;
  *-rack1) uid=33333333-3333-4333-8333-333333333333 ;;
  *-rack2) uid=44444444-4444-4444-8444-444444444444 ;;
  *-pods) uid=55555555-5555-4555-8555-555555555555 ;;
  *-peer) uid=66666666-6666-4666-8666-666666666666 ;;
  p010-hyb-*) uid=77777777-7777-4777-8777-777777777777 ;;
  *) exit 66 ;;
esac
if [[ "${P010_HYBRID_K8S_VERIFY_MODE:-owned}" == wrong-uid && "${name}" == *-client ]]; then
  uid=99999999-9999-4999-8999-999999999999
fi
namespace_json=''
[[ "${namespace}" == '' ]] || namespace_json=",\"namespace\":\"${namespace}\""
printf '{"apiVersion":"%s","kind":"%s","metadata":{"name":"%s","uid":"%s","labels":{"p010-student-owner":"%s","p010-student-run":"%s"}%s}}\n' \
  "${api_version}" "${kind}" "${name}" "${uid}" "${P010_HYBRID_K8S_VERIFY_OWNER:?}" "${P010_HYBRID_K8S_VERIFY_RUN:?}" "${namespace_json}"
