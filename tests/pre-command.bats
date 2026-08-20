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
  unset BUILDKITE_PLUGIN_MISE_DISABLE_TOOLS_0
  unset BUILDKITE_PLUGIN_MISE_DISABLE_TOOLS_1
  unset BUILDKITE_PLUGIN_MISE_INSTALL_ARGS
  unset BUILDKITE_PLUGIN_MISE_INSTALL_SYSTEM_PACKAGES
  unset BUILDKITE_PLUGIN__DISABLE_TOOLS_0
  unset BUILDKITE_PLUGIN__DISABLE_TOOLS_1
  unset BUILDKITE_PLUGIN__INSTALL_ARGS
  unset BUILDKITE_PLUGIN__INSTALL_SYSTEM_PACKAGES
  unset BUILDKITE_COMPUTE_TYPE
  unset MISE_INSTALL_BARRIER_COUNT
  unset MISE_INSTALL_BARRIER_DIR
  unset MISE_MOCK_FAIL_INSTALL
  unset MISE_HOSTED_CACHE_VOLUME_ROOT
  unset MISE_DISABLE_TOOLS
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
    echo "install pwd=${PWD} disabled=${MISE_DISABLE_TOOLS:-} $*" >> "${log_file}"
    ;;
  system)
    if [ "${2:-}" = "install" ] && [ "${3:-}" = "--yes" ]; then
      echo "system pwd=${PWD} experimental=${MISE_EXPERIMENTAL:-} $*" >> "${log_file}"
    else
      echo "unexpected system command: $*" >&2
      exit 1
    fi
    ;;
  env)
    if [ "${2:-}" = "--shell" ] && [ "${3:-}" = "bash" ]; then
      echo "export TEST_ENV=ok"
      echo "export PATH=\"${MISE_DATA_DIR}/installs/go/1.0.0/bin:\$PATH\""
      echo "env pwd=${PWD} disabled=${MISE_DISABLE_TOOLS:-} $*" >> "${log_file}"
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
  export MISE_REAL_MV
  MISE_REAL_MV="$(command -v mv)"
  export MISE_MOCK_MV_LOG="${TEST_TMPDIR}/mv.log"
  : > "${MISE_MOCK_MV_LOG}"

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

if [ -n "${MISE_INSTALL_BARRIER_COUNT:-}" ]; then
  barrier_dir="${MISE_INSTALL_BARRIER_DIR:?}"
  marker="${barrier_dir}/ready.$$"
  : > "${marker}"

  attempts=0
  while true; do
    ready_count="$(find "${barrier_dir}" -type f -name 'ready.*' | wc -l | tr -d '[:space:]')"
    if [ "${ready_count}" -ge "${MISE_INSTALL_BARRIER_COUNT}" ]; then
      break
    fi
    attempts=$((attempts + 1))
    if [ "${attempts}" -ge 200 ]; then
      echo "timed out waiting for concurrent installs" >&2
      exit 1
    fi
    sleep 0.05
  done
fi

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

  cat > "${TEST_TMPDIR}/mock-bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${MISE_MOCK_MV_LOG:?}"
exec "${MISE_REAL_MV:?}" "$@"
MOCK

  chmod +x "${TEST_TMPDIR}/mock-bin/curl" "${TEST_TMPDIR}/mock-bin/tar" "${TEST_TMPDIR}/mock-bin/mv"
}

@test "runs install and exports shell environment from repo config" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "~~~ :mise: Setup mise" <<< "${output}"
  grep -F "install pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled= install" "${MISE_MOCK_LOG}"
  grep -F "env pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled= env --shell bash" "${MISE_MOCK_LOG}"
  grep -F "export TEST_ENV=ok" "${BUILDKITE_ENV_FILE}"
  grep -F "export PATH=${MISE_DATA_DIR}/bin:\$PATH" "${BUILDKITE_ENV_FILE}"
  grep -F "export PATH=\"${MISE_DATA_DIR}/installs/go/1.0.0/bin:\$PATH\"" "${BUILDKITE_ENV_FILE}"
}

@test "reuses cached mise without downloading" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Downloading mise"* ]]
  "${MISE_DATA_DIR}/bin/mise" --version | grep -F "mise v1.0.0"
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
  grep -F "install pwd=${subdir} disabled= install" "${MISE_MOCK_LOG}"
  grep -F "env pwd=${subdir} disabled= env --shell bash" "${MISE_MOCK_LOG}"
}

@test "uses local plugin dir config fallback" {
  subdir="${BUILDKITE_BUILD_CHECKOUT_PATH}/smoke"
  mkdir -p "${subdir}"
  printf 'go 1.0.0\n' > "${subdir}/.tool-versions"
  export BUILDKITE_PLUGIN__DIR="${subdir}"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "install pwd=${subdir} disabled= install" "${MISE_MOCK_LOG}"
  grep -F "env pwd=${subdir} disabled= env --shell bash" "${MISE_MOCK_LOG}"
}

@test "exports disable_tools as MISE_DISABLE_TOOLS for mise and commands" {
  printf 'node 24.0.0\npython 3.13.0\ngo 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"
  export BUILDKITE_PLUGIN_MISE_DISABLE_TOOLS_0="node"
  export BUILDKITE_PLUGIN_MISE_DISABLE_TOOLS_1="python"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -Fx "install pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled=node,python install" "${MISE_MOCK_LOG}"
  grep -Fx "env pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled=node,python env --shell bash" "${MISE_MOCK_LOG}"
  grep -Fx "export MISE_DISABLE_TOOLS=node\\,python" "${BUILDKITE_ENV_FILE}"
}

@test "uses local plugin disable_tools config fallback" {
  printf 'node 24.0.0\ngo 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"
  export BUILDKITE_PLUGIN__DISABLE_TOOLS_0="node"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -Fx "install pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled=node install" "${MISE_MOCK_LOG}"
  grep -Fx "export MISE_DISABLE_TOOLS=node" "${BUILDKITE_ENV_FILE}"
}

@test "passes install_args to mise install" {
  printf 'node 24.0.0\npnpm 10.0.0\nruby 3.4.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"
  export BUILDKITE_PLUGIN_MISE_INSTALL_ARGS="node pnpm@10"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "Running mise install with args: node pnpm@10" <<< "${output}"
  grep -Fx "install pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled= install node pnpm@10" "${MISE_MOCK_LOG}"
  grep -Fx "env pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled= env --shell bash" "${MISE_MOCK_LOG}"
}

@test "installs system packages before mise install when enabled" {
  printf '[tools]\ngo = "1.0.0"\n\n[system.packages]\n"apt:libssl-dev" = "latest"\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/mise.toml"
  export BUILDKITE_PLUGIN_MISE_INSTALL_SYSTEM_PACKAGES="true"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "Running mise system install --yes" <<< "${output}"
  grep -Fx "system pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} experimental=1 system install --yes" "${MISE_MOCK_LOG}"
  grep -Fx "install pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled= install" "${MISE_MOCK_LOG}"

  system_line="$(grep -n -F "system pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} experimental=1 system install --yes" "${MISE_MOCK_LOG}" | cut -d: -f1)"
  install_line="$(grep -n -F "install pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled= install" "${MISE_MOCK_LOG}" | cut -d: -f1)"

  [ "${system_line}" -lt "${install_line}" ]
}

@test "uses local plugin install_system_packages config fallback" {
  printf '[tools]\ngo = "1.0.0"\n\n[system.packages]\n"apt:libssl-dev" = "latest"\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/mise.toml"
  export BUILDKITE_PLUGIN__INSTALL_SYSTEM_PACKAGES="true"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -Fx "system pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} experimental=1 system install --yes" "${MISE_MOCK_LOG}"
}

@test "uses local plugin install_args config fallback" {
  printf 'node 24.0.0\npnpm 10.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"
  export BUILDKITE_PLUGIN__INSTALL_ARGS="node pnpm"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -Fx "install pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled= install node pnpm" "${MISE_MOCK_LOG}"
  grep -Fx "env pwd=${BUILDKITE_BUILD_CHECKOUT_PATH} disabled= env --shell bash" "${MISE_MOCK_LOG}"
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

@test "installs mise safely from five concurrent hooks" {
  local i
  local pid
  local publish_count
  local ready_count
  local staged_count
  local -a pids=()

  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"
  rm -f "${MISE_DATA_DIR}/bin/mise"
  setup_install_mocks

  export MISE_INSTALL_BARRIER_COUNT=5
  export MISE_INSTALL_BARRIER_DIR="${TEST_TMPDIR}/install-barrier"
  mkdir -p "${MISE_INSTALL_BARRIER_DIR}"

  for i in 1 2 3 4 5; do
    (
      export BUILDKITE_ENV_FILE="${TEST_TMPDIR}/env.${i}"
      export MISE_MOCK_LOG="${TEST_TMPDIR}/mise.${i}.log"
      bash hooks/pre-command > "${TEST_TMPDIR}/output.${i}" 2>&1
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "${pid}"
  done

  ready_count="$(find "${MISE_INSTALL_BARRIER_DIR}" -type f -name 'ready.*' | wc -l | tr -d '[:space:]')"
  [ "${ready_count}" -eq 5 ]
  [ -x "${MISE_DATA_DIR}/bin/mise" ]
  "${MISE_DATA_DIR}/bin/mise" --version | grep -F "mise v1.0.0"

  publish_count="$(grep -Fc -- "-f ${MISE_DATA_DIR}/bin/.mise." "${MISE_MOCK_MV_LOG}")"
  [ "${publish_count}" -eq 5 ]
  staged_count="$(find "${MISE_DATA_DIR}/bin" -type f -name '.mise.*' | wc -l | tr -d '[:space:]')"
  [ "${staged_count}" -eq 0 ]
}

@test "reinstalls mise when the cached binary cannot execute" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"

  # Simulate a corrupt cached binary that exits 126 ("command invoked
  # cannot execute") whenever it's run — e.g. arch mismatch, partial
  # download, or a permissions issue with a binfmt handler.
  cat > "${MISE_DATA_DIR}/bin/mise" <<'BROKEN'
#!/usr/bin/env bash
exit 126
BROKEN
  chmod +x "${MISE_DATA_DIR}/bin/mise"

  setup_install_mocks

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "Downloading mise v1.0.0" <<< "${output}"
  # The reinstalled binary must be the working one written by the tar mock.
  "${MISE_DATA_DIR}/bin/mise" --version | grep -F "mise v1.0.0"
}

@test "downloads musl build when ldd version output exits non-zero" {
  printf 'go 1.0.0\n' > "${BUILDKITE_BUILD_CHECKOUT_PATH}/.tool-versions"
  rm -f "${MISE_DATA_DIR}/bin/mise"
  setup_install_mocks

  cat > "${TEST_TMPDIR}/mock-bin/uname" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -s)
    echo "Linux"
    ;;
  -m)
    echo "x86_64"
    ;;
  *)
    exit 1
    ;;
esac
MOCK

  cat > "${TEST_TMPDIR}/mock-bin/ldd" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

echo "musl libc (x86_64)"
exit 1
MOCK

  chmod +x "${TEST_TMPDIR}/mock-bin/uname" "${TEST_TMPDIR}/mock-bin/ldd"

  run bash hooks/pre-command

  [ "${status}" -eq 0 ]
  grep -F "Downloading mise v1.0.0 for linux-x64-musl" <<< "${output}"
}
