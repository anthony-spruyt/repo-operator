# need_jsonata: the JSONata tests run where the jsonata package resolves; under CI a missing package fails them
need_jsonata() {
  node -e 'require(process.env.JSONATA_REQUIRE || "jsonata")' 2>/dev/null && return 0
  if [[ -n "${CI:-}" ]]; then
    echo "the jsonata package is not installed" >&2
    return 1
  fi
  skip "the jsonata package is not installed"
}

# jsonata_true <expression> <json input>: the Renovate matchJsonata verdict for one set of fields. evaluate() answers directly in jsonata 1.x and with a promise in 2.x.
jsonata_true() {
  node -e '
    const jsonata = require("jsonata");
    Promise.resolve(jsonata(process.argv[1]).evaluate(JSON.parse(process.argv[2]))).then((r) => console.log(r === true ? "true" : "false"));
  ' "$1" "$2"
}
