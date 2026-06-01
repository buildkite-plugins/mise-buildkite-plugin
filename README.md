# mise Buildkite Plugin

Install [mise](https://mise.jdx.dev/), run `mise install`, and export the tool environment into the Buildkite step.

This plugin is intentionally small:

- `mise` is installed if missing or at the wrong version
- `mise install` always runs
- the plugin-managed `mise` binary is added to the command environment `PATH`
- `mise env --shell bash` is sourced in the hook and appended to `$BUILDKITE_ENV_FILE`
- command execution uses the active repository mise config exported by `mise env`

## Example

```yml
steps:
  - label: ":wrench: Test"
    plugins:
      - mise#v1.1.3:
          version: 2026.2.11
    command: go test ./...
```

## Monorepo Example

```yml
steps:
  - label: ":wrench: Test backend"
    plugins:
      - mise#v1.1.3:
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
      - mise#v1.1.3:
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

## Hosted Agent Cache Volumes

```yml
cache: ".buildkite/cache-volume"

steps:
  - label: ":wrench: Test"
    plugins:
      - mise#v1.1.3: ~
    command: go test ./...
```

When running on Buildkite hosted agents, the plugin automatically uses `/cache/bkcache/mise` as `MISE_DATA_DIR` if a cache volume is attached. Buildkite only mounts that volume when the pipeline or step defines `cache`, so you still need to request one in `pipeline.yml`.

## Configuration

- `version` (default: `latest`): mise version to install.
- `dir` (default: checkout directory): directory where `mise install` and `mise env` run.
- `cache-dir` (default: unset): directory to use for `MISE_DATA_DIR`. This is mainly useful on self-hosted agents with a persistent disk.
- `install_args` (default: unset): arguments passed directly to `mise install`, such as `node pnpm` or `node@24 pnpm@10`. These are install-only arguments; command execution still uses the environment exported from the repository mise config.

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
