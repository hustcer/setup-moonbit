#!/usr/bin/env nu
# Author: hustcer
# Created: 2023/11/02 20:33:15
# TODO:
#   [x] Install all moon* binaries
#   [x] Support Windows, macOS, Linux
#   [x] This script should run both in Github Runners and local machines
# Description: Scripts for setting up MoonBit environment

use common.nu [hr-line windows?]

const CLI_HOST = 'https://cli.moonbitlang.com'

const CLI_DOWNLOAD_PATH = {
  windows_x86_64: 'windows',
  linux_x86_64: 'ubuntu_x86',
  macos_aarch64: 'macos_m1',
  macos_x86_64: 'macos_intel',
}

export-env {
  $env.config.color_config.leading_trailing_space_bg = { attr: n }
}

# Download moonbit binary files to local
export def 'setup moonbit' [] {
  let MOONBIT_BIN_DIR = [$nu.home-path '.moon'] | path join
  const DEFAULT_BINS = ['moon', 'moonc', 'moonfmt', 'moonrun', 'mooninfo']
  const WINDOWS_BINS = ['moon.exe', 'moonc.exe', 'moonfmt.exe', 'moonrun.exe']
  mkdir $MOONBIT_BIN_DIR; cd $MOONBIT_BIN_DIR
  let OS_INFO = $'($nu.os-info.name)_($nu.os-info.arch)'
  let DOWNLOAD_PATH = $CLI_DOWNLOAD_PATH | get -i $OS_INFO
  if ($DOWNLOAD_PATH | is-empty) { echo $'Unsupported Platform: ($OS_INFO)'; exit 2 }

  if (windows?) {
    $WINDOWS_BINS | each {|it| aria2c $'($CLI_HOST)/($DOWNLOAD_PATH)/($it)' }
  } else {
    $DEFAULT_BINS | each {|it| aria2c $'($CLI_HOST)/($DOWNLOAD_PATH)/($it)'; chmod +x $it }
  }

  echo 'OS Info:'; echo $nu.os-info; hr-line
  echo $'Contents of ($MOONBIT_BIN_DIR):'; hr-line -b
  echo (ls -l $MOONBIT_BIN_DIR)
  if ('GITHUB_PATH' in $env) {
    echo $MOONBIT_BIN_DIR  | save -a $env.GITHUB_PATH
  }
}

alias main = setup moonbit
