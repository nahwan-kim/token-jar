#!/bin/bash
# Deterministic, fail-closed source boundary audit for Provider targets.
set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly SOURCES_ROOT="$REPOSITORY_ROOT/Packages/TokenTankCore/Sources"
readonly REPORT_FILE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tokentank-provider-io.XXXXXX")"
readonly TARGETS=(CodexProvider ClaudeProvider GrokProvider CursorProvider DoubaoProvider)

failed=0
scanned_files=0

cleanup() {
  /bin/rm -f "$REPORT_FILE"
}
trap cleanup EXIT

scan_file() {
  local file="$1"
  local awk_status=0

  /usr/bin/awk -v source_file="$file" '
    # Remove comments while retaining strings and source line boundaries.  Keeping
    # strings means interpolation and suspicious source text remain fail-closed;
    # comment-only mentions do not become findings.
    function scrub(line,    out,i,c,n) {
      out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        n = substr(line, i + 1, 1)

        if (block_depth > 0) {
          if (c == "/" && n == "*") {
            block_depth++
            i++
          } else if (c == "*" && n == "/") {
            block_depth--
            i++
          }
          continue
        }

        if (in_triple_string) {
          out = out c
          if (c == "\"" && substr(line, i, 3) == "\"\"\"") {
            out = out "\"\""
            i += 2
            in_triple_string = 0
          }
          continue
        }

        if (in_string) {
          out = out c
          if (c == "\\" && i < length(line)) {
            i++
            out = out substr(line, i, 1)
          } else if (c == "\"") {
            in_string = 0
          }
          continue
        }

        if (c == "/" && n == "/") {
          break
        }
        if (c == "/" && n == "*") {
          block_depth = 1
          i++
          continue
        }
        if (c == "\"" && substr(line, i, 3) == "\"\"\"") {
          out = out "\"\"\""
          i += 2
          in_triple_string = 1
          continue
        }
        if (c == "\"") {
          out = out c
          in_string = 1
          continue
        }
        out = out c
      }
      return out
    }

    function finding(label) {
      printf "%s:%d: forbidden %s\n", source_file, FNR, label
      found = 1
    }

    {
      code = scrub($0)

      if (code ~ "(^|[^[:alnum:]_])(FileManager|NSFileManager)([^[:alnum:]_]|$)") finding("FileManager")
      if (code ~ "(^|[^[:alnum:]_])(FileHandle|NSFileHandle)([^[:alnum:]_]|$)") finding("FileHandle")
      contentsCode = code
      gsub(/[.]append[[:space:]]*[(][[:space:]]*contentsOf[[:space:]]*:/, "", contentsCode)
      if (contentsCode ~ "(^|[^[:alnum:]_])contentsOf[[:space:]]*:") finding("Data/String(contentsOf:)")
      if (code ~ "(^|[^[:alnum:]_])URLSession([^[:alnum:]_]|$)") finding("URLSession")
      if (code ~ "(^|[^[:alnum:]_])URLRequest([^[:alnum:]_]|$)") finding("URLRequest")
      if (code ~ "(^|[^[:alnum:]_])Network([^[:alnum:]_]|$)") finding("Network import/API")
      if (code ~ "(^|[^[:alnum:]_])NW[[:alnum:]_]*([^[:alnum:]_]|$)") finding("NW* API")

      if (code ~ "(^|[[:space:];=({,])(socket|connect|send|recv|recvfrom|sendto|bind|listen|accept|setsockopt|getaddrinfo|shutdown|inet_pton|inet_ntop|read|readv|writev|poll|select|kqueue|CFStreamCreatePairWithSocket)[[:space:]]*[(]") finding("socket API")
      if (code ~ "(Darwin|Glibc|SwiftGlibc)[.](socket|connect|send|recv|recvfrom|sendto|bind|listen|accept|setsockopt|getaddrinfo|shutdown|inet_pton|inet_ntop|read|readv|writev|poll|select|kqueue)[[:space:]]*[(]") finding("namespaced socket API")
      if (code ~ "(^|[[:space:];])import[[:space:]]+(Darwin|Glibc|SwiftGlibc)([^[:alnum:]_]|$)") finding("POSIX import")
      if (code ~ "(^|[^[:alnum:]_])SecItem[[:alnum:]_]*([^[:alnum:]_]|$)") finding("SecItem* API")
      if (code ~ "(^|[[:space:];])import[[:space:]]+Security([^[:alnum:]_]|$)") finding("Security import")
      if (code ~ "(^|[^[:alnum:]_])Security[.]") finding("Security API")

      if (code ~ "(^|[^[:alnum:]_])(Process|NSTask|CommandLine)([^[:alnum:]_]|$)") finding("process/shell API")
      if (code ~ "(^|[^[:alnum:]_])(system|popen|pclose|posix_spawn|execve|execl|execlp|execle|execv|execvp|execvpe)[[:space:]]*[(]") finding("shell execution API")
      if (code ~ "(^|[^[:alnum:]_])NSWorkspace([^[:alnum:]_]|$)") finding("NSWorkspace")
      if (code ~ "(^|[^[:alnum:]_])NSAppleScript([^[:alnum:]_]|$)") finding("NSAppleScript")
      if (code ~ "(^|[^[:alnum:]_])(NSAppleEvent|AppleEvent|AE[A-Za-z0-9_]*)([^[:alnum:]_]|$)") finding("Apple Events API")
      if (code ~ "(^|[^[:alnum:]_])(WebKit|WK[A-Za-z0-9_]*|SafariServices|SFSafari[A-Za-z0-9_]*)([^[:alnum:]_]|$)") finding("WebKit/browser API")

      if (code ~ "(^|[^[:alnum:]_])(dlopen|dlsym|dlclose|dladdr|NSLookupSymbolInImage|NSCreateObjectFileImageFromFile|CFBundleGetFunctionPointerForName|CFBundleLoadExecutable|Bundle[.]load|loadExecutable)([^[:alnum:]_]|$)") finding("dynamic loading API")
      if (code ~ "(^|[^[:alnum:]_])(NSClassFromString|NSSelectorFromString|Selector|perform|methodForSelector|objc_msgSend|class_getMethodImplementation)([^[:alnum:]_]|$)") finding("runtime reflection API")

      if (code ~ "(^|[^[:alnum:]_])(write|removeItem|moveItem|copyItem|createFile|delete|rename|renameat|unlink|unlinkat|chmod|fchmod|chown|fchown|truncate|ftruncate|mkdir|rmdir|setAttributes|setResourceValue|setResourceValues)([^[:alnum:]_]|$)") finding("write/delete/rename/permission mutation API")
      if (code ~ "(^|[^[:alnum:]_])(open|openat|fopen|fdopen|freopen|opendir|readdir|stat|lstat|fstat|access|readlink|realpath|mmap|CFReadStreamCreateWithFile|CFWriteStreamCreateWithFile)[[:space:]]*[(]") finding("direct file-open/metadata API")
      if (code ~ "(^|[^[:alnum:]_])(contentsOfDirectory|subpaths|enumerator|resourceValues|bookmarkData|resolvingBookmarkData|startAccessingSecurityScopedResource|stopAccessingSecurityScopedResource)([^[:alnum:]_]|$)") finding("filesystem enumeration/resource API")
    }

    END {
      if (found) exit 1
    }
  ' "$file" >"$REPORT_FILE" || awk_status=$?

  if (( awk_status != 0 && awk_status != 1 )); then
    printf 'FAIL: scanner error while reading %s (awk exit %d)\n' "$file" "$awk_status" >&2
    failed=1
    return
  fi

  if [[ -s "$REPORT_FILE" ]]; then
    /bin/cat "$REPORT_FILE"
    failed=1
  fi
}

for target in "${TARGETS[@]}"; do
  target_dir="$SOURCES_ROOT/$target"
  if [[ ! -d "$target_dir" ]]; then
    printf 'FAIL: missing Provider source target: %s\n' "$target_dir" >&2
    failed=1
    continue
  fi

  symlink_list=""
  if ! symlink_list="$(/usr/bin/find "$target_dir" -type l -print | /usr/bin/sort)"; then
    printf 'FAIL: cannot inspect symlinks in Provider source target: %s\n' "$target_dir" >&2
    failed=1
    continue
  fi
  if [[ -n "$symlink_list" ]]; then
    printf 'FAIL: symlinked Provider source entry is not auditable: %s\n' "$target_dir" >&2
    printf '%s\n' "$symlink_list"
    failed=1
  fi

  file_list=""
  if ! file_list="$(/usr/bin/find "$target_dir" -type f -name '*.swift' -print | /usr/bin/sort)"; then
    printf 'FAIL: cannot enumerate Provider source target: %s\n' "$target_dir" >&2
    failed=1
    continue
  fi
  if [[ -z "$file_list" ]]; then
    printf 'FAIL: Provider source target has no Swift files: %s\n' "$target_dir" >&2
    failed=1
    continue
  fi

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    scanned_files=$((scanned_files + 1))
    scan_file "$file"
  done <<<"$file_list"
done

if (( failed != 0 )); then
  printf 'Provider I/O audit: FAIL (%d Swift file(s) scanned)\n' "$scanned_files" >&2
  exit 1
fi

printf 'Provider I/O audit: PASS (%d Swift file(s) scanned; five fixed targets only)\n' "$scanned_files"
