use std/assert

def run-installer [installer: path, ...args: string] {
  ^nu --no-config-file $installer ...$args | complete
}

def assert-diagnostic [stderr: string, expected: string] {
  # At very narrow widths even individual words can span diagnostic continuation lines.
  let message = $stderr | ansi strip | str replace --all --regex '[\s|│]+' ''
  let phrase = $expected | str replace --all --regex '\s+' ''
  assert ($message | str contains $phrase) $stderr
}

# Run on Unix, where a Nushell script with a shebang can stand in for curl.
def main [installer: path] {
  let installer = $installer | path expand
  let work_dir = mktemp --directory
  try {
    let installed = [$work_dir installed] | path join
    let payload = [$work_dir payload] | path join
    let core_payload = [$work_dir core-payload] | path join
    let mocks = [$work_dir mocks] | path join
    let archive = [$work_dir toolchain.tar.gz] | path join
    let core_archive = [$work_dir core.tar.gz] | path join
    let incomplete_archive = [$work_dir incomplete.tar.gz] | path join
    let incomplete_core = [$work_dir incomplete-core.tar.gz] | path join
    let invalid_alias_archive = [$work_dir invalid-alias.tar.gz] | path join
    let invalid_moon_archive = [$work_dir invalid-moon.tar.gz] | path join
    let conflicting_archive = [$work_dir conflicting.tar.gz] | path join
    let moon = [$installed bin moon] | path join
    let core = [$installed lib core moon.mod] | path join
    let stale_lib = [$installed lib stale] | path join
    let stale_include = [$installed include stale] | path join
    let custom_tool = [$installed bin internal custom-tool] | path join
    let custom_link = [$work_dir custom-link] | path join
    let observed = [$work_dir observed.nuon] | path join
    mkdir ($custom_tool | path dirname) ($core | path dirname) ($stale_include | path dirname) ([$payload bin internal] | path join) ([$payload lib] | path join) ([$payload include] | path join) ([$core_payload core] | path join) $mocks
    'old moon' | save $moon
    'old core' | save $core
    'stale lib' | save $stale_lib
    'stale include' | save $stale_include
    'custom tool' | save $custom_tool
    ^ln $custom_tool $custom_link
    'old bundled tool' | save ([$installed bin internal bundled-tool] | path join)
    let old_bin = [$installed bin] | path join
    let payload_bin = [$payload bin] | path join
    for name in [moonc moonrun] {
      let old_binary = [$old_bin $name] | path join
      ['#!/bin/sh' 'echo old'] | str join (char nl) | save $old_binary
      ^chmod +x $old_binary
      ['#!/bin/sh' 'echo staged'] | str join (char nl) | save ([$payload_bin $name] | path join)
    }
    [
      '#!/usr/bin/env -S nu --no-config-file'
      'def --wrapped main [...args: string] {'
      '  if $args == ["version" "--all"] {'
      '    let bin = [$env.MOON_HOME bin] | path join'
      '    if $env.MOONC_OVERRIDE? != ([$bin moonc] | path join) { exit 3 }'
      '    if $env.MOONRUN_OVERRIDE? != ([$bin moonrun] | path join) { exit 3 }'
      '    print "test toolchain version"'
      '    return'
      '  }'
      '  if $env.TEST_MOON_FAIL_STDOUT? == "1" {'
      '    print "bundle failed on stdout"'
      '    exit 1'
      '  }'
      '}'
    ] | str join (char nl) | save ([$payload bin moon] | path join)
    'new bundled tool' | save ([$payload bin internal bundled-tool] | path join)
    'new runtime' | save ([$payload lib runtime.c] | path join)
    'new header' | save ([$payload include moonbit.h] | path join)
    'new core' | save ([$core_payload core moon.mod] | path join)
    ^tar -czf $archive -C $payload bin lib include
    ^tar -czf $core_archive -C $core_payload core
    ^tar -czf $incomplete_archive -C $payload bin
    ^tar -czf $incomplete_core -C $payload lib
    let payload_moonx = [$payload bin moonx] | path join
    mkdir $payload_moonx
    ^tar -czf $invalid_alias_archive -C $payload bin lib include
    rm --permanent -rf $payload_moonx
    let payload_moon = [$payload bin moon] | path join
    let valid_moon = open --raw $payload_moon
    'invalid executable' | save --force $payload_moon
    ^tar -czf $invalid_moon_archive -C $payload bin lib include
    $valid_moon | save --force $payload_moon
    let internal = [$payload bin internal] | path join
    mv $internal ([$work_dir payload-internal] | path join)
    'unexpected replacement' | save $internal
    ^tar -czf $conflicting_archive -C $payload bin lib include

    let curl = [$mocks curl] | path join
    [
      '#!/usr/bin/env -S nu --no-config-file'
      'def --wrapped main [...args: string] {'
      '  let url = $args | last'
      '  let out_idx = $args | enumerate | where item == "-o" | get index.0'
      '  let archive = $args | get ($out_idx + 1)'
      '  if $env.TEST_DOWNLOAD in ["core" "bundle-fail" "success"] and ($url | str contains "/binaries/") {'
      '    cp $env.TEST_ARCHIVE $archive'
      '    return'
      '  }'
      '  if $env.TEST_DOWNLOAD == "bundle-fail" and ($url | str contains "/cores/") {'
      '    cp $env.TEST_CORE_ARCHIVE $archive'
      '    return'
      '  }'
      '  "partial download" | save $archive'
      '  let moon = try { open --raw $env.TEST_MOON } catch { null }'
      '  let core = try { open --raw $env.TEST_CORE } catch { null }'
      '  [$moon $core] | to nuon | save $env.TEST_OBSERVED'
      '  exit 18'
      '}'
    ] | str join (char nl) | save $curl
    ^chmod +x $curl

    with-env {
      PATH: ($env.PATH | prepend [$mocks $old_bin])
      MOONBIT_HOME: $installed
      MOONBIT_INSTALL_VERSION: 'latest'
      MOONBIT_INSTALL_DEV: ''
      MOONC_OVERRIDE: ([$old_bin moonc] | path join)
      MOONRUN_OVERRIDE: ([$old_bin moonrun] | path join)
      GITHUB_PATH: ([$work_dir github-path] | path join)
      TEST_ARCHIVE: $archive
      TEST_CORE_ARCHIVE: $core_archive
      TEST_MOON: $moon
      TEST_CORE: $core
      TEST_OBSERVED: $observed
    } {
      # 1. Interrupted toolchain or core downloads must leave the live install untouched.
      for download in [toolchain core] {
        let result = with-env {TEST_DOWNLOAD: $download} { run-installer $installer '-cV' latest }
        assert not equal $result.exit_code 0
        assert equal (open $observed) ['old moon' 'old core'] $'Install changed during ($download) download'
        assert equal (open --raw $moon) 'old moon'
        assert equal (open --raw $core) 'old core'
        assert equal (ls -a $installed | get name | path basename | sort) [bin include lib]
        rm --permanent $observed
      }

      # 2. Failed core bundling must surface stdout diagnostics and leave the live install untouched.
      let bundle_fail = with-env {TEST_DOWNLOAD: 'bundle-fail', TEST_MOON_FAIL_STDOUT: '1'} {
        run-installer $installer '-cV' latest
      }
      assert not equal $bundle_fail.exit_code 0
      assert-diagnostic $bundle_fail.stderr 'bundle failed on stdout'
      assert equal (open --raw $moon) 'old moon'
      assert equal (open --raw $core) 'old core'
      assert equal (ls -a $installed | get name | path basename | sort) [bin include lib]

      # Invalid archive layouts must fail before replacing any installed file.
      let missing_lib = with-env {TEST_DOWNLOAD: 'success', TEST_ARCHIVE: $incomplete_archive} {
        run-installer $installer
      }
      let missing_core = with-env {TEST_DOWNLOAD: 'bundle-fail', TEST_CORE_ARCHIVE: $incomplete_core} {
        run-installer $installer '-cV' latest
      }
      assert not equal $missing_lib.exit_code 0
      assert-diagnostic $missing_lib.stderr 'Expected a directory'
      assert not equal $missing_core.exit_code 0
      assert-diagnostic $missing_core.stderr 'Expected a core'
      let invalid_alias = with-env {TEST_DOWNLOAD: 'success', TEST_ARCHIVE: $invalid_alias_archive} {
        run-installer $installer
      }
      assert not equal $invalid_alias.exit_code 0
      assert-diagnostic $invalid_alias.stderr 'moonx symlink'
      let invalid_moon = with-env {TEST_DOWNLOAD: 'core', TEST_ARCHIVE: $invalid_moon_archive} {
        run-installer $installer '-cV' latest
      }
      assert not equal $invalid_moon.exit_code 0
      assert-diagnostic $invalid_moon.stderr 'staged Moon'
      assert not ($observed | path exists) 'Core download should not start when staged Moon is invalid'
      # Existing tools on PATH or named by override variables must not fill holes in the archive.
      for name in [moonc moonrun] {
        let missing_binary_archive = [$work_dir $'missing-($name).tar.gz'] | path join
        ^tar -czf $missing_binary_archive --exclude $'bin/($name)' -C $payload bin lib include
        let missing_binary = with-env {TEST_DOWNLOAD: 'core', TEST_ARCHIVE: $missing_binary_archive} {
          run-installer $installer '-cV' latest
        }
        assert not equal $missing_binary.exit_code 0
        assert-diagnostic $missing_binary.stderr $'named ($name)'
        assert not ($observed | path exists) 'Core download should not start when an executable is missing'
      }
      assert equal (open --raw $moon) 'old moon'
      assert equal (open --raw $core) 'old core'
      assert equal (open --raw $stale_include) 'stale include'
      assert equal (ls -a $installed | get name | path basename | sort) [bin include lib]

      let conflict_home = [$work_dir conflicting-install] | path join
      mkdir $conflict_home
      let conflict_path = [$conflict_home lib] | path join
      'existing file' | save $conflict_path
      let conflict = with-env {TEST_DOWNLOAD: 'success', MOONBIT_HOME: $conflict_home} {
        run-installer $installer
      }
      assert not equal $conflict.exit_code 0
      assert-diagnostic $conflict.stderr 'Cannot replace'
      assert equal (open --raw $conflict_path) 'existing file'
      assert equal (ls -a $conflict_home | get name | path basename) [lib]

      let bin_conflict = with-env {TEST_DOWNLOAD: 'success', TEST_ARCHIVE: $conflicting_archive} {
        run-installer $installer
      }
      assert not equal $bin_conflict.exit_code 0
      assert-diagnostic $bin_conflict.stderr 'Cannot replace'
      assert equal (open --raw $custom_tool) 'custom tool'
      assert equal (open --raw $moon) 'old moon'

      let file_conflict_home = [$work_dir file-conflict] | path join
      let file_conflict_path = [$file_conflict_home bin internal] | path join
      mkdir ($file_conflict_path | path dirname)
      'user file' | save $file_conflict_path
      let file_conflict = with-env {TEST_DOWNLOAD: 'success', MOONBIT_HOME: $file_conflict_home} {
        run-installer $installer
      }
      assert not equal $file_conflict.exit_code 0
      assert-diagnostic $file_conflict.stderr 'Cannot replace'
      assert equal (open --raw $file_conflict_path) 'user file'
      assert equal (ls -a $file_conflict_home | get name | path basename) [bin]

      # 3. An existing lock must block concurrent installation without deleting the lock or live files.
      let lock_path = [$installed .setup-moonbit-lock] | path join
      mkdir $lock_path
      try {
        let locked = with-env {TEST_DOWNLOAD: 'success'} { run-installer $installer }
        assert not equal $locked.exit_code 0
        assert-diagnostic $locked.stderr 'Cannot acquire'
        assert (($lock_path | path type) == 'dir') 'Existing lock was removed on contention'
        assert equal (open --raw $moon) 'old moon'
        assert equal (open --raw $core) 'old core'
        assert equal (ls -a $installed | get name | path basename | sort) [.setup-moonbit-lock bin include lib]
      } finally {
        rm --permanent -rf $lock_path
      }

      # 4. A mid-replacement failure must roll back earlier entries (lib, include, bin) cleanly.
      if (^id -u | str trim) != '0' {
        let internal_dir = [$installed bin internal] | path join
        ^chmod 555 $internal_dir
        try {
          let rollback = with-env {TEST_DOWNLOAD: 'success'} { run-installer $installer }
          assert not equal $rollback.exit_code 0
          assert equal (open --raw $moon) 'old moon'
          assert equal (open --raw $core) 'old core'
          assert equal (open --raw $stale_lib) 'stale lib'
          assert equal (open --raw $stale_include) 'stale include'
          assert equal (open --raw ([$installed bin internal bundled-tool] | path join)) 'old bundled tool'
          assert equal (ls -a $installed | get name | path basename | sort) [bin include lib]
        } finally {
          ^chmod 755 $internal_dir
        }
      }

      # 5. A successful update must replace lib/include, link moonx, and preserve custom tools & hard links.
      ^chmod 000 $custom_tool
      let result = with-env {
        TEST_DOWNLOAD: 'success'
        MOONC_OVERRIDE: ([$work_dir absent-moonc] | path join)
        MOONRUN_OVERRIDE: ([$work_dir absent-moonrun] | path join)
      } { run-installer $installer }
      assert equal $result.exit_code 0 $result.stderr
      assert equal ($result.stdout | str trim | lines | last) 'test toolchain version'
      assert str contains (open --raw $moon) 'TEST_MOON_FAIL_STDOUT'
      assert equal (open --raw ([$installed bin internal bundled-tool] | path join)) 'new bundled tool'
      assert equal ([$installed bin moonx] | path join | path type) 'symlink'
      assert equal (open --raw ([$installed bin moonx] | path join)) (open --raw $moon)
      assert equal (open --raw ([$installed lib runtime.c] | path join)) 'new runtime'
      assert equal (open --raw ([$installed include moonbit.h] | path join)) 'new header'
      assert not ($stale_lib | path exists)
      assert not ($stale_include | path exists)
      assert equal (ls -a $installed | get name | path basename | sort) [bin include lib]
      ^chmod u+rw $custom_link
      '!' | save --append $custom_link
      assert equal (open --raw $custom_tool) 'custom tool!'
    }

    # 6. Empty MOONBIT_HOME / MOONBIT_INSTALL_VERSION must fall back to ~/.moon & latest, not $env.PWD.
    let fake_home = [$work_dir fake-home] | path join
    let caller_cwd = [$work_dir caller-cwd] | path join
    mkdir $fake_home ([$caller_cwd lib] | path join)
    'project lib' | save ([$caller_cwd lib keep.txt] | path join)
    let fallback_result = do {
      cd $caller_cwd
      with-env {
        HOME: $fake_home
        PATH: ($env.PATH | prepend $mocks)
        MOONBIT_HOME: ''
        MOONBIT_INSTALL_VERSION: ''
        MOONBIT_INSTALL_DEV: ''
        GITHUB_PATH: ([$work_dir github-path] | path join)
        TEST_ARCHIVE: $archive
        TEST_DOWNLOAD: 'success'
      } {
        run-installer $installer
      }
    }
    assert equal $fallback_result.exit_code 0 $fallback_result.stderr
    assert equal (open --raw ([$caller_cwd lib keep.txt] | path join)) 'project lib'
    assert equal (open --raw ([$fake_home .moon lib runtime.c] | path join)) 'new runtime'
  } finally {
    rm --permanent -rf $work_dir
  }
}
