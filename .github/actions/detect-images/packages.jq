# Version files mirror release-please's src/strategies/*.ts; other release types fall back to building.
# The docker tag gets a v only when include-v-in-tag is set true.
def norm: sub("^(\\./)+"; "") | sub("/+$"; "") | if . == "" then "." else . end;
def list: if type == "array" then .[] | strings else empty end;
def str_or($d): if type == "string" and . != "" then . else $d end;
. as $c
| ($c.packages // {}) | to_entries
| map(
    (.key | norm) as $p
    | .value as $v
    | def opt($k): $v[$k] // $c[$k];
      def flag($k; $d): if $v | has($k) then $v[$k] elif $c | has($k) then $c[$k] else $d end == true;
      def add_path: (if $p == "." or startswith("/") then sub("^/+"; "") else "\($p)/\(.)" end) | sub("/+$"; "");
    (opt("release-type") | str_or("node")) as $type
    | (opt("version-file") | str_or("")) as $vf
    | {
        path: $p,
        docker_prefix: (if flag("include-v-in-tag"; false) then "v" else "" end),
        component: ($v.component // "" | tostring),
        exclude: [opt("exclude-paths") | list | sub("^/+"; "") | norm],
        changelog: (opt("changelog-path") | str_or("CHANGELOG.md") | add_path),
        version_files: (
          [opt("extra-files") | if type == "array" then .[] else empty end
            | if type == "object" and (.glob | not) then .path else . end | strings | add_path]
          + ({
              node: ["package.json", "package-lock.json", "npm-shrinkwrap.json", "samples/package.json"],
              python: ["setup.cfg", "setup.py", "pyproject.toml"],
              simple: [$vf | str_or("version.txt")],
              go: [$vf | select(. != "")]
            }[$type] // [] | map(add_path))
          + (if $type == "node" or $type == "python" then ["changelog.json"] else [] end)
        ),
        python: ($type == "python")
      }
  )
