# Checks and generated blocks for profile.yaml and contributions/, used by the tasks with `include "profile";`.
# One module on purpose: jq 1.8 crashes when a module includes another whose functions call each other.

# Every project of every group
def projects_of: [(.projects // [])[] | (.items // [])[]];

# Every URL profile.yaml mentions: projects, contributions and the ignored repos
def listed_urls: [projects_of[].url, (.contributions // [])[].url, (.ignored // [])[]];

# Color of language $name: custom_colors first, then github_colors
def color_of($name): (.custom_colors // {})[$name] // (.github_colors // {})[$name];

# Every icon the groups use, sorted
def used_icons: [(.projects // [])[] | objects | .icon | strings] | unique;

# Every language the projects use, sorted
def used_languages: [projects_of[] | (.languages // [])[]] | unique;

### Validation: each def outputs one message per problem

def unknown_keys($allowed; $where):
  (keys - $allowed)[] | "\($where): unknown key \"\(.)\" (allowed: \($allowed | join(", ")))";

# Text that goes into one line of Markdown
def one_line: type == "string" and (test("[\n\r]") | not);

def check_text($key; $where):
  if has($key) | not then empty
  elif (.[$key] | type) != "string" then "\($where).\($key) must be text"
  elif (.[$key] | one_line | not) then "\($where).\($key) must fit on one line"
  else empty end;

# A URL that can go in a Markdown link as it is: http(s), no space, parenthesis, bracket or angle bracket
def link_url: type == "string" and test("^https?://[^\\s()<>\\[\\]]+$");

def check_colors($key):
  if has($key) | not then empty
  elif (.[$key] | type) != "object" then "\($key) must map language names to colors"
  else .[$key] | to_entries[] | select(.value | type != "string" or (test("^#[0-9a-fA-F]{6}$") | not))
    | "\($key).\(.key) must be a color like \"#a259ff\" (in quotes: # starts a YAML comment)" end;

# What projects and contributions share: a name, an http(s) URL, an optional description
def check_link($where):
  (if (.name | type) != "string" or .name == "" then "\($where).name is missing"
   elif (.name | one_line | not) or (.name | test("[\\[\\]]")) then "\($where).name must fit on one line, without [ or ] (it is a link text)"
   else empty end),
  (if .url | link_url | not then "\($where).url must be an http(s) URL without spaces, parentheses, brackets or < >" else empty end),
  check_text("description"; $where);

def check_project($where):
  if type != "object" then "\($where) must be a mapping (name, url, description, languages)"
  else
    unknown_keys(["name", "url", "description", "languages"]; $where),
    check_link($where),
    (if has("languages") | not then empty
     elif (.languages | type) != "array" then "\($where).languages must be a list of names"
     else .languages | to_entries[] | select(.value | type != "string") | "\($where).languages[\(.key)] must be a name" end)
  end;

def check_group($where):
  if type != "object" then "\($where) must be a mapping (title, folded, icon, items)"
  else
    unknown_keys(["title", "folded", "icon", "items"]; $where),
    check_text("title"; $where),
    (if has("icon") | not then empty
     elif (.icon | type) != "string" or (.icon | test("^[A-Za-z0-9._-]+$") | not) then "\($where).icon must be the name of an image of .assets/icons/ (without .svg)"
     elif (.title // "") == "" then "\($where): an icon goes before the title, so the group needs one"
     else empty end),
    (if has("folded") and (.folded | type) != "boolean" then "\($where).folded must be true or false" else empty end),
    (if .folded == true and (.title // "") == "" then "\($where): a folded group needs a title" else empty end),
    (if (.items | type) != "array" or (.items | length) == 0 then "\($where).items must be a list of projects"
     else .items | to_entries[] | .key as $i | .value | check_project("\($where).items[\($i)]") end)
  end;

def check_projects:
  if (.projects | type) != "array" or (.projects | length) == 0 then "projects must be a list of groups"
  else .projects | to_entries[] | .key as $i | .value | check_group("projects[\($i)]") end;

def check_contributions:
  if has("contributions") | not then empty
  elif (.contributions | type) != "array" then "contributions must be a list"
  else .contributions | to_entries[] | .key as $i | .value | "contributions[\($i)]" as $where
    | if type != "object" then "\($where) must be a mapping (name, url, description)"
      else unknown_keys(["name", "url", "description"]; $where), check_link($where) end
  end;

def check_ignored:
  if has("ignored") | not then empty
  elif (.ignored | type) != "array" then "ignored must be a list of URLs"
  else .ignored | to_entries[] | select(.value | link_url | not)
    | "ignored[\(.key)] must be an http(s) URL without spaces, parentheses, brackets or < >" end;

# A URL as compared with others: case and trailing slashes don't count
def url_key: ascii_downcase | sub("/+$"; "");

# The URLs among the given ones that appear more than once, as "<url> is listed more than once in <where>"
def duplicate_urls(urls; $where):
  [urls | url_key] | group_by(.) | map(select(length > 1) | .[0])[] | "\(.) is listed more than once in \($where)";

# The name of group number $i, for messages
def group_name($i): .title // (if $i == 0 then "the main list" else "group \($i + 1)" end);

# A project listed twice in one group
def duplicates_in_a_group:
  .projects | to_entries[] | .key as $i | (.value | group_name($i)) as $group
  | duplicate_urls(.value.items[].url; $group);

# A project in two groups: one message per URL, naming the groups
def projects_in_two_groups:
  [.projects | to_entries[] | .key as $i | (.value | group_name($i)) as $group
    | .value.items | map(.url | url_key) | unique[] | {key: ., group: $group}]
  | group_by(.key) | map(select(length > 1))[]
  | "\(.[0].key) is in more than one group (\(map(.group) | join(", ")))";

# A repo both shown in projects and ignored
def shown_and_ignored:
  [projects_of[].url | url_key] as $shown
  | (.ignored // [])[] | url_key | select(IN($shown[])) | "\(.) is both in projects and in ignored";

# Every problem of profile.yaml, as a list of messages
def validate:
  [
    if type != "object" then "the file must be a mapping (github_colors, custom_colors, projects, contributions, ignored)"
    else
      unknown_keys(["github_colors", "custom_colors", "projects", "contributions", "ignored"]; "top level"),
      check_colors("github_colors"),
      check_colors("custom_colors"),
      check_projects,
      check_contributions,
      check_ignored,
      # Only once the lists are well formed: these read every entry
      if [check_projects, check_contributions, check_ignored] | length > 0 then empty
      else
        duplicates_in_a_group,
        projects_in_two_groups,
        duplicate_urls((.contributions // [])[].url; "contributions"),
        duplicate_urls((.ignored // [])[]; "ignored"),
        shown_and_ignored,
        (. as $p | used_languages[] | select(. as $lang | $p | color_of($lang) == null)
          | "no color for \(.): run `mise run colors`, or add it to custom_colors"),
        (used_languages as $used | (.github_colors // {}) | keys - $used | .[]
          | "github_colors.\(.) is not used by any project: run `mise run colors`")
      end
    end
  ];

### Rendering (`--arg badges` and `--arg icons`: the paths README.md uses)

# The generated blocks README.md must have, in order: projects, and contributions when there are some
def readme_blocks: ["projects"] + if (.contributions // []) | length > 0 then ["contributions"] else [] end;

# File name of a language's badge: "C++" -> "cpp.svg", "Vim Script" -> "vim-script.svg"
def badge_file: ascii_downcase | gsub("\\+"; "p") | gsub("#"; "sharp") | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "") | "\(.).svg";

# Width of a badge: the dot, then the name at 12 px, from Arial's advance widths (per 1000 em, for " " to "~")
# plus 10%, so it also fits the other fonts of GitHub's stack (Segoe UI, San Francisco, Noto Sans)
def badge_width:
  [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556,
   556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667,
   556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556,
   556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722,
   500, 500, 500, 334, 260, 334, 584] as $advance
  | 14 + ([explode[] | if . >= 32 and . <= 126 then $advance[. - 32] else 600 end] | add * 12 / 1000 * 1.1) | ceil;

# Every language badge ([{name, color, file, width}])
def badges: . as $p | used_languages | map(. as $lang | {name: ., color: ($p | color_of($lang)), file: badge_file, width: badge_width});

# A project: bold name and language badges, the description on the next line (each badge is one image, so a line
# break never separates a dot from its name)
def project:
  "- **[\(.name)](\(.url))**"
  + ((.languages // []) | map(" <picture><img src=\"\($ARGS.named.badges)/\(badge_file)\" width=\"\(badge_width)\" height=\"16\" align=\"absmiddle\" alt=\"\(.)\"></picture>") | join(""))
  + if (.description // "") != "" then "<br>\n  \(.description)" else "" end;

def group:
  (.items | map(project) | join("\n")) as $list
  | (if .icon then "<picture><img src=\"\($ARGS.named.icons)/\(.icon).svg\" width=\"18\" height=\"18\" align=\"absmiddle\" alt=\"\"></picture> " else "" end) as $icon
  | if .folded then "<details>\n<summary>\($icon)\(.title)</summary>\n\n\($list)\n\n</details>"
    elif (.title // "") != "" then "**\($icon)\(.title)**\n\n\($list)"
    else $list end;

# Block <!-- generated:projects -->: every group, in order
def projects: .projects | map(group) | join("\n\n");

# Block <!-- generated:contributions -->: one line per contribution
def contributions:
  .contributions | map(
    "- [\(.name)](\(.url))"
    + if (.description // "") != "" then ": \(.description)" else "" end
  )
  | join("\n");

### contributions/patches/: one folder per project, <owner>/<repo>/, with its patches and an index.yaml of their titles

# A file or folder name that can go in a link as it is
def safe_name: test("^[A-Za-z0-9._-]+$");

# What a file name of a project folder says: {number} for a pull request, {branch} for a change never submitted,
# or null for a name that has no place there
def patch_name:
  if test("^[0-9]+-[A-Za-z0-9._-]+[.]patch$") then {number: (capture("^(?<n>[0-9]+)").n | tonumber)}
  elif test("^unsubmitted-[A-Za-z0-9._-]+[.]patch$") then {branch: capture("^unsubmitted-(?<b>.+)[.]patch$").b}
  else null end;

# contributions/patches/ as {files, indexes, strays}, from the records of contributions_records (lib/common.bash)
def contributions_tree($records):
  [$records | split("\n")[] | select(. != "") | split("\t")] as $rows
  | {
      files: [$rows[] | select(.[0] == "file") | (.[1] | split("/")) as [$o, $r, $f]
        | {path: .[1], folder: "\($o)/\($r)", file: $f, year: (.[2] | tonumber? // null), subject: (.[3] == "1")}],
      indexes: [$rows[] | select(.[0] == "index")
        | {folder: .[1]} + if .[2] == "ok" then {titles: (.[3] | fromjson)} else {error: .[3]} end],
      strays: [$rows[] | select(.[0] == "stray") | {path: .[1], kind: .[2]}]
    };

# The patches of $tree ([{path, owner, repo, file, year, title, number or branch}]), once check_patches passes
def patches($tree):
  ($tree.indexes | map({key: .folder, value: (.titles | objects)}) | from_entries) as $titles
  | [$tree.files[] | (.file | patch_name) as $name | select($name != null)
      | (.folder | split("/")) as [$o, $r]
      | {path, owner: $o, repo: $r, file, year, title: ($titles[.folder] // {})[.file]} + $name];

# Every problem of contributions/patches/ ($tree, see contributions_tree), as a list of messages
def check_patches($tree):
  [
    ($tree.strays[] | if .kind == "folder" then "contributions/patches/\(.path)/: a project folder has no subfolders"
      else "contributions/patches/\(.path): files go in project folders, contributions/patches/<owner>/<repo>/" end),
    # Folder names go into links too
    ([$tree.files[].folder, $tree.indexes[].folder] | unique[] | select(split("/") | all(safe_name) | not)
      | "contributions/patches/\(.)/: folder names use only letters, digits, ., _ and -"),
    ($tree.files[] | "contributions/patches/\(.path)" as $where
      | if (.file | patch_name) == null then "\($where): only <number>-<words>.patch, unsubmitted-<branch>.patch and index.yaml go in a project folder (words: letters, digits, ., _ and -)"
        elif .subject | not then "\($where): not a git patch (no Subject: line)"
        elif .year == null then "\($where): no Date: line, so no year"
        else empty end),
    # A folder with files needs an index.yaml
    (([$tree.files[].folder] | unique) - [$tree.indexes[].folder] | .[] | "contributions/patches/\(.)/: no index.yaml (it gives each patch its title)"),
    ($tree.indexes[] | . as $index | "contributions/patches/\(.folder)/index.yaml" as $where
      | [$tree.files[] | select(.folder == $index.folder)] as $files
      | [$files[] | select(.file | patch_name != null) | .file] as $patches
      | if has("error") then "\($where) is not valid YAML: \(.error)"
        elif ($files | length) == 0 then "\($where): the folder has no patch"
        elif (.titles | type) != "object" then "\($where) must map each patch of its folder to its title"
        else
          ($patches - (.titles | keys) | .[] | "\($where): no title for \(.)"),
          ((.titles | keys) - [$files[].file] | .[] | "\($where): \(.) is not a file of this folder"),
          (.titles | to_entries[] | select(.value | type != "string" or . == "") | "\($where): \(.key) must have a title"),
          (.titles | to_entries[] | select(.value | type == "string" and . != "" and (one_line | not)) | "\($where): the title of \(.key) must fit on one line")
        end),
    # Two patches for the same pull request
    ($tree.files | map(select(.file | patch_name | .number != null) | . + (.file | patch_name))
      | group_by([.folder, .number]) | map(select(length > 1))[]
      | "contributions/patches/\(.[0].folder)/: \(length) patches for #\(.[0].number) (\(map(.file) | join(", ")))")
  ];

### Rendering of contributions/README.md: profile.yaml (as JSON) with the patches under "patches"

# Block <!-- generated:highlights -->: the contributions of profile.yaml
def highlights:
  (.contributions // []) | map(
    "- [\(.url | sub("^https?://[^/]+/"; "") | sub("/+$"; ""))](\(.url))"
    + if (.description // "") != "" then ": \(.description)" else "" end
  )
  | join("\n");

def change_line:
  "- [\(.owner)/\(.repo)](https://github.com/\(.owner)/\(.repo))"
  + if .number then " [#\(.number)](https://github.com/\(.owner)/\(.repo)/pull/\(.number))" else "" end
  + " \(.title)"
  + if .branch then " <sub>not submitted</sub>" else "" end
  + " · [patch](patches/\(.path))";

# Block <!-- generated:changes -->: every patch by year, newest first; in a year, by project, then number
def changes:
  .patches | group_by(.year) | reverse
  | map("### \(.[0].year)\n\n" + (sort_by((.owner + "/" + .repo | ascii_downcase), (.number // infinite), .file) | map(change_line) | join("\n")))
  | join("\n\n");
