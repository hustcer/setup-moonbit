# Changelog
All notable changes to this project will be documented in this file.

## [1.12] - 2025-03-15

### Features

- Add bundle core for llvm backend support with bleeding version (#58)

## [1.11.0] - 2025-02-17

### Features

- Add DeepSeek Code review support by `hustcer/deepseek-review`
- Add support for specifying Moonbit Core version by `core-version` input (#55)

### Miscellaneous Tasks

- Update README (#53)

### Deps

- Upgrade Nushell to v0.102 (#51)

## [1.10] - 2025-01-29

**Celebrate Chinese New Year with our festive update!** 🐉✨

### Bug Fixes

- Unzip zip ball and override existing files without prompting on Windows (#40)
- Create one and only one failed alert issue for failed jobs in daily checking (#48)

### Features

- Support setting moon home by `MOONBIT_HOME` env var (#38)

## [1.9.0] - 2025-01-08

### Bug Fixes

- Fix basic workflow error
- Fix setup moonbit scripts for the latest release (#34)

### Miscellaneous Tasks

- Add daily checking badge

### Refactor

- Remove common.nu (#30)

### Deps

- Upgrade Nu to v0.101 (#32)

## [1.8.0]

### Features

- Add nightly version support (#25)
- Add bleeding version support (#27)

### Miscellaneous Tasks

- Update daily checking workflow, add develop and main branch check

### Refactor

- Add bundle-core helper

## [1.7.0] - 2024-11-08

### Features

- Add wasm-gc bundle target for moonbit core lib (#20)
- Upgrade `Nushell` to v0.99.1

### Miscellaneous Tasks

- Change action icon from code to circle
- Quiet unzip output for Windows (#23)
- Add cspell checking hook
- Add milestone workflow (#18)

## [1.6.1] - 2024-09-16

### Features

- Add `setup-core` input support
- Add `bleeding` version support for macOS only

### Miscellaneous Tasks

- Try to remove GITHUB_TOKEN env setting

## [1.6.0] - 2024-09-16

### Bug Fixes

- Fix just fetch command
- Fix moonbit setup and release scripts

### Features

- Add download specified version of moonbit toolchains support
- Add version input to action

### Miscellaneous Tasks

- Change bin dir from ~/.moon to ~/.moon/bin
- Update Nu to v0.97.1

### Deps

- Upgrade actions/checkout and use latest version of Nu for action

## [1.5.1] - 2024-05-05

### Features

- Make sure major version tag always point to the latest semver tag that has the same major version

## [1.5] - 2024-04-27

### Features

- Add `moon_cove_report` download support for non-Windows OS

### Deps

- Upgrade to Nu v0.92.2 for the shell engine
- Upgrade setup-nu to v3.10 to fix macOS arm64 support


## [1.3] - 2024-03-07

### Bug Fixes

- Fix `aria2c` download for local Windows machine
- Fix daily checking workflow, create an issue if it fails
- Fix all workflows
- Fix `just release` task

### Features

- Add daily checking workflow to make sure `setup-moonbit` works, close #1 (#3)
- Make moonbit.nu works on both Github runners and local machine
- Use `http get` instead of `aria2c` for binary downloading when `aria2c` is not installed (#9)
- Add moondoc command

### Miscellaneous Tasks

- Use ubuntu-latest instead of ubuntu-22.04 in workflows
- Upgrade Nu to 0.91.0
- Turn off fail fast for daily workflow

## [1.2] - 2023-11-02

### Refactor

- Use modules instead of embedded scripts

## [1.1] - 2023-11-02

### Bug Fixes

- Embed scripts into action.yml

## [1.0] - 2023-11-02

### Documentation

- Add README.md

### Features

- Add setup-moonbit Action for Windows, Ubuntu and macOS support

### Miscellaneous Tasks

- Test moon new and run

