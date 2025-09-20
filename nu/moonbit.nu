#!/usr/bin/env nu
# Author: hustcer
# Created: 2023/11/02 20:33:15
# TODO:
#   [√] Install all moon* binaries
#   [√] Support Windows, macOS, Linux
#   [√] This script should run both in Github Runners and local machines
#   [√] Setup moonbit toolchains of specified version
#   [√] Setup Moonbit Core support
#   [√] Setup moonbit core of `bleeding` version support
# Description: Scripts for setting up MoonBit environment
# REF:
#   - https://cli.moonbitlang.com/version.json
# Usage:
#    setup moonbit
#    setup moonbit 0.1.20240910+3af041b9a

const CLI_HOST = 'https://cli.moonbitlang.com'

const VALID_VERSION_TAG = [latest, bleeding, pre-release, nightly]
const ARCH_TARGET_MAP = {
  linux_x86_64: 'linux-x86_64',
  macos_x86_64: 'darwin-x86_64',
  macos_aarch64: 'darwin-aarch64',
  windows_x86_64: 'windows-x86_64',
}

export-env {
  $env.config.color_config.leading_trailing_space_bg = { attr: n }
}

# Download binary file from CLI_HOST with aria2c or `http get`
def fetch-release [ version: string, archive: string ] {
  let version = $version | str replace + %2B
  print $'Fetch binaries from (ansi g)($CLI_HOST)/binaries/($version)/($archive)(ansi reset)'
  if (is-installed aria2c) {
    aria2c --allow-overwrite $'($CLI_HOST)/binaries/($version)/($archive)'
  } else {
    http get $'($CLI_HOST)/binaries/($version)/($archive)' | save --progress --force $archive
  }
}

# Download moonbit core from CLI_HOST with aria2c or `http get`
def fetch-core [ version: string ] {
  if ($version not-in $VALID_VERSION_TAG) and not (is-semver $version) {
    print $'(ansi r)Invalid version: ($version)(ansi reset)'; exit 2
  }
  let version = $version | str replace + %2B
  let suffix = if (windows?) { $'($version).zip' } else { $'($version).tar.gz' }
  if (is-installed aria2c) {
    aria2c --allow-overwrite $'($CLI_HOST)/cores/core-($suffix)'
  } else {
    http get $'($CLI_HOST)/cores/core-($suffix)' | save --progress --force $'core-($suffix)'
  }
}

# Download moonbit binary files to local
export def 'setup moonbit' [
  version?,                                # The version of moonbit toolchain to setup, default from env or `latest`
  --setup-core(-c),                        # Setup moonbit core
  --core-version(-V): string = 'latest',   # The version of moonbit core to setup, default to same as toolchain
] {
  let version = $version | default $env.MOONBIT_INSTALL_VERSION? | default 'latest'
  if ($version not-in $VALID_VERSION_TAG) and not (is-semver $version) {
    print $'(ansi r)Invalid version: ($version)(ansi reset)'; exit 2
  }
  let MOON_HOME = $env.MOON_HOME? | default ($env.MOONBIT_HOME? | default ([$nu.home-path .moon] | path join))
  let MOON_BIN_DIR = [$MOON_HOME bin] | path join
  let MOON_LIB_DIR = [$MOON_HOME lib] | path join
  let coreDir = $'($MOON_LIB_DIR)/core'
  if not ($MOON_BIN_DIR | path exists) { mkdir $MOON_BIN_DIR }
  if not ($MOON_LIB_DIR | path exists) { mkdir $MOON_LIB_DIR }

  cd $MOON_HOME
  let OS_INFO = $'($nu.os-info.name)_($nu.os-info.arch)'
  let archive = $ARCH_TARGET_MAP | get -i $OS_INFO
  if ($archive | is-empty) { print $'Unsupported Platform: ($OS_INFO)'; exit 2 }

  print $'(char nl)Setup moonbit toolchain of version: (ansi g)($version)(ansi reset)'; hr-line
  print $'Current moon home: (ansi g)($MOON_HOME)(ansi reset)'

  # Clean existing directories before extraction
  try { rm -rf $MOON_BIN_DIR } catch {}
  try { rm -rf $MOON_LIB_DIR } catch {}
  try { rm -rf $'($MOON_HOME)/include' } catch {}

  let isDev = 'MOONBIT_INSTALL_DEV' in $env

  if (windows?) {
    let zipName = if $isDev { $'moonbit-($archive)-dev.zip' } else { $'moonbit-($archive).zip' }
    fetch-release $version $zipName
    unzip -qo $zipName -d $MOON_HOME
    rm moonbit*.zip
  } else {
    let target = if $isDev { $'($archive)-dev' } else { $archive }
    let tarName = $'moonbit-($target).tar.gz'
    fetch-release $version $tarName
    tar xf $tarName --directory $MOON_HOME
    const IGNORE = []
    ls $MOON_BIN_DIR
      | get name
      | filter { ($in | path basename) not-in $IGNORE }
      | each { chmod +x $in }
    try { chmod +x $'($MOON_BIN_DIR)/internal/tcc' } catch { print $'(ansi r)Failed to make tcc executable(ansi reset)' }
    rm moonbit*.tar.gz
  }

  # Create AGENTS.md link to moon-pilot prompt if exists
  let promptPath = $'($MOON_BIN_DIR)/internal/moon-pilot/lib/prompt/moonbitlang.mbt.md'
  if ($promptPath | path exists) {
    let agentsPath = $'($MOON_HOME)/AGENTS.md'
    try { if ($agentsPath | path exists) { rm -f $agentsPath } } catch {}
    if (windows?) {
      try { ^pwsh -NoProfile -Command $"New-Item -ItemType HardLink -Path '($agentsPath)' -Value '($promptPath)'" } catch {}
    } else {
      try { ^ln -sf $promptPath $agentsPath } catch {}
    }
  }

  print 'OS Info:'; print $nu.os-info; hr-line
  print $'Contents of ($MOON_BIN_DIR):'; hr-line -b
  print (ls $MOON_BIN_DIR)
  if ('GITHUB_PATH' in $env) {
    echo $MOON_BIN_DIR  o>> $env.GITHUB_PATH
  }
  if ('Path' in $env) {
    $env.Path = ($env.Path | split row (char esep) | prepend $MOON_BIN_DIR)
  }
  if ('PATH' in $env) {
    $env.PATH = ($env.PATH | split row (char esep) | prepend $MOON_BIN_DIR)
  }

  if $setup_core {
    let real_core_version = if ($core_version == 'latest') { $version } else { $core_version }
    print $'(char nl)Setup moonbit core of version: (ansi g)($real_core_version)(ansi reset)'; hr-line
    cd $MOON_LIB_DIR; try { rm -rf $coreDir } catch {}
    if $real_core_version == 'bleeding' {
      if ($coreDir | path exists) { rm -rf $coreDir }
      try { git clone --depth 1 https://github.com/moonbitlang/core.git $coreDir } catch {
        print $'(ansi r)Failed to clone bleeding core from GitHub(ansi reset)'
      }
      bundle-core $coreDir $version
      return
    }

    fetch-core $real_core_version

    if (windows?) {
      unzip -qo $'core-($real_core_version).zip' -d $MOON_LIB_DIR; rm $'core-($real_core_version).zip'
    } else {
      tar xf $'core-($real_core_version).tar.gz' --directory $MOON_LIB_DIR; rm $'core-($real_core_version).tar.gz'
    }
    bundle-core $coreDir $version
  }
}

# Bundle moonbit core
def bundle-core [coreDir: string, version: string] {
  let moonBin = if (windows?) { 'moon.exe' } else { 'moon' }
  print $'(char nl)Bundle moonbit core(ansi reset)'; hr-line
  try {
    ^$moonBin bundle --warn-list -a --all --source-dir $coreDir
  } catch {
    print $'(ansi r)Failed to bundle core(ansi reset)'
  }
  try {
    ^$moonBin bundle --warn-list -a --target wasm-gc --source-dir $coreDir --quiet
  } catch {
    print $'(ansi r)Failed to bundle core to wasm-gc(ansi reset)'
  }
  if $version != 'nightly' or (windows?) { return }
  print $'(ansi g)Bundle core for llvm backend(ansi reset)'
  try {
    ^$moonBin bundle --warn-list -a --target llvm --source-dir $coreDir
  } catch {
    print $'(ansi r)Failed to bundle core for llvm backend(ansi reset)'
  }
}

# If current host is Windows
export def windows? [] {
  # Windows / Darwin / Linux
  (sys host | get name) == 'Windows'
}

# A custom command to check if a string is a valid SemVer version
def is-semver [version?: string] {
  let version = if ($version | is-empty) { $in } else { $version }
  if ($version | is-empty) { return false }
  # Use regex pattern to match the SemVer version string
  # The `v` prefix is not supported, add `v?` at the beginning of the regex if needed
  # ^v?(0|[1-9]\d*)\.(0|[1-9]\d*)... Keep the reset of the pattern the same
  let semver_pattern = '^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'
  # Check if the version string matches the SemVer pattern
  if $version =~ $semver_pattern { true } else { false }
  # $version | str replace --regex $semver_pattern 'match' | $in == 'match'
}

# Check if some command available in current shell
export def is-installed [ app: string ] {
  (which $app | length) > 0
}

export def hr-line [
  width?: int = 90,
  --color(-c): string = 'g',
  --blank-line(-b),
  --with-arrow(-a),
] {
  # Create a line by repeating the unit with specified times
  def build-line [
    times: int,
    unit: string = '-',
  ] {
    0..<$times | reduce -f '' { |i, acc| $unit + $acc }
  }

  print $'(ansi $color)(build-line $width)(if $with_arrow {'>'})(ansi reset)'
  if $blank_line { char nl }
}

alias main = setup moonbit
