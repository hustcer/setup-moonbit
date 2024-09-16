#!/usr/bin/env nu
# Author: hustcer
# Created: 2023/11/02 20:33:15
# TODO:
#   [x] Install all moon* binaries
#   [x] Support Windows, macOS, Linux
#   [x] This script should run both in Github Runners and local machines
# Description: Scripts for setting up MoonBit environment
# Usage:
#    setup moonbit
#    setup moonbit 0.1.20240910+3af041b9a

use common.nu [hr-line windows? is-installed]

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

# Download binary file from CLI_HOST with aira2c or `http get`
def fetch-release [ version: string, archive: string ] {
  let version = $version | str replace + %2B
  if (is-installed aria2c) {
    aria2c --allow-overwrite $'($CLI_HOST)/binaries/($version)/($archive)'
  } else {
    http get $'($CLI_HOST)/binaries/($version)/($archive)' | save --progress --force $archive
  }
}

# Download moonbit binary files to local
export def 'setup moonbit' [version: string = 'latest'] {
  let MOONBIT_BIN_DIR = [$nu.home-path .moon bin] | path join
  mkdir $MOONBIT_BIN_DIR; cd $MOONBIT_BIN_DIR
  let OS_INFO = $'($nu.os-info.name)_($nu.os-info.arch)'
  let archive = $ARCH_TARGET_MAP | get -i $OS_INFO
  if ($archive | is-empty) { print $'Unsupported Platform: ($OS_INFO)'; exit 2 }

  if (windows?) {
    fetch-release $version $'moonbit-($archive).zip'
    unzip $'moonbit-($archive).zip' -d $MOONBIT_BIN_DIR
    rm moonbit*.zip
  } else {
    fetch-release $version $'moonbit-($archive).tar.gz'
    tar xf $'moonbit-($archive).tar.gz' --directory $MOONBIT_BIN_DIR
    ls $MOONBIT_BIN_DIR | get name | each { chmod u+x $in }
    rm moonbit*.tar.gz
  }

  print 'OS Info:'; print $nu.os-info; hr-line
  print $'Contents of ($MOONBIT_BIN_DIR):'; hr-line -b
  print (ls $MOONBIT_BIN_DIR)
  if ('GITHUB_PATH' in $env) {
    echo $MOONBIT_BIN_DIR  o>> $env.GITHUB_PATH
  }
}

alias main = setup moonbit
