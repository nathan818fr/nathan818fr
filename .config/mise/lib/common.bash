# shellcheck shell=bash disable=SC2034 # the constants are used by the tasks that source this file
#
# Shared code of the tasks in .config/mise/tasks/, sourced after their strict mode.

# Paths
LIB_DIR="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")"
ROOT_DIR="$(realpath -- "${LIB_DIR}/../../..")"
TASKS_DIR="${ROOT_DIR}/.config/mise/tasks"
PROFILE="${ROOT_DIR}/profile.yaml"
README="${ROOT_DIR}/README.md"
BADGES_DIR="${ROOT_DIR}/.assets/languages"
ICONS_DIR="${ROOT_DIR}/.assets/icons"
INDEX="${ROOT_DIR}/contributions/README.md"
PATCHES_DIR="${ROOT_DIR}/contributions/patches"

# How README.md refers to the badges and icons (relative to the repository root)
BADGES_PATH='.assets/languages'
ICONS_PATH='.assets/icons'

# The generated blocks of contributions/README.md, in order
INDEX_BLOCKS=(highlights changes)

### Profile

function profile_json() {
  yq -o=json '.' -- "$PROFILE"
}

# Fill the array named $1 with the problems of profile.yaml
function profile_errors() {
  local -n _profile_errors="$1"
  local -a _icons=()
  local _json _icon
  if ! command -v yq >/dev/null; then
    echo "error: yq is not installed: run \`mise install\`" >&2
    return 1
  fi
  if ! _json="$(profile_json 2>&1)"; then
    _profile_errors=("not valid YAML: ${_json}")
    return 0
  fi
  if ! capture_lines "$1" jq -r -L "$LIB_DIR" 'include "profile"; validate[]' <<<"$_json"; then return 1; fi
  if [[ "${#_profile_errors[@]}" -gt 0 ]]; then return 0; fi
  if ! capture_lines _icons jq -r -L "$LIB_DIR" 'include "profile"; used_icons[]' <<<"$_json"; then return 1; fi
  for _icon in "${_icons[@]}"; do
    if [[ ! -f "${ICONS_DIR}/${_icon}.svg" ]]; then _profile_errors+=("icon \"${_icon}\": no file .assets/icons/${_icon}.svg"); fi
  done
}

# Print the problems of profile.yaml, and fail if there are any
function check_profile() {
  local -a _problems=()
  local _problem
  if ! profile_errors _problems; then return 1; fi
  for _problem in "${_problems[@]}"; do echo "error: profile.yaml: ${_problem}" >&2; done
  if [[ "${#_problems[@]}" -gt 0 ]]; then return 1; fi
}

### contributions/

# Print one tab-separated record per entry of contributions/patches/ (paths relative to it), for
# contributions_tree in lib/profile.jq:
#   file <path> <year> <1 if it has a Subject: line>   a file of a project folder (year and Subject: for .patch files)
#   index <folder> ok|error <JSON or error>          the index.yaml of a project folder
#   stray <path> file|folder                         something outside the <owner>/<repo>/ layout
function contributions_records() {
  local -a _owners=() _repos=() _paths=()
  local _owner _repo _path _rel _json _status _year _subject
  folder_entries _owners "$PATCHES_DIR"
  for _owner in "${_owners[@]}"; do
    if [[ ! -d "$_owner" ]]; then
      printf 'stray\t%s\tfile\n' "${_owner#"${PATCHES_DIR}/"}"
      continue
    fi
    folder_entries _repos "$_owner"
    for _repo in "${_repos[@]}"; do
      if [[ ! -d "$_repo" ]]; then
        printf 'stray\t%s\tfile\n' "${_repo#"${PATCHES_DIR}/"}"
        continue
      fi
      folder_entries _paths "$_repo"
      for _path in "${_paths[@]}"; do
        _rel="${_path#"${PATCHES_DIR}/"}"
        if [[ -d "$_path" ]]; then
          printf 'stray\t%s\tfolder\n' "$_rel"
        elif [[ "$(basename -- "$_path")" == 'index.yaml' ]]; then
          if _json="$(yq -o=json -I=0 '.' -- "$_path" 2>&1)"; then
            _status='ok'
          else
            _status='error'
            _json="${_json#"Error: bad file '${_path}': "}" # the path is already in the message
          fi
          printf 'index\t%s\t%s\t%s\n' "$(dirname -- "$_rel")" "$_status" "${_json//[$'\t\n']/ }"
        else
          _year=''
          _subject=0
          if [[ "$_path" == *.patch ]]; then
            _year="$(awk '/^Date: / { if (match($0, / [0-9][0-9][0-9][0-9] /)) print substr($0, RSTART + 1, 4); exit }' "$_path")"
            if grep -q -m 1 '^Subject: ' -- "$_path"; then _subject=1; fi
          fi
          printf 'file\t%s\t%s\t%s\n' "$_rel" "$_year" "$_subject"
        fi
      done
    done
  done
}

function contributions_tree_json() {
  local _records
  if ! _records="$(contributions_records)"; then return 1; fi
  jq -n -L "$LIB_DIR" --arg records "$_records" 'include "profile"; contributions_tree($records)'
}

# Fill the array named $1 with the problems of contributions/patches/
function contributions_errors() {
  local _tree
  if ! _tree="$(contributions_tree_json)"; then return 1; fi
  # shellcheck disable=SC2016 # a jq program: shellcheck can't tell through capture_lines
  if ! capture_lines "$1" jq -n -r -L "$LIB_DIR" --argjson tree "$_tree" 'include "profile"; check_patches($tree)[]'; then
    return 1
  fi
}

# Print the problems of contributions/patches/, and fail if there are any
function check_contributions() {
  local -a _problems=()
  local _problem
  if ! contributions_errors _problems; then return 1; fi
  for _problem in "${_problems[@]}"; do echo "error: ${_problem}" >&2; done
  if [[ "${#_problems[@]}" -gt 0 ]]; then return 1; fi
}

# Print profile.yaml as JSON, with the patches under "patches"
function index_json() {
  local _tree
  if ! _tree="$(contributions_tree_json)"; then return 1; fi
  profile_json | jq -L "$LIB_DIR" --argjson tree "$_tree" 'include "profile"; . + {patches: patches($tree)}'
}

### Markdown files with generated blocks

function start_marker() {
  printf '<!-- generated:%s -->' "$1"
}

function end_marker() {
  printf '<!-- /generated:%s -->' "$1"
}

# Print the Markdown file $1 with its blocks $3... rendered from the JSON $2
function render_markdown() {
  local _file="$1" _json="$2" _name="${1#"${ROOT_DIR}/"}" _block _content _text
  shift 2
  if [[ ! -f "$_file" ]]; then
    echo "error: ${_name} is missing (it holds the text around the generated blocks)" >&2
    return 1
  fi
  if ! _text="$(<"$_file")"; then return 1; fi
  if ! check_markers "$_name" "$_text" "$@"; then return 1; fi
  for _block in "$@"; do
    # Each block name is the name of its function in lib/profile.jq
    if ! _content="$(jq -r -L "$LIB_DIR" --arg badges "$BADGES_PATH" --arg icons "$ICONS_PATH" "include \"profile\"; ${_block}" \
      <<<"$_json")"; then
      return 1
    fi
    if ! _text="$(replace_block "$_block" "$_content" <<<"$_text")"; then return 1; fi
  done
  printf '%s\n' "$_text"
}

# $1: profile.yaml as JSON
function render_readme() {
  local -a _blocks=()
  if ! capture_lines _blocks jq -r -L "$LIB_DIR" 'include "profile"; readme_blocks[]' <<<"$1"; then return 1; fi
  render_markdown "$README" "$1" "${_blocks[@]}"
}

function render_index() {
  local _json
  if ! _json="$(index_json)"; then return 1; fi
  render_markdown "$INDEX" "$_json" "${INDEX_BLOCKS[@]}"
}

# Check that the text $2 of the file $1 has each marker of the blocks $3... once, and no line that only looks like one
function check_markers() {
  local _name="$1" _text="$2" _block _marker _count _line _failed=0
  local -a _marker_lines=()
  local -A _known=()
  shift 2
  for _block in "$@"; do
    for _marker in "$(start_marker "$_block")" "$(end_marker "$_block")"; do
      _known["$_marker"]=1
      _count="$(grep -c -x -F -- "$_marker" <<<"$_text" || true)"
      if [[ "$_count" != '1' ]]; then
        echo "error: ${_name} must have the line ${_marker} once (it has it ${_count} times)" >&2
        _failed=1
      fi
    done
  done
  # shellcheck disable=SC2016 # an awk program: shellcheck can't tell through capture_lines
  if ! capture_lines _marker_lines awk '/<!--.*generated:/ { print NR ": " $0 }' <<<"$_text"; then return 1; fi
  for _line in "${_marker_lines[@]}"; do
    if [[ -n "${_known["${_line#*: }"]:-}" ]]; then continue; fi
    echo "error: ${_name} line ${_line%%: *} looks like a marker but is none of: ${!_known[*]}" >&2
    _failed=1
  done
  return "$_failed"
}

# Copy stdin to stdout, with the lines between the markers of block $1 replaced by $2
function replace_block() {
  # The content goes through the environment: `awk -v` would interpret its backslashes
  if ! BLOCK_CONTENT="$2" awk -v start="$(start_marker "$1")" -v end="$(end_marker "$1")" -- '
    $0 == start { print; print ""; print ENVIRON["BLOCK_CONTENT"]; print ""; skip = 1; next }
    $0 == end { skip = 0 }
    !skip { print }
    END { if (skip) exit 1 }
  '; then
    echo "error: no $(end_marker "$1") after $(start_marker "$1")" >&2
    return 1
  fi
}

### Language badges

# Print the badge of the language $1 (color $2, width $3)
function badge_svg() {
  local _name="${1//&/&amp;}"
  _name="${_name//</&lt;}"
  cat <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="${3}" height="16" viewBox="0 0 ${3} 16" role="img" aria-label="${_name}">
  <style>
    text { font: 12px -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif; fill: #59636e; }
    @media (prefers-color-scheme: dark) { text { fill: #9198a1; } }
  </style>
  <circle cx="5" cy="8" r="5" fill="${2}"/>
  <text x="14" y="12">${_name}</text>
</svg>
EOF
}

# Fill the array named $3 with the badges that differ from what profile.yaml ($1) needs, or are no longer used;
# if $2 is 'write', also write or remove them
function update_badges() {
  local -n _changed_badges="$3"
  local -a _rows=()
  local -A _used=()
  local _row _file _color _width _name _path _svg
  _changed_badges=()
  if ! capture_lines _rows jq -r -L "$LIB_DIR" 'include "profile"; badges[] | [.file, .color, .width, .name] | @tsv' \
    <<<"$1"; then
    return 1
  fi
  if [[ "$2" == 'write' ]]; then
    if ! mkdir -p -- "$BADGES_DIR"; then return 1; fi # mkdir says why
  fi
  for _row in "${_rows[@]}"; do
    IFS=$'\t' read -r _file _color _width _name <<<"$_row"
    _used["$_file"]=1
    _path="${BADGES_DIR}/${_file}"
    _svg="$(badge_svg "$_name" "$_color" "$_width")"
    if [[ -f "$_path" && "$(<"$_path")" == "$_svg" ]]; then continue; fi
    _changed_badges+=("$_file")
    if [[ "$2" == 'write' ]]; then
      # 2>/dev/null comes first, so that bash's own error is hidden too
      if ! printf '%s\n' "$_svg" 2>/dev/null >"$_path"; then
        echo "error: cannot write ${_path#"${ROOT_DIR}/"}" >&2
        return 1
      fi
    fi
  done
  for _path in "${BADGES_DIR}"/*.svg; do
    if [[ ! -f "$_path" ]]; then continue; fi # no badges yet: the pattern stays as is
    _file="$(basename -- "$_path")"
    if [[ -n "${_used["$_file"]:-}" ]]; then continue; fi
    _changed_badges+=("$_file")
    if [[ "$2" == 'write' ]]; then
      if ! rm -f -- "${BADGES_DIR:?}/${_file:?}"; then return 1; fi
    fi
  done
}

### Helpers

# Fill the array named $1 with the entries of the folder $2, hidden ones included
function folder_entries() {
  local -n _folder_entries="$1"
  local _entry
  _folder_entries=()
  for _entry in "$2"/* "$2"/.[!.]* "$2"/..?*; do
    if [[ -e "$_entry" || -L "$_entry" ]]; then _folder_entries+=("$_entry"); fi # an unmatched pattern stays as is
  done
}

# Put the output lines of a command in an array, failing if the command fails (unlike `< <(cmd)`)
# usage: capture_lines <array> <command> [<args>...]
function capture_lines() {
  local -n _lines="$1"
  local _out
  shift
  if _out="$("$@")"; then :; else return "$?"; fi
  _lines=()
  if [[ -n "$_out" ]]; then mapfile -t _lines <<<"$_out"; fi
}
