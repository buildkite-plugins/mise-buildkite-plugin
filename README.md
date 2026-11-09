# mise Buildkite Plugin

Install [mise](https://mise.jdx.dev/), run `mise install`, and export the tool environment into the Buildkite step.

This plugin is intentionally small:

- `mise` is installed if missing or at the wrong version
- `mise install --quiet` always runs
- `mise system install --yes` can run before `mise install` when explicitly enabled
- the plugin-managed `mise` binary is added to the command environment `PATH`
- `mise env --shell bash` is sourced in the hook and appended to `$BUILDKITE_ENV_FILE`
- command execution uses the active repository mise config exported by `mise env`

## Example

```yml
steps:
  - label: ":wrench: Test"
    plugins:
      - mise#v1.1.5:
          version: 2026.10.17
    command: go test ./...
```

## Monorepo Example

```yml
steps:
  - label: ":wrench: Test backend"
    plugins:
      - mise#v1.1.5:
          dir: backend
    command: go test ./...
```

## Install Args

For steps that only need part of a shared mise config, use `install_args` to pass
arguments directly to `mise install`:

```yml
steps:
  - label: ":react: Frontend"
    plugins:
      - mise#v1.1.5:
          install_args: node pnpm
    command: pnpm test
```

Bare tool names use versions from the repository config when present. Versioned
arguments such as `node@24 pnpm@10` are also valid `mise install` arguments,
but they only affect what gets installed. Later commands still use the
environment exported by `mise env --shell bash`, so the active versions come
from the repository mise config. When `install_args` is omitted, the existing
behavior is preserved: `mise install` runs with no arguments and installs
everything in the config file.

## System Packages

mise can install machine-global packages declared in `[system.packages]` with
`mise system install --yes`. This plugin keeps that behavior opt-in because
system packages can mutate the agent host or container.

```toml
[system.packages]
"apt:libssl-dev" = "latest"
```

```yml
steps:
  - label: ":wrench: Test"
    plugins:
      - mise#v1.1.5:
          install_system_packages: true
    command: go test ./...
```

When enabled, the hook runs `mise system install --yes` with `MISE_EXPERIMENTAL=1`
before the normal `mise install`. On CI containers that run as root this
installs without prompts; on non-root Linux agents, mise may use `sudo`
according to its normal system package behavior.

## Hosted Agent Cache Volumes

```yml
cache: ".buildkite/cache-volume"

steps:
  - label: ":wrench: Test"
    plugins:
      - mise#v1.1.5: ~
    command: go test ./...
```

When running on Buildkite hosted agents, the plugin automatically uses `/cache/bkcache/mise` as `MISE_DATA_DIR` if a cache volume is attached. Buildkite only mounts that volume when the pipeline or step defines `cache`, so you still need to request one in `pipeline.yml`.

## Buildkite Cache

```yml
steps:
  - label: ":wrench: Test"
    plugins:
      - mise#v1.1.5:
          cache: true
    command: go test ./...
```

With `cache: true`, the plugin saves and restores the mise data dir with
[Buildkite Cache](https://buildkite.com/docs/pipelines/configure/cache). It
generates its own cache config, so the repository doesn't need a
`.buildkite/cache.yml`. The cache key is made of:

- the mise platform, such as `linux-x64` or `linux-x64-musl`
- the mise version the plugin installs, including the version `latest` resolves to
- a checksum of whichever of `mise.toml`, `.mise.toml`, `.tool-versions`, `mise.lock` and `.mise.lock` exist in `dir`

The mise version is the fallback limit. A new mise version starts with an empty
cache, while a config or lockfile change restores the newest cache for the same
mise version, and `mise install` adds only what changed.

The hook restores the cache before checking the mise binary, so a warm cache
needs no download from GitHub. It saves the cache after `mise install`. Saving
is skipped when the exact key already exists, and cache misses or errors don't
fail the build. Use [cache registry policies](https://buildkite.com/docs/pipelines/configure/cache#manage-cache-registries-configure-a-cache-policy)
to control which builds can save entries that other builds restore.

Requirements and caveats:

- Jobs must run on clustered agents with Buildkite agent v4.0.3 or later. Self-hosted agents also need `BUILDKITE_AGENT_CACHE_STORE_URL`.
- A restore replaces the whole data dir. The hosted agent cache volume is shared between jobs, so `cache: true` doesn't use it. Don't point `MISE_DATA_DIR` or `cache-dir` at a directory that concurrent jobs share, such as when several agents on one host run as the same user.

## Concurrent Jobs

Jobs using the same mise version can safely bootstrap the plugin-managed binary
in a shared `MISE_DATA_DIR`. Downloads are staged there and moved into place
atomically.

There is still only one mise binary at `$MISE_DATA_DIR/bin/mise`. Jobs using
different versions can replace it while another job is running. The plugin
doesn't lock `mise install`, either, so concurrent tool installs depend on mise
and the tool backend. Use separate data directories if you need isolation.

## Configuration

- `version` (default: `latest`): mise version to install. `latest` is resolved on each hook invocation; a cached binary is replaced when its version differs. Explicit pins are honored, including older versions.
- `dir` (default: checkout directory): directory where `mise install` and `mise env` run.
- `cache` (default: `false`): save and restore the mise data dir with Buildkite Cache. See [Buildkite Cache](#buildkite-cache).
- `cache-dir` (default: unset): directory to use for `MISE_DATA_DIR`. This is mainly useful on self-hosted agents with a persistent disk.
- `install_args` (default: unset): arguments passed directly to `mise install`, such as `node pnpm` or `node@24 pnpm@10`. These are install-only arguments; command execution still uses the environment exported from the repository mise config.
- `install_system_packages` (default: `false`): run `mise system install --yes` before `mise install`.

The agent’s host `curl` and CA trust must be kept up to date for bootstrap downloads.
The plugin does not upgrade explicitly pinned mise versions or audit tools selected
by your repository’s mise configuration.

## Repo Requirements

The target directory must contain one of:

- `mise.toml`
- `.mise.toml`
- `.tool-versions`

`MISE_DATA_DIR` still takes precedence over plugin configuration. Advanced `mise` behavior should otherwise be configured with normal step environment variables such as `MISE_LOG_LEVEL` or `MISE_EXPERIMENTAL`.

## Development

Run plugin checks locally:

```bash
mise install
docker run --rm -v "$PWD:/plugin" -w /plugin buildkite/plugin-linter --id mise --path /plugin
docker run --rm -v "$PWD:/plugin" -w /plugin buildkite/plugin-tester
"$(mise where shellcheck@0.11.0)/shellcheck-v0.11.0/shellcheck" hooks/pre-command tests/pre-command.bats
```
