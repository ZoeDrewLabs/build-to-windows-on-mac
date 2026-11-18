# catalog.sh — catálogo de programas conhecidos (profiles/catalogo.tsv).

# ---------- catálogo de programas conhecidos (profiles/catalogo.tsv) ----------
# Quebra o nome do arquivo em palavras e procura no catálogo. Saída: nome<TAB>situacao<TAB>link<TAB>componentes<TAB>nota
catalog_match() {
  local cat="$PROFILES/catalogo.tsv" words pat line
  [[ -f "$cat" ]] || cat="$SCRIPTS/../profiles/catalogo.tsv"
  [[ -f "$cat" ]] || return 1
  words=" ${${(L)1}//[^a-z0-9+]/ } "; words="${words//  / }"
  while IFS=$'\t' read -r pat line; do
    [[ -z "$pat" || "$pat" == \#* || "$pat" == procura ]] && continue
    for p in ${(s:|:)pat}; do
      [[ "$words" == *" $p "* ]] && { print -r -- "$line"; return 0; }
    done
  done < "$cat"
  return 1
}

# Últimas versões publicadas: "<motor Sikarugir mais novo da mesma série WS12>|<Template mais novo>"
latest_versions() {
  local py='
import json, re, sys, urllib.request
def assets(repo):
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases?per_page=10",
                                 headers={"User-Agent": "BuildToWindowsOnMac"})
    with urllib.request.urlopen(req, timeout=6) as r:
        return [a["name"] for rel in json.load(r) for a in rel["assets"]]
def key(n): return [int(x) for x in re.findall(r"\d+", n)]
eng = [n[:-7] for n in assets(sys.argv[1]) if re.fullmatch(r"WS12WineSikarugir[\d.]+(_\d+)?\.tar\.xz", n)]
tpl = [n[:-7] for n in assets(sys.argv[2]) if re.fullmatch(r"Template-[\d.]+\.tar\.xz", n)]
print((max(eng, key=key) if eng else "") + "|" + (max(tpl, key=key) if tpl else ""))
'
  xcode-select -p >/dev/null 2>&1 || return 1     # sem ferramentas de desenvolvedor: não chama o python3
  python3 -c "$py" "$ENGINES_REPO" "$WRAPPER_REPO" 2>/dev/null
}
