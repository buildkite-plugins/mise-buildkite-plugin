#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export BUILDKITE_BUILD_CHECKOUT_PATH="${TEST_TMPDIR}/checkout"
  export BUILDKITE_ENV_FILE="${TEST_TMPDIR}/env"
  export MISE_DATA_DIR="${TEST_TMPDIR}/mise-data"
  export BUILDKITE_PLUGIN_MISE_VERSION="1.0.0"

  mkdir -p "${BUILDKITE_BUILD_CHECKOUT_PATH}"
  write_mise_mock "${MISE_DATA_DIR}"

  export MISE_MOCK_LOG="${TEST_TMPDIR}/mise.log"
  : > "${MISE_MOCK_LOG}"

  unset BUILDKITE_PLUGIN_MISE_CACHE_DIR
  unset BUILDKITE_PLUGIN_MISE_DIR
  unset BUILDKITE_COMPUTE_TYPE
  unset MISE_MOCK_FAIL_INSTALL
  unset MISE_HOSTED_CACHE_VOLUME_ROOT
}

write_mise_mock() {
  local data_dir="$1"

  mkdir -p "${data_dir}/bin" "${data_dir}/shims"

  cat > "${data_dir}/bin/mise" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

log_file="${MISE_MOCK_LOG:?}"
cmd="${1:-}"

case "${cmd}" in
  --version|version)
    echo "mise v1.0.0"
    ;;
  install)
    if [ "${MISE_MOCK_FAIL_INSTALL:-0}" = "1" ]; then
      echo "mock install failed" >&2
      exit 42
    fi
    echo "install pwd=${PWD} $*" >> "${log_file}"
    ;;
  env)
    if [ "${2:-}" = "--shell" ] && [ "${3:-}" = "bash" ]; then
      echo "export TEST_ENV=ok"
      echo "export PATH=\"${MISE_DATA_DIR}/installs/go/1.0.0/bin:\$PATH\""
      echo "env pwd=${PWD} $*" >> "${log_file}"
    else
      exit 1
    fi
    ;;
  *)
    echo "unexpected command: $*" >&2
    exit 1
    ;;
esac
MOCK
  chmod +x "${data_dir}/bin/mise"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

setup_install_mocks() {
  mkdir -p "${TEST_TMPDIR}/mock-bin"
  export PATH="${TEST_TMPDIR}/mock-bin:${PATH}"

  cat > "${TEST_TMPDIR}/mock-bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'mock archive'
MOCK

  cat > "${TEST_TMPDIR}/mock-bin/tar" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

dest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dest="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "${dest}/mise/bin"
cat > "${dest}/mise/bin/mise" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --version|version)
    echo "mise v1.0.0"
    ;;
  install)
    ;;
  env)
    if [ "${2:-}" = "--shell" ] && [ "${3:-}" = "bash" ]; then
      echo "export PATH=\"${MISE_DATA_DIR}/installs/go/1.0.0/bin:\$PATH\""
    else
      exit 1
    fi
    ;;
  *)
    echo "unexpected installed command: $*" >&2
    exit 1
    ;;
esac
INNER
chmod +x "${dest}/mise/bin/mise"
MOCK

  chmod +x "${TEST_TMPDIR}/mock-bin/curl" "${TEST_TMPDIR}/mock-bin/tar"
}

@test "runs install and exports shell environment from repo config" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "~~~ :mise: Setup mise" <<< "${output}"
  grep -F "install pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} install" "${MISE_MOCK_LOG}"
  grep -F "env pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} env --shell bash" "${MISE_MOCK_LOG}"
  grep -F "export TEST_ENV=ok" "${BUILDKITE_ENV_FILE}"
  grep -F "export PATH=${MISE_DATA_DIR}/bin:\$PATH" "${BUILDKITE_ENV_FILE}"
  grep -F "export PATH=\"${MISE_DATA_DIR}/installs/go/1.0.0/bin:\$PATH\"" "${BUILDKITE_ENV_FILE}"
}

@test "expands the setup log group when mise install fails" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"
  export MISE_MOCK_FAIL_INSTALL="1"

  run bash hooks/pre-command

  [ "${status}" -eq 42 ]
  grep -F "~~~ :mise: Setup mise" <<< "${output}"
  grep -F "^^^ +++" <<< "${output}"
  grep -F "mock install failed" <<< "${output}"
}

@test "exports mise environment in the hook shell" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"

  run bash -c "
    . hooks/pre-command >/dev/null
    env | grep -Fx 'TEST_ENV=ok'
    env | grep -Fx 'MISE_TRUSTED_CONFIG_PATHS=${BUILDKITE_BUILD_CHECKOUT_PATH}'
    env | grep -Fx 'MISE_YES=1'
    case \":\$PATH:\" in
      *\":${MISE_DATA_DIR}/bin:\"*) ;;
      *) exit 1 ;;
    esac
    case \":\$PATH:\" in
      *\":${MISE_DATA_DIR}/installs/go/1.0.0/bin:\"*) ;;
      *) exit 1 ;;
    esac
  "

  [ "${status}" -eq 0 ]
}

@test "puts plugin-managed mise binary on PATH before installed tool paths are exported" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  path_line="$(grep -n -F "export PATH=${MISE_DATA_DIR}/bin:\$PATH" "${BUILDKITE_ENV_FILE}" | cut -d: -f1)"
  tool_path_line="$(grep -n -F "export PATH=\"${MISE_DATA_DIR}/installs/go/1.0.0/bin:\$PATH\"" "${BUILDKITE_ENV_FILE}" | cut -d: -f1)"

  [ -n "${path_line}" ]
  [ -n "${tool_path_line}" ]
  [ "${path_line}" -lt "${tool_path_line}" ]
}

@test "uses dir config for monorepos" {
  subdir="${BUILDKITE_BUILD_CHECKOUT_PATH}/backend"
  mkdir -p "${subdir}"
  printf 'go 1.0.0\n' > "${subdir}/.tool-versions"
  export BUILDKITE_PLUGIN_MISE_DIR="${subdir}"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "install pwd=${subdir} install" "${MISE_MOCK_LOG}"
  grep -F "env pwd=${subdir} env --shell bash" "${MISE_MOCK_LOG}"
}

@test "uses local plugin dir config fallback" {
  subdir="${BUILDKITE_BUILD_CHECKOUT_PATH}/smoke"
  mkdir -p "${subdir}"
  printf 'go 1.0.0\n' > "${subdir}/.tool-versions"
  export BUILDKITE_PLUGIN__DIR="${subdir}"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "install pwd=${subdir} install" "${MISE_MOCK_LOG}"
  grep -F "env pwd=${subdir} env --shell bash" "${MISE_MOCK_LOG}"
}

@test "uses cache-dir config when MISE_DATA_DIR is unset" {
  cache_dir="${TEST_TMPDIR}/self-hosted-cache"
  unset MISE_DATA_DIR
  export BUILDKITE_PLUGIN_MISE_CACHE_DIR="${cache_dir}"
  write_mise_mock "${cache_dir}"
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "Using mise data dir: ${cache_dir} (plugin cache-dir configuration)" <<< "${output}"
  grep -F "export MISE_DATA_DIR=${cache_dir}" "${BUILDKITE_ENV_FILE}"
}

@test "uses hosted cache volume automatically when available" {
  hosted_cache_root="${TEST_TMPDIR}/hosted-cache"
  unset MISE_DATA_DIR
  export BUILDKITE_COMPUTE_TYPE="hosted"
  export MISE_HOSTED_CACHE_VOLUME_ROOT="${hosted_cache_root}"
  write_mise_mock "${hosted_cache_root}/mise"
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "Using mise data dir: ${hosted_cache_root}/mise (Buildkite hosted agent cache volume)" <<< "${output}"
  grep -F "export MISE_DATA_DIR=${hosted_cache_root}/mise" "${BUILDKITE_ENV_FILE}"
}

@test "fails when no mise config exists" {
  run bash hooks/pre-command

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"No mise config found in"* ]]
}

@test "installs mise without leaking cleanup trap state" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"
  rm -f "${MISE_DATA_DIR}/bin/mise"
  setup_install_mocks

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  [ -x "${MISE_DATA_DIR}/bin/mise" ]
  [[ "${output}" != *"archive: unbound variable"* ]]
}
