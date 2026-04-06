#!/usr/bin/env zsh
# =============================================================================
#  AnalyzeSourceCodeForMacAppStore.zsh
#  Static Mac App Store compliance scan for an Xcode project folder or
#  workspace. Checks for private / non-public API usage, deprecated APIs,
#  entitlements issues, and key App Store metadata problems.
# =============================================================================

setopt extended_glob null_glob pipefail

# Terminal colors
BOLD=$'\e[1m'
DIM=$'\e[2m'
RESET=$'\e[0m'
C_CYAN=$'\e[36m'
C_GREEN=$'\e[32m'
C_YELLOW=$'\e[33m'
C_BLUE=$'\e[34m'
C_MAGENTA=$'\e[35m'
C_RED=$'\e[31m'
C_WHITE=$'\e[97m'
C_GRAY=$'\e[90m'

DEFAULT_EXCLUDES=(
  .git
  .svn
  .hg
  .build
  .swiftpm
  build
  Build
  DerivedData
  Pods
  Carthage
  vendor
  Vendor
  third_party
  ThirdParty
  node_modules
  SourcePackages
  xcuserdata
)

NO_COLOR=""
STRICT=0
PROJECT_PATH=""
WORKSPACE_PATH=""
EXTRA_EXCLUDES=()
XCODE_TARGET_KIND=""
XCODE_TARGET_PATH=""
TMP_FILES=()
FIND_PRUNE_ARGS=()
FOUND_CATEGORY=0
FOUND_SANDBOX=0

init_colors() {
  if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    BOLD=""
    DIM=""
    RESET=""
    C_CYAN=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_RED=""
    C_WHITE=""
    C_GRAY=""
  fi
}

usage() {
  print "${BOLD}Usage:${RESET}  AnalyzeSourceCodeForMacAppStore.zsh [options] [directory]"
  print ""
  print "${BOLD}Options:${RESET}"
  print "  --project PATH      Use a specific .xcodeproj"
  print "  --workspace PATH    Use a specific .xcworkspace"
  print "  --exclude NAME      Exclude a directory name or glob (repeatable, comma-separated)"
  print "  --strict            Treat warnings as failures"
  print "  --no-color          Disable ANSI colors"
  print "  -h, --help          Show this help"
  print ""
  print "If no project/workspace is given, the scan looks inside the directory for"
  print "the first .xcworkspace or .xcodeproj it can validate."
  print ""
  print "You can also point it directly at a built .app, .appex, .framework, or"
  print ".xpc bundle."
  print ""
  print "The scan checks source files, project files, Info.plist files,"
  print "entitlements, strings output, otool -L/-ov, and codesign entitlements."
}

die() {
  print -u2 "${C_RED}${BOLD}Error:${RESET} $1"
  exit 1
}

warn() {
  print -u2 "${C_YELLOW}${BOLD}Warning:${RESET} $1"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"
}

add_excludes() {
  local value=$1
  local -a parts
  parts=("${(@s:,:)value}")
  local part
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] && EXTRA_EXCLUDES+=("$part")
  done
}

repeat_char() {
  local char=$1
  local -i n=$2
  local out=""
  local -i i
  for (( i = 0; i < n; i++ )); do
    out+="$char"
  done
  print -rn -- "$out"
}

fmt_num() {
  local n=${1:-0}
  local sign=""
  local out=""
  local chunk

  if [[ $n == -* ]]; then
    sign="-"
    n=${n#-}
  fi

  while (( n >= 1000 )); do
    chunk=$(( n % 1000 ))
    out=",$(printf '%03d' "$chunk")$out"
    n=$(( n / 1000 ))
  done

  out="${n}${out}"
  print -rn -- "${sign}${out}"
}

build_regex() {
  local -a parts=("$@")
  print -r -- ${(j:|:)parts}
}

count_unique_lines() {
  if (( $# == 0 )); then
    print -rn -- 0
    return 0
  fi

  local count
  count=$(sort -u "$@" 2>/dev/null | wc -l | tr -d '[:space:]')
  print -rn -- "${count:-0}"
}

print_section() {
  local title=$1
  print ""
  print "${BOLD}${C_CYAN}$(repeat_char '=' 72)${RESET}"
  print "${BOLD}  ${title}${RESET}"
  print "${BOLD}${C_CYAN}$(repeat_char '=' 72)${RESET}"
}

emit_section() {
  local title=$1
  local color=$2
  shift 2

  local count
  count=$(count_unique_lines "$@")
  (( count == 0 )) && return 1

  print ""
  print "${BOLD}${color}${title}${RESET}"
  print "  ${C_GRAY}$(repeat_char '-' 72)${RESET}"
  sort -u "$@" 2>/dev/null | while IFS= read -r line; do
    print "  ${color}${line}${RESET}"
  done
  print ""
}

append_matches_from_blob() {
  local source=$1
  local file=$2
  local regex=$3
  local blob=$4
  local outfile=$5

  local matches rc
  matches=$(print -r -- "$blob" | grep -n -s -E -e "$regex" 2>/dev/null)
  rc=$?
  (( rc == 1 )) && return 0
  (( rc != 0 )) && return $rc
  [[ -n "$matches" ]] || return 0

  print -r -- "$matches" | while IFS= read -r line; do
    print -r -- "[$source] ${file}:$line" >> "$outfile"
  done
}

run_grep_batch() {
  local regex=$1
  local outfile=$2
  shift 2

  (( $# == 0 )) && return 0

  local out rc
  out=$(grep -nH -s -I -E -e "$regex" -- "$@" 2>/dev/null)
  rc=$?
  (( rc == 1 )) && return 0
  (( rc != 0 )) && return $rc
  [[ -n "$out" ]] || return 0
  print -r -- "$out" >> "$outfile"
}

scan_text_tree() {
  local root=$1
  local regex=$2
  local outfile=$3
  shift 3

  local -a find_args=("$@")
  local -a batch
  local file
  local -i batch_size=200

  : > "$outfile"

  while IFS= read -r -d $'\0' file; do
    batch+=("$file")
    if (( ${#batch} >= batch_size )); then
      run_grep_batch "$regex" "$outfile" "${batch[@]}" || return $?
      batch=()
    fi
  done < <(find "$root" "${find_args[@]}" -type f -print0 2>/dev/null)

  if (( ${#batch} > 0 )); then
    run_grep_batch "$regex" "$outfile" "${batch[@]}" || return $?
  fi
}

plist_get() {
  local file=$1
  local key=$2
  /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null
}

is_true() {
  case ${1:l} in
    true|yes|1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

build_find_prune_args() {
  typeset -ga FIND_PRUNE_ARGS
  local -a excludes=("$@")
  FIND_PRUNE_ARGS=( \( )

  local first=1
  local pattern
  for pattern in "${excludes[@]}"; do
    [[ -n "$pattern" ]] || continue
    (( first )) || FIND_PRUNE_ARGS+=( -o )
    FIND_PRUNE_ARGS+=( -path "$pattern" -o -path "*/$pattern" )
    first=0
  done

  FIND_PRUNE_ARGS+=( \) -prune -o )
}

is_bundle_target_path() {
  case $1 in
    *.app|*.appex|*.framework|*.xpc)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

discover_xcode_target() {
  local scan_root=$1
  local direct_target=${2:-}
  local project_override=${3:-}
  local workspace_override=${4:-}
  local -a projects workspaces
  local candidate

  if [[ -n "$project_override" && -n "$workspace_override" ]]; then
    die "Specify only one of --project or --workspace"
  fi

  if [[ -n "$workspace_override" ]]; then
    [[ -d "$workspace_override" ]] || die "Not a workspace directory: '$workspace_override'"
    XCODE_TARGET_KIND="workspace"
    XCODE_TARGET_PATH=${workspace_override:a}
  elif [[ -n "$project_override" ]]; then
    [[ -d "$project_override" ]] || die "Not a project directory: '$project_override'"
    XCODE_TARGET_KIND="project"
    XCODE_TARGET_PATH=${project_override:a}
  elif [[ -n "$direct_target" ]]; then
    case $direct_target in
      *.xcworkspace)
        XCODE_TARGET_KIND="workspace"
        XCODE_TARGET_PATH=${direct_target:a}
        ;;
      *.xcodeproj)
        XCODE_TARGET_KIND="project"
        XCODE_TARGET_PATH=${direct_target:a}
        ;;
      *)
        die "Unsupported target path: '$direct_target'"
        ;;
    esac
  else
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] && workspaces+=("$candidate")
    done < <(find "$scan_root" -type d -name '*.xcworkspace' -print 2>/dev/null | sort)

    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] && projects+=("$candidate")
    done < <(find "$scan_root" -type d -name '*.xcodeproj' -print 2>/dev/null | sort)

    if (( ${#workspaces} > 0 )); then
      XCODE_TARGET_KIND="workspace"
      XCODE_TARGET_PATH=${workspaces[1]:a}
      (( ${#workspaces} > 1 )) && warn "Multiple .xcworkspace directories found; using $XCODE_TARGET_PATH"
    elif (( ${#projects} > 0 )); then
      XCODE_TARGET_KIND="project"
      XCODE_TARGET_PATH=${projects[1]:a}
      (( ${#projects} > 1 )) && warn "Multiple .xcodeproj directories found; using $XCODE_TARGET_PATH"
    else
      die "No .xcodeproj or .xcworkspace found inside '$scan_root'"
    fi
  fi

  if [[ $XCODE_TARGET_KIND == workspace ]]; then
    xcodebuild -list -workspace "$XCODE_TARGET_PATH" >/dev/null 2>&1 || \
      die "Found '$XCODE_TARGET_PATH', but xcodebuild -list could not validate it"
  else
    xcodebuild -list -project "$XCODE_TARGET_PATH" >/dev/null 2>&1 || \
      die "Found '$XCODE_TARGET_PATH', but xcodebuild -list could not validate it"
  fi
}

sandbox_policy_for_path() {
  local file=$1
  case $file in
    *.app/Contents/MacOS/*|*.appex/Contents/MacOS/*|*.xpc/Contents/MacOS/*)
      print -rn -- 1
      ;;
    *)
      print -rn -- -1
      ;;
  esac
}

scan_entitlements_file() {
  local file=$1
  local label=$2
  local warn_out=$3
  local fail_out=$4
  local sandbox_policy=${5:-0}

  local value
  if value=$(plist_get "$file" com.apple.security.app-sandbox); then
    if ! is_true "$value"; then
      print -r -- "[$label] ${file}: com.apple.security.app-sandbox is ${value}" >> "$fail_out"
    else
      FOUND_SANDBOX=1
    fi
  else
    case $sandbox_policy in
      1)
        print -r -- "[$label] ${file}: missing com.apple.security.app-sandbox" >> "$fail_out"
        ;;
      0)
        print -r -- "[$label] ${file}: does not declare com.apple.security.app-sandbox" >> "$warn_out"
        ;;
      *)
        ;;
    esac
  fi

  if value=$(plist_get "$file" com.apple.security.get-task-allow); then
    is_true "$value" && \
      print -r -- "[$label] ${file}: com.apple.security.get-task-allow is true" >> "$fail_out"
  fi

  if grep -q -s -E 'com\.apple\.security\.temporary-exception' "$file" 2>/dev/null; then
    print -r -- "[$label] ${file}: contains temporary exception entitlements" >> "$fail_out"
  fi

  local -a warn_keys=(
    com.apple.security.cs.allow-jit
    com.apple.security.cs.allow-unsigned-executable-memory
    com.apple.security.cs.allow-dyld-environment-variables
    com.apple.security.cs.disable-library-validation
    com.apple.security.cs.skip-library-validation
  )

  local key
  for key in "${warn_keys[@]}"; do
    if value=$(plist_get "$file" "$key"); then
      is_true "$value" && \
        print -r -- "[$label] ${file}: ${key} is true" >> "$warn_out"
    fi
  done
}

scan_info_plist_file() {
  local file=$1
  local warn_out=$2

  local package_type
  package_type=$(plist_get "$file" CFBundlePackageType) || return 0
  [[ $package_type == APPL ]] || return 0

  local category
  if category=$(plist_get "$file" LSApplicationCategoryType); then
    FOUND_CATEGORY=1
    [[ -n "$category" ]] || \
      print -r -- "[plist] ${file}: LSApplicationCategoryType is empty" >> "$warn_out"
  else
    print -r -- "[plist] ${file}: missing LSApplicationCategoryType for application bundle" >> "$warn_out"
  fi

  local value bundle_id short_version bundle_version executable
  if bundle_id=$(plist_get "$file" CFBundleIdentifier); then
    if [[ -z "$bundle_id" ]]; then
      print -r -- "[plist] ${file}: CFBundleIdentifier is empty" >> "$warn_out"
    elif [[ $bundle_id == *\** ]]; then
      print -r -- "[plist] ${file}: CFBundleIdentifier contains a wildcard (${bundle_id})" >> "$warn_out"
    fi
  else
    print -r -- "[plist] ${file}: missing CFBundleIdentifier" >> "$warn_out"
  fi

  if short_version=$(plist_get "$file" CFBundleShortVersionString); then
    [[ -n "$short_version" ]] || \
      print -r -- "[plist] ${file}: CFBundleShortVersionString is empty" >> "$warn_out"
  else
    print -r -- "[plist] ${file}: missing CFBundleShortVersionString" >> "$warn_out"
  fi

  if bundle_version=$(plist_get "$file" CFBundleVersion); then
    [[ -n "$bundle_version" ]] || \
      print -r -- "[plist] ${file}: CFBundleVersion is empty" >> "$warn_out"
  else
    print -r -- "[plist] ${file}: missing CFBundleVersion" >> "$warn_out"
  fi

  if executable=$(plist_get "$file" CFBundleExecutable); then
    [[ -n "$executable" ]] || \
      print -r -- "[plist] ${file}: CFBundleExecutable is empty" >> "$warn_out"
  else
    print -r -- "[plist] ${file}: missing CFBundleExecutable" >> "$warn_out"
  fi

  local -a ats_keys=(
    NSAllowsArbitraryLoads
    NSAllowsArbitraryLoadsInWebContent
    NSAllowsLocalNetworking
    NSAllowsArbitraryLoadsForMedia
    NSAllowsArbitraryLoadsInMedia
  )

  local key
  for key in "${ats_keys[@]}"; do
    if value=$(plist_get "$file" "NSAppTransportSecurity:$key"); then
      is_true "$value" && \
        print -r -- "[plist] ${file}: NSAppTransportSecurity:${key} is true" >> "$warn_out"
    fi
  done

  if plist_get "$file" "NSAppTransportSecurity:NSExceptionDomains" >/dev/null 2>&1; then
    print -r -- "[plist] ${file}: NSAppTransportSecurity contains exception domains" >> "$warn_out"
  fi
}

scan_binary_file() {
  local file=$1
  local private_re=$2
  local deprecated_re=$3
  local private_out=$4
  local deprecated_out=$5
  local warn_out=$6
  local fail_out=$7

  local kind
  kind=$(file -b -- "$file" 2>/dev/null) || return 0

  case $kind in
    *Mach-O*|*current\ ar\ archive*|*object\ file*|*shared\ library*|*executable*|*dynamically\ linked\ shared\ library*)
      ;;
    *)
      return 0
      ;;
  esac

  local sandbox_policy
  sandbox_policy=$(sandbox_policy_for_path "$file")

  local strings_out otool_l_out otool_v_out codesign_out ent_tmp ent_blob
  strings_out=$(strings -a -- "$file" 2>/dev/null || true)
  otool_l_out=$(otool -L -- "$file" 2>/dev/null || true)
  otool_v_out=$(otool -ov -- "$file" 2>/dev/null || true)

  append_matches_from_blob "strings" "$file" "$private_re" "$strings_out" "$private_out"
  append_matches_from_blob "strings" "$file" "$deprecated_re" "$strings_out" "$deprecated_out"
  append_matches_from_blob "otool -L" "$file" "$private_re" "$otool_l_out" "$private_out"
  append_matches_from_blob "otool -ov" "$file" "$private_re" "$otool_v_out" "$private_out"
  append_matches_from_blob "otool -ov" "$file" "$deprecated_re" "$otool_v_out" "$deprecated_out"

  codesign_out=$(codesign -d --entitlements :- -- "$file" 2>&1 || true)
  if [[ $codesign_out == *'<plist'* && $codesign_out == *'</plist>'* ]]; then
    ent_blob="<plist${codesign_out#*<plist}"
    ent_blob="${ent_blob%%</plist>*}</plist>"
    ent_tmp=$(mktemp "${TMPDIR:-/tmp}/macappstore-entitlements.XXXXXX") || \
      die "Unable to create a temporary file for codesign entitlements"
    print -r -- "$ent_blob" > "$ent_tmp"
    TMP_FILES+=("$ent_tmp")
    scan_entitlements_file "$ent_tmp" "codesign" "$warn_out" "$fail_out" "$sandbox_policy"
    rm -f -- "$ent_tmp"
    TMP_FILES=("${(@)TMP_FILES:#$ent_tmp}")
  fi
}

cleanup() {
  (( ${#TMP_FILES[@]} > 0 )) && rm -f -- "${TMP_FILES[@]}" 2>/dev/null
}

main() {
  local -a remaining_args
  local TARGET_ARG="."
  local DIRECT_TARGET=""
  local SCAN_ROOT=""
  local -i POSITIONAL_GIVEN=0
  local -i NEED_XCODEBUILD=1
  local -i REQUIRES_APP_METADATA=1
  local -i private_count=0 deprecated_count=0 security_count=0 warn_count=0 blocking_count=0
  local -i summary_warn_count=0 total_warn_count=0
  local category_hint_count sandbox_hint_count

  while (( $# )); do
    case $1 in
      -h|--help)
        init_colors
        usage
        exit 0
        ;;
      --no-color)
        NO_COLOR=1
        shift
        ;;
      --strict)
        STRICT=1
        shift
        ;;
      --project)
        (( $# >= 2 )) || die "Missing value for --project"
        PROJECT_PATH=$2
        shift 2
        ;;
      --project=*)
        PROJECT_PATH=${1#*=}
        shift
        ;;
      --workspace)
        (( $# >= 2 )) || die "Missing value for --workspace"
        WORKSPACE_PATH=$2
        shift 2
        ;;
      --workspace=*)
        WORKSPACE_PATH=${1#*=}
        shift
        ;;
      --exclude)
        (( $# >= 2 )) || die "Missing value for --exclude"
        add_excludes "$2"
        shift 2
        ;;
      --exclude=*)
        add_excludes "${1#*=}"
        shift
        ;;
      --)
        shift
        remaining_args=("$@")
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        remaining_args=("$@")
        break
        ;;
    esac
  done

  if (( ${#remaining_args[@]} > 0 )); then
    POSITIONAL_GIVEN=1
    TARGET_ARG=${remaining_args[1]}
    if (( ${#remaining_args[@]} > 1 )); then
      die "Unexpected arguments: ${remaining_args[2,-1]}"
    fi
  fi

  init_colors

  if is_bundle_target_path "$TARGET_ARG"; then
    if [[ -n "$PROJECT_PATH" || -n "$WORKSPACE_PATH" ]]; then
      die "Bundle targets cannot be combined with --project or --workspace"
    fi
    DIRECT_TARGET=${TARGET_ARG:a}
    SCAN_ROOT=${TARGET_ARG:a}
    [[ -d "$DIRECT_TARGET" ]] || die "Not a bundle directory: '$TARGET_ARG'"
    NEED_XCODEBUILD=0
    XCODE_TARGET_KIND="bundle"
    XCODE_TARGET_PATH="$DIRECT_TARGET"
    case $TARGET_ARG in
      *.framework)
        REQUIRES_APP_METADATA=0
        ;;
    esac
  fi

  (( NEED_XCODEBUILD )) && require_tool xcodebuild
  require_tool file
  require_tool strings
  require_tool otool
  require_tool codesign
  require_tool grep
  require_tool sort
  require_tool find
  require_tool mktemp
  [[ -x /usr/libexec/PlistBuddy ]] || die "Required tool not found: /usr/libexec/PlistBuddy"

  if (( POSITIONAL_GIVEN == 0 && NEED_XCODEBUILD )); then
    if [[ -n "$WORKSPACE_PATH" ]]; then
      SCAN_ROOT=${WORKSPACE_PATH:h:a}
    elif [[ -n "$PROJECT_PATH" ]]; then
      SCAN_ROOT=${PROJECT_PATH:h:a}
    fi
  fi

  if (( NEED_XCODEBUILD == 0 )); then
    :
  elif [[ $TARGET_ARG == *.xcodeproj || $TARGET_ARG == *.xcworkspace ]]; then
    DIRECT_TARGET=${TARGET_ARG:a}
    SCAN_ROOT=${TARGET_ARG:h:a}
    [[ -d "$DIRECT_TARGET" ]] || die "Not a workspace/project directory: '$TARGET_ARG'"
  else
    SCAN_ROOT=${TARGET_ARG:a}
    [[ -d "$SCAN_ROOT" ]] || die "Not a directory: '$TARGET_ARG'"
  fi

  build_find_prune_args "${DEFAULT_EXCLUDES[@]}" "${EXTRA_EXCLUDES[@]}"

  if (( NEED_XCODEBUILD )); then
    discover_xcode_target "$SCAN_ROOT" "$DIRECT_TARGET" "$PROJECT_PATH" "$WORKSPACE_PATH"
  fi

  local private_tmp deprecated_tmp security_fail_tmp warn_tmp category_hint_tmp sandbox_hint_tmp
  private_tmp=$(mktemp "${TMPDIR:-/tmp}/macappstore-private.XXXXXX") || exit 1
  deprecated_tmp=$(mktemp "${TMPDIR:-/tmp}/macappstore-deprecated.XXXXXX") || exit 1
  security_fail_tmp=$(mktemp "${TMPDIR:-/tmp}/macappstore-security.XXXXXX") || exit 1
  warn_tmp=$(mktemp "${TMPDIR:-/tmp}/macappstore-warnings.XXXXXX") || exit 1
  category_hint_tmp=$(mktemp "${TMPDIR:-/tmp}/macappstore-category-hint.XXXXXX") || exit 1
  sandbox_hint_tmp=$(mktemp "${TMPDIR:-/tmp}/macappstore-sandbox-hint.XXXXXX") || exit 1

  TMP_FILES=(
    "$private_tmp"
    "$deprecated_tmp"
    "$security_fail_tmp"
    "$warn_tmp"
    "$category_hint_tmp"
    "$sandbox_hint_tmp"
  )
  trap cleanup EXIT INT TERM HUP

  print ""
  print "${BOLD}${C_CYAN}Mac App Store Analyzer${RESET}"
  print "  ${C_GRAY}Scan root:${RESET} ${C_YELLOW}${SCAN_ROOT}${RESET}"
  print "  ${C_GRAY}Analysis target:${RESET} ${C_YELLOW}${XCODE_TARGET_KIND}:${XCODE_TARGET_PATH}${RESET}"
  print "  ${C_GRAY}Checks:${RESET} source files, project files, Info.plist files, entitlements, strings, otool, and codesign"
  print ""

  local PRIVATE_RE DEPRECATED_RE PROJECT_FAIL_RE PROJECT_WARN_RE CATEGORY_HINT_RE SANDBOX_HINT_RE
  PRIVATE_RE=$(build_regex \
    'PrivateFrameworks' \
    'PrivateHeaders' \
    '/System/Library/PrivateFrameworks/' \
    '/Library/PrivateFrameworks/' \
    '@selector\(_[A-Za-z0-9_]+' \
    'Selector\("_[^"]+"\)' \
    'NSSelectorFromString\(.*"_[^"]+"\)' \
    'NSClassFromString\(.*"_[^"]+"\)' \
    'objc_getClass\("_[^"]+"\)' \
    'objc_getProtocol\("_[^"]+"\)' \
    'objc_lookUpClass\("_[^"]+"\)' \
    'sel_registerName\("_[^"]+"\)' \
    'dlopen\(".*PrivateFrameworks' \
    'framework[[:space:]]+PrivateFrameworks' \
  )
  DEPRECATED_RE=$(build_regex \
    'NSRunAlertPanel' \
    'NSBeginAlertSheet' \
    'NSRunInformationalAlertPanel' \
    'NSBeginInformationalAlertSheet' \
    'NSRunCriticalAlertPanel' \
    'NSBeginCriticalAlertSheet' \
    'NSGetAlertPanel' \
    'NSGetInformationalAlertPanel' \
    'NSGetCriticalAlertPanel' \
    'NSDrawer' \
    'NSMovieView' \
    'NSQuickDrawView' \
    'NSOpenGLView' \
    'NSOpenGLPixelFormat' \
    'NSOpenGLPixelBuffer' \
    'NSOpenGLContext' \
    'WebView' \
    'WebFrame' \
    'WebFrameView' \
    'WebPolicyDelegate' \
    'WebDataSource' \
    'WebDownload' \
    'WebPreferences' \
    'WaitNextEvent' \
    'GetNextEvent' \
    'MenuSelect' \
    'UpdateWindows' \
    'Gestalt' \
    'FrontWindow' \
    'UIWebView' \
    'NSURLConnection' \
    'ALAsset' \
    'ALAssetsLibrary' \
    'NSFileHandle.*readInBackgroundAndNotify' \
    'OSAtomic[A-Za-z0-9_]*' \
    'dispatch_get_current_queue' \
    'QTMovie' \
    'QTMovieView' \
    'QTKit' \
    'ABAddressBook' \
    'AddressBook' \
  )
  PROJECT_FAIL_RE=$(build_regex 'ENABLE_APP_SANDBOX[[:space:]]*=[[:space:]]*NO')
  PROJECT_WARN_RE=$(build_regex \
    'ENABLE_HARDENED_RUNTIME[[:space:]]*=[[:space:]]*NO' \
    'CODE_SIGN_STYLE[[:space:]]*=[[:space:]]*Manual' \
  )
  CATEGORY_HINT_RE=$(build_regex 'LSApplicationCategoryType' 'INFOPLIST_KEY_LSApplicationCategoryType')
  SANDBOX_HINT_RE=$(build_regex 'com\.apple\.security\.app-sandbox' 'ENABLE_APP_SANDBOX[[:space:]]*=[[:space:]]*YES')
  local -a PROJECT_CONFIG_FIND_ARGS
  PROJECT_CONFIG_FIND_ARGS=(
    "${FIND_PRUNE_ARGS[@]}"
    \( -name 'project.pbxproj' -o -name '*.xcconfig' -o -name '*.xcscheme' -o -name '*.xcsettings' \)
  )

  print "${C_GRAY}Scanning source and project files...${RESET}"
  scan_text_tree "$SCAN_ROOT" "$PRIVATE_RE" "$private_tmp" "${FIND_PRUNE_ARGS[@]}" || \
    die "Source scan for private APIs failed"
  scan_text_tree "$SCAN_ROOT" "$DEPRECATED_RE" "$deprecated_tmp" "${FIND_PRUNE_ARGS[@]}" || \
    die "Source scan for deprecated APIs failed"
  scan_text_tree "$SCAN_ROOT" "$PROJECT_FAIL_RE" "$security_fail_tmp" "${PROJECT_CONFIG_FIND_ARGS[@]}" || \
    die "Source scan for sandbox build settings failed"
  scan_text_tree "$SCAN_ROOT" "$PROJECT_WARN_RE" "$warn_tmp" "${PROJECT_CONFIG_FIND_ARGS[@]}" || \
    die "Source scan for warning build settings failed"
  scan_text_tree "$SCAN_ROOT" "$CATEGORY_HINT_RE" "$category_hint_tmp" "${PROJECT_CONFIG_FIND_ARGS[@]}" || \
    die "Source scan for app category hints failed"
  scan_text_tree "$SCAN_ROOT" "$SANDBOX_HINT_RE" "$sandbox_hint_tmp" "${PROJECT_CONFIG_FIND_ARGS[@]}" || \
    die "Source scan for sandbox hints failed"

  category_hint_count=$(count_unique_lines "$category_hint_tmp")
  sandbox_hint_count=$(count_unique_lines "$sandbox_hint_tmp")
  (( category_hint_count > 0 )) && FOUND_CATEGORY=1
  (( sandbox_hint_count > 0 )) && FOUND_SANDBOX=1

  print "${C_GRAY}Scanning Info.plist files...${RESET}"
  local info_plist
  while IFS= read -r -d $'\0' info_plist; do
    scan_info_plist_file "$info_plist" "$warn_tmp" || return $?
  done < <(find "$SCAN_ROOT" "${FIND_PRUNE_ARGS[@]}" -type f \( -name 'Info.plist' -o -name '*-Info.plist' \) -print0 2>/dev/null)

  print "${C_GRAY}Scanning entitlements files...${RESET}"
  local entitlements_file
  while IFS= read -r -d $'\0' entitlements_file; do
    scan_entitlements_file "$entitlements_file" "entitlements" "$warn_tmp" "$security_fail_tmp" 0 || return $?
  done < <(find "$SCAN_ROOT" "${FIND_PRUNE_ARGS[@]}" -type f -name '*.entitlements' -print0 2>/dev/null)

  print "${C_GRAY}Scanning binary artifacts with strings, otool, and codesign...${RESET}"
  local file
  while IFS= read -r -d $'\0' file; do
    [[ -n "$file" ]] || continue
    [[ $file == *.plist || $file == *.entitlements || $file == *.pbxproj || $file == *.xcscheme || $file == *.xcconfig ]] && continue
    scan_binary_file "$file" "$PRIVATE_RE" "$DEPRECATED_RE" "$private_tmp" "$deprecated_tmp" "$warn_tmp" "$security_fail_tmp" || return $?
  done < <(find "$SCAN_ROOT" "${FIND_PRUNE_ARGS[@]}" -type f -print0 2>/dev/null)

  private_count=$(count_unique_lines "$private_tmp")
  deprecated_count=$(count_unique_lines "$deprecated_tmp")
  security_count=$(count_unique_lines "$security_fail_tmp")
  warn_count=$(count_unique_lines "$warn_tmp")
  blocking_count=$(( private_count + deprecated_count + security_count ))
  if (( REQUIRES_APP_METADATA )); then
    if (( FOUND_CATEGORY == 0 )); then
      (( summary_warn_count++ ))
    fi
    if (( FOUND_SANDBOX == 0 )); then
      (( summary_warn_count++ ))
    fi
  fi
  total_warn_count=$(( warn_count + summary_warn_count ))

  print_section "RESULTS"

  emit_section "Private / non-public API matches" "$C_RED" "$private_tmp"
  emit_section "Deprecated API matches" "$C_YELLOW" "$deprecated_tmp"
  emit_section "Security / entitlements issues" "$C_RED" "$security_fail_tmp"
  emit_section "Warnings" "$C_YELLOW" "$warn_tmp"

  print_section "SUMMARY"
  printf "  ${C_GRAY}%-24s ${RESET}%8s\n" "Analysis target" "${XCODE_TARGET_KIND}:$(basename "$XCODE_TARGET_PATH")"
  printf "  ${C_GRAY}%-24s ${RESET}%8s\n" "Private API hits" "$(fmt_num "$private_count")"
  printf "  ${C_GRAY}%-24s ${RESET}%8s\n" "Deprecated API hits" "$(fmt_num "$deprecated_count")"
  printf "  ${C_GRAY}%-24s ${RESET}%8s\n" "Security issues" "$(fmt_num "$security_count")"
  printf "  ${C_GRAY}%-24s ${RESET}%8s\n" "Warnings" "$(fmt_num "$total_warn_count")"
  printf "  ${C_GRAY}%-24s ${RESET}%8s\n" "Category found" "$(fmt_num "$FOUND_CATEGORY")"
  printf "  ${C_GRAY}%-24s ${RESET}%8s\n" "Sandbox found" "$(fmt_num "$FOUND_SANDBOX")"

  print ""
  if (( blocking_count > 0 )); then
    print "  ${C_RED}${BOLD}Potential issues were found.${RESET}"
    exit 2
  fi

  if (( REQUIRES_APP_METADATA )); then
    if (( FOUND_CATEGORY == 0 )); then
      warn "No app category declaration was found in scanned plists or project settings"
    fi

    if (( FOUND_SANDBOX == 0 )); then
      warn "No app sandbox entitlement was found in scanned entitlements or project settings"
    fi
  fi

  if (( STRICT > 0 && total_warn_count > 0 )); then
    print "  ${C_YELLOW}${BOLD}Warnings were found and --strict is enabled.${RESET}"
    exit 2
  fi

  if (( total_warn_count > 0 )); then
    print "  ${C_YELLOW}${BOLD}Warnings were found, but no blocking issues matched the configured rules.${RESET}"
  else
    print "  ${C_GREEN}${BOLD}No issues detected by the configured heuristics.${RESET}"
  fi
}

main "$@"
