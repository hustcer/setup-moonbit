# Changelog
All notable changes to this project will be documented in this file.

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

