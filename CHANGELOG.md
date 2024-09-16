# Changelog
All notable changes to this project will be documented in this file.

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

- Make sure major vesion tag always point to the latest semver tag that has the same major version

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
- Use `http get` instead of `aria2c` for binary downloading when `aira2c` is not installed (#9)
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

