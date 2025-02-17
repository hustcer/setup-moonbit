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
# Usage:
#    setup moonbit
#    setup moonbit 0.1.20240910+3af041b9a

const CLI_HOST = 'https://cli.moonbitlang.com'

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
  version: string = 'latest',   # The version of moonbit toolchain to setup, and `latest` by default
  --setup-core(-c),             # Setup moonbit core
  --core-version(-V),           # The version of moonbit core to setup, `latest` by default
] {
  let MOONBIT_HOME = $env.MOONBIT_HOME? | default ([$nu.home-path .moon] | path join)
  let MOONBIT_BIN_DIR = [$MOONBIT_HOME bin] | path join
  let MOONBIT_LIB_DIR = [$MOONBIT_HOME lib] | path join
  let coreDir = $'($MOONBIT_LIB_DIR)/core'
  if not ($MOONBIT_BIN_DIR | path exists) { mkdir $MOONBIT_BIN_DIR }
  if not ($MOONBIT_LIB_DIR | path exists) { mkdir $MOONBIT_LIB_DIR }

  cd $MOONBIT_HOME
  let OS_INFO = $'($nu.os-info.name)_($nu.os-info.arch)'
  let archive = $ARCH_TARGET_MAP | get -i $OS_INFO
  if ($archive | is-empty) { print $'Unsupported Platform: ($OS_INFO)'; exit 2 }

  print $'(char nl)Setup moonbit toolchain of version: (ansi g)($version)(ansi reset)'; hr-line
  print $'Current moon home: (ansi g)($MOONBIT_HOME)(ansi reset)'

  if (windows?) {
    fetch-release $version $'moonbit-($archive).zip'
    unzip -qo $'moonbit-($archive).zip' -d $MOONBIT_HOME
    rm moonbit*.zip
  } else {
    fetch-release $version $'moonbit-($archive).tar.gz'
    tar xf $'moonbit-($archive).tar.gz' --directory $MOONBIT_HOME
    const IGNORE = []
    ls $MOONBIT_BIN_DIR
      | get name
      | filter { ($in | path basename) not-in $IGNORE }
      | each { chmod +x $in }
    try { chmod +x $'($MOONBIT_BIN_DIR)/internal/tcc' } catch { print $'(ansi r)Failed to make tcc executable(ansi reset)' }
    rm moonbit*.tar.gz
  }

  print 'OS Info:'; print $nu.os-info; hr-line
  print $'Contents of ($MOONBIT_BIN_DIR):'; hr-line -b
  print (ls $MOONBIT_BIN_DIR)
  if ('GITHUB_PATH' in $env) {
    echo $MOONBIT_BIN_DIR  o>> $env.GITHUB_PATH
  }
  if ('Path' in $env) {
    $env.Path = ($env.Path | split row (char esep) | prepend $MOONBIT_BIN_DIR)
  }
  if ('PATH' in $env) {
    $env.PATH = ($env.PATH | split row (char esep) | prepend $MOONBIT_BIN_DIR)
  }

  if $setup_core {
    print $'(char nl)Setup moonbit core of version: (ansi g)($core_version)(ansi reset)'; hr-line
    cd $MOONBIT_LIB_DIR; rm -rf ./core/*
    if $core_version == 'bleeding' {
      if ($coreDir | path exists) { rm -rf $coreDir }
      git clone --depth 1 https://github.com/moonbitlang/core.git $coreDir
      bundle-core $coreDir
      return
    }

    fetch-core $core_version

    if (windows?) {
      unzip -qo core*.zip -d $MOONBIT_LIB_DIR; rm core*.zip
    } else {
      tar xf core*.tar.gz --directory $MOONBIT_LIB_DIR; rm core*.tar.gz
    }
    bundle-core $coreDir
  }
}

# Bundle moonbit core
def bundle-core [coreDir: string] {
  let moonBin = if (windows?) { 'moon.exe' } else { 'moon' }
  print $'(char nl)Bundle moonbit core(ansi reset)'; hr-line
  try {
    ^$moonBin bundle --all --source-dir $coreDir
  } catch {
    print $'(ansi red)Failed to bundle core(ansi reset)'
  }
  try {
    ^$moonBin bundle --target wasm-gc --source-dir $coreDir --quiet
  } catch {
    print $'(ansi red)Failed to bundle core to wasm-gc(ansi reset)'
  }
}

# If current host is Windows
export def windows? [] {
  # Windows / Darwin / Linux
  (sys host | get name) == 'Windows'
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
