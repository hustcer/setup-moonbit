#!/usr/bin/env nu
# Author: hustcer
# Created: 2023/11/02 20:33:15
# TODO:
#   [√] Install all moon* binaries
#   [√] Support Windows, macOS, Linux
#   [√] This script should run both in Github Runners and local machines
#   [√] Setup moonbit toolchains of specified version
#   [√] Setup Moonbit Core support
# Description: Scripts for setting up MoonBit environment
# REF:
#   - https://cli.moonbitlang.com/version.json
# Usage:
#    setup moonbit
#    setup moonbit 0.1.20240910+3af041b9a

const CLI_HOST = 'https://cli.moonbitlang.com'

# It takes longer to respond to requests made with unknown/rare user agents.
# When make http post pretend to be curl, it gets a response just as quickly as curl.
export const HTTP_HEADERS = [User-Agent curl/8.9]

const VALID_VERSION_TAG = [latest, pre-release, nightly]
const ARCH_TARGET_MAP = {
  linux_x86_64: 'linux-x86_64',
  linux_aarch64: 'linux-aarch64',
  macos_x86_64: 'darwin-x86_64',
  macos_aarch64: 'darwin-aarch64',
  windows_x86_64: 'windows-x86_64',
}

export-env {
  $env.config.color_config.leading_trailing_space_bg = { attr: n }
}

# Download binary file from CLI_HOST with curl or `http get`
def fetch-release [ version: string, archive: string ] {
  let version = $version | str replace + %2B
  let assets = $'($CLI_HOST)/binaries/($version)/($archive)'
  print $'Fetch binaries from (ansi g)($assets)(ansi reset)'
  if (is-installed curl) {
    curl -O -L $assets
  } else {
    http get -H $HTTP_HEADERS $assets | save --progress --force $archive
  }
}

# Download moonbit core from CLI_HOST with curl or `http get`
def fetch-core [ version: string ] {
  if ($version not-in $VALID_VERSION_TAG) and not (is-semver $version) {
    print $'(ansi r)Invalid version: ($version)(ansi reset)'; exit 2
  }
  let url_encoded_version = $version | str replace + %2B

  let suffix = if (windows?) { $'($version).zip' } else { $'($version).tar.gz' }
  let url_encoded_suffix = if (windows?) { $'($url_encoded_version).zip' } else { $'($url_encoded_version).tar.gz' }

  let assets_url = $'($CLI_HOST)/cores/core-($url_encoded_suffix)'
  print $'Fetch core assets from (ansi g)($assets_url)(ansi reset)'
  if (is-installed curl) {
    curl -L $assets_url -o $'core-($suffix)'
  } else {
    http get -H $HTTP_HEADERS $assets_url | save --progress --force $'core-($suffix)'
  }
}

# Patch runtime.c to guard `#include <windows.h>` behind MOONBIT_NATIVE_NO_SYS_HEADER.
# The bundled TCC doesn't ship with winapi headers and the moon build tool compiles with
# -DMOONBIT_NATIVE_NO_SYS_HEADER, but the runtime still includes <windows.h> unconditionally
# for GetConsoleOutputCP/SetConsoleOutputCP used in moonbit_println. Without Visual Studio
# installed TCC can't discover system headers, causing the native target build to fail.
def patch-runtime-windows-header [libDir: string] {
  let runtime = [$libDir runtime.c] | path join
  if not ($runtime | path exists) { return }
  let content = open $runtime
  let old = "#ifdef _WIN32\n#include <windows.h>\n#endif"
  if ($content | str contains $old) {
    let new = [
      '#ifdef _WIN32'
      '#ifndef MOONBIT_NATIVE_NO_SYS_HEADER'
      '#include <windows.h>'
      '#else'
      '#define CP_UTF8 65001'
      'unsigned int GetConsoleOutputCP(void);'
      'int SetConsoleOutputCP(unsigned int);'
      '#endif'
      '#endif'
    ] | str join "\n"
    $content | str replace $old $new | save --force $runtime
    print $'(ansi g)Patched runtime.c: guarded <windows.h> behind MOONBIT_NATIVE_NO_SYS_HEADER(ansi reset)'
  }
}

# Download moonbit binary files to local
export def 'setup moonbit' [
  version?,             # The version of moonbit toolchain to setup, and `latest` by default
  --setup-core(-c),     # Setup moonbit core
  --core-version(-V): string = 'latest',  # The version of moonbit core to setup, `latest` by default
  --patch-runtime(-p),  # Patch runtime.c to fix native build on Windows without Visual Studio
] {
  let version = $version | default $env.MOONBIT_INSTALL_VERSION? | default 'latest'
  if ($version not-in $VALID_VERSION_TAG) and not (is-semver $version) {
    print $'(ansi r)Invalid version: ($version)(ansi reset)'; exit 2
  }
  let MOONBIT_HOME = $env.MOONBIT_HOME? | default ([$nu.home-dir .moon] | path join)
  let MOONBIT_BIN_DIR = [$MOONBIT_HOME bin] | path join
  let MOONBIT_LIB_DIR = [$MOONBIT_HOME lib] | path join
  let coreDir = $'($MOONBIT_LIB_DIR)/core'
  if not ($MOONBIT_BIN_DIR | path exists) { mkdir $MOONBIT_BIN_DIR }
  if not ($MOONBIT_LIB_DIR | path exists) { mkdir $MOONBIT_LIB_DIR }

  cd $MOONBIT_HOME
  let OS_INFO = $'($nu.os-info.name)_($nu.os-info.arch)'
  let archive = $ARCH_TARGET_MAP | get -o $OS_INFO
  if ($archive | is-empty) { print $'Unsupported Platform: ($OS_INFO)'; exit 2 }

  print $'(char nl)Setup moonbit toolchain of version: (ansi g)($version)(ansi reset)'; hr-line
  print $'Current moon home: (ansi g)($MOONBIT_HOME)(ansi reset)'

  # Clean up old lib and include directories before extraction to
  # avoid stale files, matching the behavior of the official install scripts
  let includeDir = [$MOONBIT_HOME include] | path join
  if ($includeDir | path exists) { rm -rf $includeDir }
  if ($MOONBIT_LIB_DIR | path exists) { rm -rf $MOONBIT_LIB_DIR }

  if (windows?) {
    fetch-release $version $'moonbit-($archive).zip'
    unzip -qo $'moonbit-($archive).zip' -d $MOONBIT_HOME
    rm moonbit*.zip
    if $patch_runtime {
      # Workaround: runtime.c includes <windows.h> without guarding it
      # behind MOONBIT_NATIVE_NO_SYS_HEADER. When TCC has no winapi headers
      # and Visual Studio is not installed, this causes the native build to
      # fail. Patch runtime.c to guard the include and provide manual
      # declarations for the required Windows API functions.
      patch-runtime-windows-header $MOONBIT_LIB_DIR
    }
  } else {
    fetch-release $version $'moonbit-($archive).tar.gz'
    tar xf $'moonbit-($archive).tar.gz' --directory $MOONBIT_HOME
    const IGNORE = []
    ls $MOONBIT_BIN_DIR
      | get name
      | where { ($in | path basename) not-in $IGNORE }
      | each { chmod +x $in }
    try { chmod +x $'($MOONBIT_BIN_DIR)/internal/tcc' } catch { print $'(ansi r)Failed to make tcc executable(ansi reset)' }
    rm moonbit*.tar.gz
  }

  # Link AGENTS.md to moon-pilot prompt if available
  let agents_src = $"($MOONBIT_HOME)/bin/internal/moon-pilot/lib/prompt/moonbitlang.mbt.md"
  if ($agents_src | path exists) {
    let agents_dst = $"($MOONBIT_HOME)/AGENTS.md"
    if ($agents_dst | path exists) { rm -f $agents_dst }
    if (windows?) {
      let agents_src_win = $"($MOONBIT_HOME)\\bin\\internal\\moon-pilot\\lib\\prompt\\moonbitlang.mbt.md"
      let agents_dst_win = $"($MOONBIT_HOME)\\AGENTS.md"
      try { ^cmd /c mklink /H $agents_dst_win $agents_src_win } catch { print $"(ansi r)Failed to create hard link for ($agents_src_win)(ansi reset)" }
    } else {
      try { ^ln -sf $agents_src $agents_dst } catch { print $"(ansi r)Failed to create symlink for ($agents_src)(ansi reset)" }
    }
  }

  print 'OS Info:'; print $nu.os-info; hr-line
  print $'Contents of ($MOONBIT_BIN_DIR):'; hr-line -b
  ls $MOONBIT_BIN_DIR | table -w 150 -t psql | print
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

    fetch-core $core_version

    if (windows?) {
      unzip -qo $'core-($core_version).zip' -d $MOONBIT_LIB_DIR; rm $'core-($core_version).zip'
    } else {
      tar xf $'core-($core_version).tar.gz' --directory $MOONBIT_LIB_DIR; rm $'core-($core_version).tar.gz'
    }
    bundle-core $coreDir $version
  }
}

# Bundle moonbit core
def bundle-core [coreDir: string, version: string] {
  let moonBin = if (windows?) { 'moon.exe' } else { 'moon' }
  print $'(char nl)Bundle moonbit core(ansi reset)'; hr-line
  try {
    ^$moonBin -C $coreDir bundle --warn-list -a --all
  } catch {
    print $'(ansi r)Failed to bundle core(ansi reset)'
  }
  try {
    ^$moonBin -C $coreDir bundle --warn-list -a --target wasm-gc --quiet
  } catch {
    print $'(ansi r)Failed to bundle core to wasm-gc(ansi reset)'
  }
  if $version != 'nightly' or (windows?) { return }
  print $'(ansi g)Bundle core for llvm backend(ansi reset)'
  try {
    ^$moonBin -C $coreDir bundle --warn-list -a --target llvm
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

export def main [
  version?,             # The version of moonbit toolchain to setup, and `latest` by default
  --setup-core(-c),     # Setup moonbit core
  --core-version(-V): string = 'latest',  # The version of moonbit core to setup, `latest` by default
  --patch-runtime(-p),  # Patch runtime.c to fix native build on Windows without Visual Studio
] {
  setup moonbit $version --setup-core=$setup_core --core-version=$core_version --patch-runtime=$patch_runtime
}
