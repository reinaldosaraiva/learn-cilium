#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "$BASH_SOURCE")" && pwd)
repo_root=$(cd "$script_dir/../../../../" && pwd)
flow_playbook="$script_dir/beginner-canary-flow.yml"
ansible_playbook_bin=$(printenv ANSIBLE_PLAYBOOK_BIN 2>/dev/null || command -v ansible-playbook || true)
ansible_config="$repo_root/poc-k8s-fabric/automation/student-lab/ansible.cfg"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$ansible_playbook_bin" ]] || fail "ansible-playbook 2.19.x is required; set ANSIBLE_PLAYBOOK_BIN."
[[ -f "$ansible_config" ]] || fail "student-lab ansible.cfg is missing."

tmp_parent=$(printenv TMPDIR 2>/dev/null || printf '/tmp')
mkdir -p "$tmp_parent"
test_root=$(mktemp -d "$tmp_parent/p010-beginner-canary.XXXXXX")
chmod 700 "$test_root"
if [[ $(printenv PRESERVE_TEST_ARTIFACTS 2>/dev/null || true) == 1 ]]; then
  trap 'printf "TEST_ARTIFACTS=%s\n" "$test_root"' EXIT
else
  trap 'rm -rf "$test_root"' EXIT
fi

test_uid=$(id -u)
test_owner_token='test-owner-token'
namespace_name='student-verify-11111111111111111111111111111111'
namespace_uid='11111111-1111-4111-8111-111111111111'

cat >"$test_root/kubectl" <<'KUBECTL'
#!/bin/sh
set -e

printf '%s\n' "$*" >>"$FAKE_KUBECTL_TRACE"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kubeconfig|--context)
      shift 2
      ;;
    --request-timeout=*)
      shift
      ;;
    *)
      break
      ;;
  esac
done

operation=$1
shift
scenario=$FAKE_KUBECTL_SCENARIO
namespace_state=$FAKE_NAMESPACE_STATE
job_state=$FAKE_JOB_STATE

print_namespace() {
  uid=$1
  owner=$2
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s","uid":"%s","labels":{"p010-student-owner":"%s"},"annotations":{"p010-student-owner-token":"%s"}}}\n' \
    "$FAKE_NAMESPACE_NAME" "$uid" "$owner" "$owner"
}

print_namespace_without_owner() {
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s","uid":"%s"}}\n' \
    "$FAKE_NAMESPACE_NAME" "$FAKE_NAMESPACE_UID"
}

case "$operation" in
  get)
    resource=$1
    shift
    name=$1
    shift
    ignore_not_found=false
    for arg in "$@"; do
      [ "$arg" = '--ignore-not-found=true' ] && ignore_not_found=true
    done
    case "$resource" in
      service)
        printf 'ClusterIP 80 grpc\n'
        ;;
      endpoints)
        if [ "$name" = hubble-relay ]; then
          printf '10.96.0.10\n'
        elif [ "$scenario" = endpoints-api-error ]; then
          printf 'Forbidden: synthetic API failure\n' >&2
          exit 1
        elif [ "$scenario" = endpoints-absent ]; then
          attempt=0
          [ ! -f "$FAKE_ENDPOINT_COUNT" ] || read -r attempt <"$FAKE_ENDPOINT_COUNT"
          attempt=$((attempt + 1))
          printf '%s\n' "$attempt" >"$FAKE_ENDPOINT_COUNT"
        else
          printf '10.244.0.92\n'
        fi
        ;;
      deployment)
        printf '4245\n'
        ;;
      deployments)
        printf 'deployment.apps/cilium-operator\n'
        ;;
      namespace)
        if [ "$ignore_not_found" = true ] && [ ! -f "$namespace_state" ]; then
          exit 0
        fi
        if [ ! -f "$namespace_state" ]; then
          printf 'Error from server (NotFound): namespaces "%s" not found\n' "$name" >&2
          exit 1
        fi
        attempt=0
        [ ! -f "$FAKE_NAMESPACE_READ_COUNT" ] || read -r attempt <"$FAKE_NAMESPACE_READ_COUNT"
        attempt=$((attempt + 1))
        printf '%s\n' "$attempt" >"$FAKE_NAMESPACE_READ_COUNT"
        if [ "$attempt" -eq 3 ] && [ "$scenario" = cleanup-missing-owner ]; then
          print_namespace_without_owner
        elif [ "$attempt" -eq 3 ] && [ "$scenario" = cleanup-malformed-json ]; then
          printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s","uid":"%s"}\n' \
            "$FAKE_NAMESPACE_NAME" "$FAKE_NAMESPACE_UID"
        elif [ "$scenario" = uid-replacement ] && [ -f "$job_state" ]; then
          print_namespace '22222222-2222-4222-8222-222222222222' foreign-owner
        else
          print_namespace "$FAKE_NAMESPACE_UID" "$FAKE_OWNER_TOKEN"
        fi
        ;;
      job)
        if [ ! -f "$job_state" ]; then
          if [ "$ignore_not_found" = true ]; then
            exit 0
          fi
          printf 'Error from server (NotFound): jobs "%s" not found\n' "$name" >&2
          exit 1
        fi
        printf '1|0|0|Failed:True:BackoffLimitExceeded;\n'
        ;;
      *)
        printf 'unexpected fake kubectl get: %s %s\n' "$resource" "$name" >&2
        exit 2
        ;;
    esac
    ;;
  create)
    manifest=''
    if [ "$1" = '-f' ]; then
      manifest=$2
    fi
    case "$manifest" in
      */canary-namespace.yml)
        : >"$namespace_state"
        print_namespace "$FAKE_NAMESPACE_UID" "$FAKE_OWNER_TOKEN"
        ;;
      */canary-probe.yml)
        : >"$job_state"
        printf 'job.batch/relay-dns-and-http created\n'
        ;;
      *)
        printf 'unexpected fake kubectl create manifest\n' >&2
        exit 2
        ;;
    esac
    ;;
  apply)
    printf 'server resources applied\n'
    ;;
  rollout)
    target=$2
    if [ "$target" = deployment/http-canary ] && [ "$scenario" = server-not-ready ]; then
      printf 'deployment did not become ready\n' >&2
      exit 1
    fi
    printf 'deployment ready\n'
    ;;
  wait)
    if [ "$scenario" = success ]; then
      printf 'job condition met\n'
    else
      printf 'Job reached Failed condition\n' >&2
      exit 1
    fi
    ;;
  logs)
    if [ "$scenario" = logs-failure ]; then
      printf 'synthetic log API failure\n' >&2
      exit 1
    elif [ "$scenario" = success ]; then
      printf 'Server: 10.96.0.10\nName: hubble-relay.kube-system.svc.cluster.local\nstudent-canary-ok\n'
    else
      printf 'Server: 10.96.0.10\nName: hubble-relay.kube-system.svc.cluster.local\nwget: No route to host\n'
    fi
    ;;
  delete)
    if [ "$1" = namespace ]; then
      rm -f "$namespace_state"
      printf 'namespace "%s" deleted\n' "$2"
    else
      printf 'unexpected fake kubectl delete\n' >&2
      exit 2
    fi
    ;;
  *)
    printf 'unexpected fake kubectl operation: %s\n' "$operation" >&2
    exit 2
    ;;
esac
KUBECTL
chmod 700 "$test_root/kubectl"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

trace_count() {
  awk -v pattern="$2" 'index($0, pattern) { count++ } END { print count + 0 }' "$1"
}

trace_line() {
  awk -v pattern="$2" 'index($0, pattern) { print NR; exit }' "$1"
}

trace_nth_line() {
  awk -v pattern="$2" -v wanted="$3" \
    'index($0, pattern) { count++; if (count == wanted) { print NR; exit } }' "$1"
}

require_trace_absent() {
  local trace_file=$1 pattern=$2
  [[ -z $(trace_line "$trace_file" "$pattern") ]] || fail "unexpected trace command: $pattern"
}

require_trace_order() {
  local trace_file=$1 previous=0 line pattern
  shift
  for pattern in "$@"; do
    line=$(trace_line "$trace_file" "$pattern")
    [[ -n $line ]] || fail "missing trace command: $pattern"
    (( line > previous )) || fail "trace order failed at: $pattern"
    previous=$line
  done
}

run_case() {
  local name=$1 expected_failure=$2 expected_task=$3 expected_rc=$4
  local expected_collection=$5 expected_evidence_complete=$6 expected_cleanup=$7
  local case_dir="$test_root/$name"
  local trace_file="$case_dir/kubectl.trace"
  local log_file="$case_dir/ansible.log"
  local namespace_state="$case_dir/namespace-present"
  local namespace_read_count="$case_dir/namespace-read-count"
  local job_state="$case_dir/job-created"
  local endpoint_count="$case_dir/endpoint-attempts"
  local rendered="$case_dir/rendered-original.yml"
  local rc

  mkdir -p "$case_dir/bin" "$case_dir/runtime"
  chmod 700 "$case_dir" "$case_dir/runtime"
  ln -s "$test_root/kubectl" "$case_dir/bin/kubectl"
  : >"$trace_file"
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$case_dir/start.utc"
  pwd >"$case_dir/cwd"
  printf '%s\n' "$ansible_playbook_bin -i localhost, --connection local $flow_playbook" >"$case_dir/argv.txt"
  printf 'scenario=%s\nexpected_failure=%s\nexpected_task=%s\nexpected_rc=%s\nexpected_collection=%s\nexpected_evidence_complete=%s\nexpected_cleanup=%s\n' \
    "$name" "$expected_failure" "$expected_task" "$expected_rc" "$expected_collection" "$expected_evidence_complete" "$expected_cleanup" >"$case_dir/expectations.txt"

  if env \
    ANSIBLE_CONFIG="$ansible_config" \
    ANSIBLE_NOCOLOR=1 \
    STUDENT_LAB_ROOT="$repo_root" \
    TEST_SCRATCH="$case_dir" \
    TEST_UID="$test_uid" \
    TEST_OWNER_TOKEN="$test_owner_token" \
    EXPECTED_FAILURE="$expected_failure" \
    EXPECTED_TASK="$expected_task" \
    EXPECTED_RC="$expected_rc" \
    EXPECTED_COLLECTION="$expected_collection" \
    EXPECTED_CLEANUP="$expected_cleanup" \
    EXPECTED_EVIDENCE_COMPLETE="$expected_evidence_complete" \
    FAKE_KUBECTL_SCENARIO="$name" \
    FAKE_KUBECTL_TRACE="$trace_file" \
    FAKE_NAMESPACE_STATE="$namespace_state" \
    FAKE_NAMESPACE_NAME="$namespace_name" \
    FAKE_NAMESPACE_UID="$namespace_uid" \
    FAKE_NAMESPACE_READ_COUNT="$namespace_read_count" \
    FAKE_OWNER_TOKEN="$test_owner_token" \
    FAKE_JOB_STATE="$job_state" \
    FAKE_ENDPOINT_COUNT="$endpoint_count" \
    "$ansible_playbook_bin" -i 'localhost,' --connection local "$flow_playbook" >"$log_file" 2>&1
  then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$rc" >"$case_dir/rc"
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$case_dir/end.utc"
  [[ $rc -eq 0 ]] || { cat "$log_file" >&2; fail "Ansible flow failed for $name (rc=$rc)."; }

  local evidence_file="$case_dir/runtime/canary-failure.txt"
  if [[ $expected_failure == 1 ]]; then
    [[ -f "$evidence_file" ]] || fail "$name did not write private failure evidence."
    ! grep -Fq "$test_owner_token" "$evidence_file" || fail "$name evidence contains the owner token."
  else
    [[ ! -e "$evidence_file" ]] || fail "success unexpectedly wrote failure evidence."
  fi

  case "$name" in
    success)
      require_trace_order "$trace_file" \
        "apply -f $case_dir/runtime/canary.yml" \
        'rollout status deployment/http-canary' \
        'get endpoints http-canary' \
        "create -f $case_dir/runtime/canary-probe.yml" \
        'wait --for=condition=complete job/relay-dns-and-http' \
        'logs job/relay-dns-and-http' \
        "delete namespace $namespace_name"
      [[ ! -e "$namespace_state" ]] || fail "success did not remove its namespace."
      cat "$case_dir/runtime/canary.yml" >"$rendered"
      printf '%s\n' '---' >>"$rendered"
      cat "$case_dir/runtime/canary-probe.yml" >>"$rendered"
      [[ $(sha256_file "$rendered") == 2a1776d44386d2918874fcb8c181934f64486e08cad2159b371ee26e0939967f ]] || fail "split manifests changed the 32e canary payload."
      ;;
    server-not-ready)
      require_trace_absent "$trace_file" 'get endpoints http-canary'
      require_trace_absent "$trace_file" "create -f $case_dir/runtime/canary-probe.yml"
      require_trace_absent "$trace_file" 'wait --for=condition=complete job/relay-dns-and-http'
      [[ ! -e "$namespace_state" ]] || fail "server-not-ready case did not clean the proven namespace."
      ;;
    endpoints-absent)
      [[ $(trace_count "$trace_file" 'get endpoints http-canary') -eq 8 ]] || fail "absent Ready endpoints did not stop after eight attempts."
      awk -v pattern='get endpoints http-canary' '
        index($0, pattern) { count++; if ($0 !~ /--request-timeout=5s/) failed=1 }
        END { exit failed || count != 8 }
      ' "$trace_file" || fail "endpoint requests were not bounded by the expected timeout."
      require_trace_absent "$trace_file" "create -f $case_dir/runtime/canary-probe.yml"
      [[ ! -e "$namespace_state" ]] || fail "endpoint-absent case did not clean the proven namespace."
      ;;
    endpoints-api-error)
      [[ $(trace_count "$trace_file" 'get endpoints http-canary') -eq 1 ]] || fail "endpoint API failure should stop retries immediately."
      require_trace_absent "$trace_file" "create -f $case_dir/runtime/canary-probe.yml"
      [[ ! -e "$namespace_state" ]] || fail "endpoint API error did not clean the proven namespace."
      ;;
    job-failure)
      require_trace_order "$trace_file" \
        "create -f $case_dir/runtime/canary-probe.yml" \
        'wait --for=condition=complete job/relay-dns-and-http' \
        "--request-timeout=10s get namespace $namespace_name -o json" \
        "get job relay-dns-and-http" \
        'logs job/relay-dns-and-http' \
        "delete namespace $namespace_name"
      grep -Fq 'job_status=' "$evidence_file" || fail "Job status was not retained."
      grep -Fq 'job_logs:' "$evidence_file" || fail "Job logs were not retained."
      [[ ! -e "$namespace_state" ]] || fail "complete Job evidence did not allow owned namespace cleanup."
      ;;
    logs-failure)
      require_trace_order "$trace_file" \
        'wait --for=condition=complete job/relay-dns-and-http' \
        "--request-timeout=10s get namespace $namespace_name -o json" \
        "get job relay-dns-and-http" \
        'logs job/relay-dns-and-http'
      require_trace_absent "$trace_file" "delete namespace $namespace_name"
      grep -Fq 'job_status=' "$evidence_file" || fail "Job status was not retained after log collection failed."
      require_trace_absent "$evidence_file" 'job_logs:'
      [[ -e "$namespace_state" ]] || fail "log collection failure deleted the namespace."
      ;;
    uid-replacement)
      require_trace_order "$trace_file" \
        'wait --for=condition=complete job/relay-dns-and-http' \
        "--request-timeout=10s get namespace $namespace_name -o json"
      require_trace_absent "$trace_file" 'get job relay-dns-and-http'
      require_trace_absent "$trace_file" 'logs job/relay-dns-and-http'
      require_trace_absent "$trace_file" "delete namespace $namespace_name"
      require_trace_absent "$evidence_file" 'job_status='
      [[ -e "$namespace_state" ]] || fail "UID replacement deleted a namespace."
      ;;
    cleanup-missing-owner|cleanup-malformed-json)
      wait_line=$(trace_line "$trace_file" 'wait --for=condition=complete job/relay-dns-and-http')
      status_line=$(trace_line "$trace_file" 'get job relay-dns-and-http')
      logs_line=$(trace_line "$trace_file" 'logs job/relay-dns-and-http')
      cleanup_line=$(trace_nth_line "$trace_file" "get namespace $namespace_name -o json" 4)
      [[ -n $wait_line && -n $status_line && -n $logs_line && -n $cleanup_line ]] \
        || fail "$name did not reach cleanup classification after complete Job evidence."
      (( wait_line < status_line && status_line < logs_line && logs_line < cleanup_line )) \
        || fail "$name cleanup identity read occurred before Job evidence collection completed."
      [[ $(trace_count "$trace_file" "get namespace $namespace_name -o json") -eq 4 ]] \
        || fail "$name did not include one collision check and exactly three live namespace reads."
      require_trace_absent "$trace_file" "delete namespace $namespace_name"
      grep -Fq 'job_status=' "$evidence_file" || fail "$name did not retain bounded Job status evidence."
      grep -Fq 'job_logs:' "$evidence_file" || fail "$name did not retain bounded Job logs evidence."
      grep -Fq 'primary_task=Wait for Relay DNS and in-cluster HTTP response' "$evidence_file" \
        || fail "$name changed the original failure recorded in private evidence."
      grep -Fq 'primary_rc=1' "$evidence_file" \
        || fail "$name changed the original return code recorded in private evidence."
      [[ -e "$namespace_state" ]] || fail "$name cleanup classification removed a namespace without ownership metadata."
      [[ $(cat "$namespace_read_count") -eq 3 ]] || fail "$name did not use the third live namespace response for cleanup."
      ;;
    *)
      fail "unknown test case: $name"
      ;;
  esac

  printf 'PASS %s\n' "$name"
}

run_case success 0 '' '' '' 1 ''
run_case server-not-ready 1 'Wait for the temporary HTTP server' 1 '' 1 ''
run_case endpoints-absent 1 'Require at least one Ready address for the temporary HTTP Service' '' '' 1 ''
run_case endpoints-api-error 1 'Distinguish an endpoint API error from an absent Ready address' '' '' 1 ''
run_case job-failure 1 'Wait for Relay DNS and in-cluster HTTP response' 1 '' 1 ''
run_case logs-failure 1 'Wait for Relay DNS and in-cluster HTTP response' 1 'job-log-collection-failed (rc=1)' 0 ''
run_case uid-replacement 1 'Wait for Relay DNS and in-cluster HTTP response' 1 'namespace-identity-changed' 0 ''
run_case cleanup-missing-owner 1 'Wait for Relay DNS and in-cluster HTTP response' 1 '' 1 'namespace-identity-unreadable'
run_case cleanup-malformed-json 1 'Wait for Relay DNS and in-cluster HTTP response' 1 '' 1 'namespace-identity-unreadable'

printf 'All beginner canary flow cases passed.\n'
