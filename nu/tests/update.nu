use std/assert

# Run on Unix, where a Nushell script with a shebang can stand in for curl.
def main [installer: path] {
  let installer = $installer | path expand
  let work_dir = mktemp --directory
  try {
    let installed = [$work_dir installed] | path join
    let payload = [$work_dir payload] | path join
    let mocks = [$work_dir mocks] | path join
    let archive = [$work_dir toolchain.tar.gz] | path join
    let moon = [$installed bin moon] | path join
    let core = [$installed lib core moon.mod] | path join
    let custom_tool = [$installed bin internal custom-tool] | path join
    let custom_link = [$work_dir custom-link] | path join
    let observed = [$work_dir observed.nuon] | path join
    mkdir ($custom_tool | path dirname) ($core | path dirname) ([$payload bin internal] | path join) $mocks
    'old moon' | save $moon
    'old core' | save $core
    'custom tool' | save $custom_tool
    ^ln $custom_tool $custom_link
    'old bundled tool' | save ([$installed bin internal bundled-tool] | path join)
    'new moon' | save ([$payload bin moon] | path join)
    'new bundled tool' | save ([$payload bin internal bundled-tool] | path join)
    ^tar -czf $archive -C $payload bin

    let curl = [$mocks curl] | path join
    [
      '#!/usr/bin/env -S nu --no-config-file'
      'def --wrapped main [...args: string] {'
      '  let url = $args | last'
      '  let archive = $url | split row "/" | last'
      '  if $env.TEST_DOWNLOAD in ["core" "success"] and ($url | str contains "/binaries/") {'
      '    cp $env.TEST_ARCHIVE $archive'
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
      PATH: ($env.PATH | prepend $mocks)
      MOONBIT_HOME: $installed
      MOONBIT_INSTALL_VERSION: 'latest'
      MOONBIT_INSTALL_DEV: ''
      GITHUB_PATH: ([$work_dir github-path] | path join)
      TEST_ARCHIVE: $archive
      TEST_MOON: $moon
      TEST_CORE: $core
      TEST_OBSERVED: $observed
    } {
      for download in [toolchain core] {
        let result = with-env {TEST_DOWNLOAD: $download} { ^nu --no-config-file $installer -cV latest | complete }
        assert not equal $result.exit_code 0
        assert equal (open $observed) ['old moon' 'old core'] $'Install changed during ($download) download'
        assert equal (open --raw $moon) 'old moon'
        assert equal (open --raw $core) 'old core'
        assert equal (ls -a $installed | get name | path basename | sort) [bin lib]
        rm --permanent $observed
      }

      ^chmod 000 $custom_tool
      let result = with-env {TEST_DOWNLOAD: 'success'} { ^nu --no-config-file $installer | complete }
      assert equal $result.exit_code 0 $result.stderr
      assert equal (open --raw $moon) 'new moon'
      assert equal (open --raw ([$installed bin internal bundled-tool] | path join)) 'new bundled tool'
      ^chmod u+rw $custom_link
      '!' | save --append $custom_link
      assert equal (open --raw $custom_tool) 'custom tool!'
    }
  } finally {
    rm --permanent -rf $work_dir
  }
}
