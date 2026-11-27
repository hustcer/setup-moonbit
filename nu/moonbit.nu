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

use download.nu fetch-archive
export use download.nu HTTP_HEADERS

const CLI_HOST = 'https://cli.moonbitlang.com'
const WINDOWS_PUBLISHER = path self publish-windows.ps1
const TOOLCHAIN_DIRS = [bin lib include]

const VALID_VERSION_TAG = [latest, pre-release, nightly]
const ARCH_TARGET_MAP = {
  linux_x86_64: 'linux-x86_64',
  linux_aarch64: 'linux-aarch64',
  macos_aarch64: 'darwin-aarch64',
  windows_x86_64: 'windows-x86_64',
  # ARM64 Windows runs the x86_64 build via emulation, matching the official install scripts
  windows_aarch64: 'windows-x86_64',
}

export-env {
  $env.config.color_config.leading_trailing_space_bg = { attr: n }
}

def extract-archive [archive: string, destination: string] {
  let result = if (windows?) {
    ^unzip -qo $archive -d $destination | complete
  } else {
    ^tar xf $archive --directory $destination | complete
  }
  $result | require-success $'Failed to extract ($archive)'
}

def require-success [message: string]: record -> nothing {
  let result = $in
  if $result.exit_code != 0 {
    let details = [$result.stderr $result.stdout] | each { str trim } | where { is-not-empty } | str join (char nl)
    if ($details | is-empty) {
      error make {msg: $message}
    }
    error make {msg: $message, help: $details}
  }
}

def toolchain-env [root: string, bin_dir: string, suffix: string]: nothing -> record {
  {
    MOON_HOME: $root
    MOON_TOOLCHAIN_ROOT: $root
    MOONC_OVERRIDE: ([$bin_dir $'moonc($suffix)'] | path join)
    MOONRUN_OVERRIDE: ([$bin_dir $'moonrun($suffix)'] | path join)
    PATH: ($env.PATH | prepend $bin_dir)
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
    print $'(ansi g)Patched runtime.c: guarded <windows.h> behind MOONBIT_NATIVE_NO_SYS_HEADER(ansi rst)'
  }
}

# Download moonbit binary files to local
export def 'setup moonbit' [
  version?,             # The version of moonbit toolchain to setup, and `latest` by default
  --setup-core(-c),     # Setup moonbit core
  --core-version(-V): string = 'latest',  # The version of moonbit core to setup, `latest` by default
  --patch-runtime(-p),  # Patch runtime.c to fix native build on Windows without Visual Studio
] {
  let version = $version | default --empty $env.MOONBIT_INSTALL_VERSION? | default --empty 'latest'
  if ($version not-in $VALID_VERSION_TAG) and not (is-semver $version) {
    print $'(ansi r)Invalid version: ($version)(ansi rst)'; exit 2
  }
  if $setup_core and ($core_version not-in $VALID_VERSION_TAG) and not (is-semver $core_version) {
    print $'(ansi r)Invalid version: ($core_version)(ansi rst)'; exit 2
  }
  let MOONBIT_HOME = $env.MOONBIT_HOME? | default --empty ([$nu.home-dir .moon] | path join) | path expand
  let MOONBIT_BIN_DIR = [$MOONBIT_HOME bin] | path join
  let OS_INFO = $'($nu.os-info.name)_($nu.os-info.arch)'
  let archive = $ARCH_TARGET_MAP | get -o $OS_INFO
  if ($archive | is-empty) { print $'Unsupported Platform: ($OS_INFO)'; exit 2 }
  # Download dev channel binaries (e.g. moonbit-darwin-aarch64-dev.tar.gz) when
  # MOONBIT_INSTALL_DEV is set to a non-empty value, matching the official install scripts
  let archive = if ($env.MOONBIT_INSTALL_DEV? | is-empty) { $archive } else { $'($archive)-dev' }

  print $'(char nl)Setup moonbit toolchain of version: (ansi g)($version)(ansi rst)'; hr-line
  print $'Current moon home: (ansi g)($MOONBIT_HOME)(ansi rst)'

  mkdir $MOONBIT_HOME
  # Keep preparation off the live paths and on the same filesystem as the final install.
  let work_dir = mktemp --directory --tmpdir-path $MOONBIT_HOME '.setup-moonbit.XXXXXXXX'
  let staged = [$work_dir toolchain] | path join
  let backup = [$work_dir backup] | path join
  try {
    mkdir $staged $backup
    prepare-toolchain $work_dir $staged $archive $version $core_version $setup_core $patch_runtime
    install-toolchain $staged $backup $MOONBIT_HOME
  } finally {
    # Retain any original files that could not be restored.
    let keep_backup = if (windows?) {
      [$backup .publish-pending] | path join | path exists
    } else {
      ($backup | path exists) and (ls -a $backup | is-not-empty)
    }
    if not $keep_backup { rm --permanent -rf $work_dir }
  }

  print 'OS Info:'; print $nu.os-info; hr-line
  print $'Contents of ($MOONBIT_BIN_DIR):'; hr-line -b
  ls $MOONBIT_BIN_DIR | table -w 150 -t psql | print
  if ('GITHUB_PATH' in $env) {
    echo $MOONBIT_BIN_DIR  o>> $env.GITHUB_PATH
  }

  print $'(char nl)(ansi g)moonbit was installed successfully to ($MOONBIT_HOME)(ansi rst)'
  print 'To verify the downloaded binaries, check https://www.moonbitlang.com/download#verifying-binaries for instructions.'
  print "To know how to add shell completions, run 'moon shell-completion --help'"

  let suffix = if (windows?) { '.exe' } else { '' }
  let moon_bin = [$MOONBIT_BIN_DIR $'moon($suffix)'] | path join
  with-env (toolchain-env $MOONBIT_HOME $MOONBIT_BIN_DIR $suffix) {
    print $'(ansi g)Moonbit toolchain version details:(ansi rst)'
    ^$moon_bin version --all
  }
}

def prepare-toolchain [
  work_dir: string, staged: string, target: string, version: string,
  core_version: string, setup_core: bool, patch_runtime: bool,
] {
  cd $work_dir
  let bin_dir = [$staged bin] | path join
  let lib_dir = [$staged lib] | path join
  let on_windows = windows?
  let suffix = if $on_windows { '.exe' } else { '' }
  let moon_bin = [$bin_dir $'moon($suffix)'] | path join
  let staged_env = toolchain-env $staged $bin_dir $suffix
  let extension = if $on_windows { 'zip' } else { 'tar.gz' }
  let archive = $'moonbit-($target).($extension)'
  let encoded_version = $version | str replace + %2B
  let download_cache = [($work_dir | path dirname) .setup-moonbit-downloads] | path join
  fetch-archive $'($CLI_HOST)/binaries/($encoded_version)/($archive)' $archive $download_cache
  extract-archive $archive $staged
  for name in $TOOLCHAIN_DIRS {
    if ([$staged $name] | path join | path type) != 'dir' {
      error make {msg: $'Expected a directory named ($name) in ($archive)'}
    }
  }
  for binary in [$moon_bin $staged_env.MOONC_OVERRIDE $staged_env.MOONRUN_OVERRIDE] {
    if ($binary | path type) != 'file' {
      error make {msg: $'Expected an executable file named ($binary | path basename) in ($archive)'}
    }
  }

  # Link moonx to moon, matching the behavior of the official install scripts.
  if $on_windows {
    if $patch_runtime { patch-runtime-windows-header $lib_dir }
    ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $WINDOWS_PUBLISHER -Staged $staged -CreateAlias |
      complete | require-success 'Failed to create the moonx.exe hard link'
  } else {
    ^chmod +x ...(ls $bin_dir | get name)
    let tcc = [$bin_dir internal tcc] | path join
    if ($tcc | path exists) { ^chmod +x $tcc }
    let moonx = [$bin_dir moonx] | path join
    if ($moonx | path type) == 'dir' {
      error make {msg: $'Cannot create the moonx symlink over directory ($moonx)'}
    }
    ^ln -sfn moon $moonx | complete | require-success 'Failed to create the moonx symlink'
  }

  with-env $staged_env {
    let version_result = try {
      ^$moon_bin version --all | complete
    } catch {|err|
      error make {msg: 'Failed to start the staged Moon executable', help: $err.msg}
    }
    $version_result | require-success 'Failed to run the staged Moon executable'
  }

  let core_dir = [$lib_dir core] | path join
  if $setup_core {
    print $'(char nl)Setup moonbit core of version: (ansi g)($core_version)(ansi rst)'; hr-line
    let encoded_core_version = $core_version | str replace + %2B
    let core_archive = $'core-($core_version).($extension)'
    fetch-archive $'($CLI_HOST)/cores/core-($encoded_core_version).($extension)' $core_archive $download_cache
    rm --permanent -rf $core_dir
    extract-archive $core_archive $lib_dir
    if ($core_dir | path type) != 'dir' {
      error make {msg: $'Expected a core directory in ($core_archive)'}
    }
    with-env ($staged_env | insert MOON_CORE_OVERRIDE $core_dir) {
      bundle-core $moon_bin $core_dir $version
    }
  }
}

def plan-install [staged: string, install_dir: string, backup: string, replace: list<string> = []] {
  let staged_entries = ls -a $staged | get name | path basename
  let names = $replace | append $staged_entries | uniq
  $names | each { |name|
    let incoming = [$staged $name] | path join
    let installed = [$install_dir $name] | path join
    let previous = [$backup $name] | path join
    let installed_type = $installed | path type | default 'missing'
    let incoming_is_dir = ($incoming | path type) == 'dir'
    let installed_is_dir = $installed_type == 'dir'
    let merge = $name not-in $replace
    if $merge and $installed_type != 'missing' and $installed_is_dir != $incoming_is_dir {
      error make {msg: $'Cannot replace ($installed) because only one entry is a directory'}
    }
    if $merge and $installed_is_dir {
      # Only replace paths that belong to the release when merging directories such as bin.
      plan-install $incoming $installed $previous
    } else {
      [{incoming: $incoming, installed: $installed, previous: $previous, publish: ($name in $staged_entries)}]
    }
  } | flatten
}

def install-toolchain [staged: string, backup: string, install_dir: string] {
  if (windows?) {
    ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $WINDOWS_PUBLISHER -Staged $staged -Backup $backup -InstallDir $install_dir |
      complete | require-success 'Failed to publish the MoonBit toolchain on Windows'
    return
  }
  let lock_path = [$install_dir .setup-moonbit-lock] | path join
  let lock = ^mkdir -- $lock_path | complete
  $lock | require-success $'Cannot acquire installation lock at ($lock_path). Wait for any other install to finish, or remove this lock if a previous run was interrupted.'
  try {
    for name in $TOOLCHAIN_DIRS {
      let live_path = [$install_dir $name] | path join
      if ($live_path | path type) not-in [null dir] {
        error make {msg: $'Cannot replace ($live_path) with a directory'}
      }
    }
    let entries = plan-install $staged $install_dir $backup [lib include]
    try {
      for entry in $entries {
        if ($entry.installed | path type) != null {
          mkdir ($entry.previous | path dirname)
          mv $entry.installed $entry.previous
        }
        if $entry.publish { mv $entry.incoming $entry.installed }
      }
    } catch { |err|
      let restore_errors = $entries | reverse | each { |entry|
        try {
          if $entry.publish and ($entry.incoming | path type) == null and ($entry.installed | path type) != null {
            mv $entry.installed $entry.incoming
          }
          if ($entry.previous | path type) != null {
            if ($entry.installed | path type) != null {
              error make {msg: $'Target path still exists: ($entry.installed)'}
            }
            mv $entry.previous $entry.installed
          }
        } catch { |restore_err|
          $'($entry.installed): ($restore_err.msg)'
        }
      } | compact
      if ($restore_errors | is-not-empty) {
        error make {
          msg: 'Failed to replace and restore the MoonBit toolchain'
          help: ([$err.msg $'Backup directory: ($backup)' ...$restore_errors] | str join (char nl))
        }
      }
      rm --permanent -rf $backup
      error make {msg: 'Failed to replace the MoonBit toolchain', help: $err.msg}
    }
    rm --permanent -rf $backup
  } finally {
    rm --permanent -rf $lock_path
  }
}

# Bundle moonbit core
def bundle-core [moon_bin: string, core_dir: string, version: string] {
  print $'(char nl)Bundle moonbit core(ansi rst)'; hr-line
  ^$moon_bin -C $core_dir bundle --warn-list -a --all | complete | require-success 'Failed to bundle core'
  ^$moon_bin -C $core_dir bundle --warn-list -a --target wasm-gc --quiet | complete | require-success 'Failed to bundle core to wasm-gc'
  if $version != 'nightly' or (windows?) { return }
  print $'(ansi g)Bundle core for llvm backend(ansi rst)'
  ^$moon_bin -C $core_dir bundle --warn-list -a --target llvm | complete | require-success 'Failed to bundle core for llvm backend'
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

  print $'(ansi $color)(build-line $width)(if $with_arrow {'>'})(ansi rst)'
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
