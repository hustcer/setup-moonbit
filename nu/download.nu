const DOWNLOADER = path self
const WINDOWS_LOCK = path self download-windows.ps1
const UNIX_LOCK = path self download-unix.sh

# The MoonBit CDN responds more quickly to the curl user agent.
export const HTTP_HEADERS = [User-Agent curl/8.9]
const ARCHIVE_HEADERS = [...$HTTP_HEADERS Accept-Encoding identity]

export def fetch-archive [url: string, archive: string, cache_dir: string]: nothing -> nothing {
  print $'Fetch (ansi g)($url)(ansi rst)'
  mkdir $cache_dir
  if ($cache_dir | path type) != 'dir' {
    error make {msg: $'Expected a download cache directory at ($cache_dir)'}
  }
  let key = [$cache_dir ($url | hash sha256)] | path join
  let lock = $'($key).lock'
  assert-cache-file $lock
  let archive = $archive | path expand --no-symlink
  let args = [--no-config-file $DOWNLOADER $url $archive $key --locked]
  match $nu.os-info.name {
    'windows' => {
      ^powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $WINDOWS_LOCK $lock $nu.current-exe $DOWNLOADER $url $archive $key
    }
    'macos' => { ^/bin/sh $UNIX_LOCK $lock $nu.current-exe ...$args }
    _ => {
      if (which flock | is-not-empty) {
        ^/bin/sh $UNIX_LOCK $lock $nu.current-exe ...$args
      } else {
        # Keep working in minimal containers without a system file lock.
        download-archive $url $archive $'($archive).download'
      }
    }
  }
}

def assert-cache-file [path: string]: nothing -> nothing {
  if ($path | path type) not-in [null file] {
    error make {msg: $'Expected a regular download cache file at ($path)'}
  }
}

def archive-size [path: string]: nothing -> int {
  ls --all --directory $path | get size.0 | into int
}

def header [response: record, name: string]: nothing -> string {
  $response.headers | where name == $name | get value.0? | default ''
}

def strong-etag [etag: string]: nothing -> bool {
  $etag =~ '^"[^"\x00-\x20\x7f]*"$'
}

def identity-encoding [response: record]: nothing -> bool {
  (header $response content-encoding | str lowercase) in ['' identity]
}

def reset-download [files: record]: nothing -> nothing {
  rm --force --permanent $files.part $files.state
}

def prepare-full-download [response: record, files: record]: nothing -> string {
  if not (identity-encoding $response) {
    error make {msg: 'Unexpected content encoding for a MoonBit archive'}
  }
  let length = try { header $response content-length | into int } catch { null }
  reset-download $files
  # Save the validator before the body. Any bytes left by an interruption belong to it.
  {
    etag: (header $response etag)
    length: $length
    source: ($response.urls | last)
    chunked: ((header $response transfer-encoding | str lowercase) == 'chunked')
  } | save $files.state
  $files.part
}

def resumed-length [response: record, previous: record, start: int, probe: bool]: nothing -> int {
  let range = try {
    header $response content-range
      | parse --regex '(?i)^bytes (?<start>\d+)-(?<end>\d+)/(?<length>\d+)$'
      | into int start end length
      | first
  } catch { return 0 }
  let end = if $probe { 0 } else { $range.length - 1 }
  let content_length = header $response content-length
  if (($response.urls | last) == $previous.source
    and (header $response etag) == $previous.etag
    and (identity-encoding $response)
    and ($previous.length? == null or $range.length == $previous.length)
    and $range.start == $start and $range.end == $end and $end >= $start and $end < $range.length
    and $content_length in ['' (($end - $start + 1) | into string)]) { $range.length } else { 0 }
}

def download-body [url: string, files: record, previous: record, offset: int]: nothing -> bool {
  let complete = $offset > 0 and $offset == $previous.length?
  let headers = if $complete {
    # Revalidate a full partial file left by an interruption before publication.
    [...$ARCHIVE_HEADERS Range 'bytes=0-0' If-Range $previous.etag]
  } else if $offset > 0 {
    [...$ARCHIVE_HEADERS Range $'bytes=($offset)-' If-Range $previous.etag]
  } else {
    $ARCHIVE_HEADERS
  }
  http get --raw --allow-errors -H $headers $url | metadata access {|meta|
    match $meta.http_response.status {
      200 => {
        save --raw --progress (prepare-full-download $meta.http_response $files)
        true
      }
      206 if $offset > 0 => {
        match (resumed-length $meta.http_response $previous (if $complete { 0 } else { $offset }) $complete) {
          0 => { false }
          $total => {
            if not $complete {
              save --raw --append --progress (do {
                if $previous.length? == null { $previous | upsert length $total | save --force $files.state }
                print $'Resuming download at byte ($offset)'
                $files.part
              })
            }
            true
          }
        }
      }
      416 if $offset > 0 => { false }
      $status => { error make {msg: $'Archive download returned HTTP ($status) for ($url)'} }
    }
  }
}

def official-checksum [url: string]: nothing -> string {
  http get --raw --allow-errors -H $HTTP_HEADERS $'($url).sha256' | metadata access {|meta|
    match $meta.http_response.status {
      200 => {
        let checksum = decode utf-8 | str trim | parse -r '^(?<digest>[0-9a-fA-F]{64})(?:[ \t]+[^\r\n]+)?$' | get digest.0?
        if $checksum == null { error make {msg: $'Invalid SHA-256 file for ($url)'} }
        $checksum | str lowercase
      }
      # S3 can return 403 for a missing checksum object, for example for Core.
      403 | 404 => { '' }
      $status => { error make {msg: $'Checksum download returned HTTP ($status) for ($url)'} }
    }
  }
}

def archive-checksum [path: string]: nothing -> string {
  # Prefer streaming tools on Unix because Nushell 0.117 buffers hash input.
  if $nu.os-info.family == 'unix' {
    if (which sha256sum | is-not-empty) {
      return (open --raw $path | ^sha256sum | split row ' ' | first)
    }
    if (which shasum | is-not-empty) {
      return (open --raw $path | ^shasum -a 256 | split row ' ' | first)
    }
  }
  open --raw $path | hash sha256
}

# The worker runs under the per-URL lock, with an isolated path as a fallback.
def download-archive [url: string, archive: string, key: string]: nothing -> nothing {
  let files = {part: $'($key).part', state: $'($key).json'}
  assert-cache-file $files.state
  assert-cache-file $files.part
  let saved = try { open $files.state } catch { null }
  let state = if ($saved | describe | str starts-with 'record') { $saved } else { {} }
  let size = if ($files.part | path type) == 'file' { archive-size $files.part } else { 0 }
  let can_resume = (($state.length? == null or (($state.length | describe) == 'int' and $size <= $state.length))
    and ($state.etag? | describe) == 'string' and (strong-etag $state.etag)
    and ($state.source? | describe) == 'string')
  let offset = if $can_resume { $size } else { 0 }
  if $offset > 0 {
    print $'Checking download at byte ($offset)'
  }
  if not (download-body $url $files $state $offset) {
    print 'The saved range could not be verified. Restarting the download.'
    download-body $url $files {} 0 | ignore
  }
  let finished = open $files.state
  let expected_length = $finished.length
  let actual_length = archive-size $files.part
  if $expected_length != null and $actual_length != $expected_length {
    if $actual_length > $expected_length { reset-download $files }
    error make {msg: $'Unexpected archive size for ($url). Expected ($expected_length), got ($actual_length).'}
  }
  let checksum = official-checksum $url
  # An EOF-delimited response cannot distinguish completion from a dropped connection.
  if $expected_length == null and $finished.chunked? != true and ($checksum | is-empty) {
    error make {msg: $'Cannot verify the end of the archive download for ($url)'}
  }
  if ($checksum | is-not-empty) and (archive-checksum $files.part) != $checksum {
    reset-download $files
    error make {msg: $'SHA-256 mismatch for ($url)'}
  }
  mv $files.part $archive
  rm --permanent $files.state
}

def main [url: string, archive: string, cache: string, --locked]: nothing -> nothing {
  if $locked {
    download-archive $url $archive $cache
  } else {
    fetch-archive $url $archive $cache
  }
}
