# Lock an open file descriptor, then keep it across exec in the process that writes the cache.
lock_path=$1
shift
exec 9>>"$lock_path" || exit

if [ "$(uname -s)" = Darwin ]; then
  lockf -t 30 9 || exit
else
  # Descriptor mode works with both util-linux and BusyBox flock.
  retries=30
  until flock -n 9; do
    if [ "$retries" -eq 0 ]; then
      printf 'Cannot acquire download lock at %s\n' "$lock_path" >&2
      exit 1
    fi
    sleep 1
    retries=$((retries - 1))
  done
fi

exec "$@"
