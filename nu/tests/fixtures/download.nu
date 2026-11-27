# Preserve the existing archive fixtures for the installation and rollback tests.
export const HTTP_HEADERS = [User-Agent curl/8.9]

export def fetch-archive [url: string, archive: string, _cache_dir: string]: nothing -> nothing {
  ^curl -fL -o $archive $url
}
