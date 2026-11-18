# prefix.sh — PrefixManager: uma garrafa (WINEPREFIX) isolada por programa.
#
# Layout:  <dados>/Prefixes/<nome>/            ← WINEPREFIX
#            drive_c/  system.reg  user.reg     ← criados pelo wineboot
#            .zog/info                          ← metadados (nome de exibição, origem, criado em)
#            .zog/deps                          ← componentes que o provisionador instalou
# Assim, DLLs e registro de um programa corporativo nunca vazam para outro.

# nome seguro para pasta: minúsculas, letras/números/hífen, até 40 caracteres
prefix_slug() {
  local s="${(L)1}"
  s="${s//[^a-z0-9]/-}"; while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  s="${s#-}"; s="${s%-}"; s="${s[1,40]}"
  print -r -- "${s:-programa}"
}

# Sugere o nome da garrafa a partir do instalador: "npp.8.7.Installer.x64.exe" → "npp"
prefix_name_for_file() {
  local base="${(L)1:t:r}" w out=()
  for w in ${=base//[^a-z0-9]/ }; do
    [[ "$w" == (setup|install|installer|instalador|x64|x86|win64|win32|amd64|arm64|64bit|32bit|full|offline|web|enu|ptb|br|latest|release) ]] && continue
    [[ "$w" == <-> || "$w" == v<-> ]] && continue          # números de versão
    out+=("$w"); (( ${#out} == 3 )) && break
  done
  prefix_slug "${(j:-:)out:-programa}"
}

# Seleciona a garrafa: exporta WINEPREFIX e ajusta caminhos que dependem dela.
use_prefix() {
  PREFIX_NAME="$(prefix_slug "$1")"
  BOTTLE="$PREFIXES/$PREFIX_NAME"
  export WINEPREFIX="$BOTTLE"
  STEAM_EXE="$BOTTLE/drive_c/Program Files (x86)/Steam/steam.exe"
}

prefix_exists() { [[ -f "$PREFIXES/$(prefix_slug "$1")/system.reg" ]]; }

# Cria uma garrafa nova, em silêncio. $1 = nome, $2 = nome de exibição (opcional), $3 = origem
create_prefix() {
  use_prefix "$1"
  if [[ -f "$BOTTLE/system.reg" ]]; then echo "garrafa $PREFIX_NAME já existe"; return 0; fi
  mkdir -p "$BOTTLE/.zog"
  newlog "garrafa-$PREFIX_NAME" >/dev/null
  echo "criando a garrafa \"$PREFIX_NAME\"..."
  # wineboot --init gera drive_c (windows/system32, Program Files, users) e system.reg/user.reg.
  # Sem janelas: o Mono/Gecko vêm do próprio motor; winemenubuilder desligado no core.sh.
  run_timeout 300 "$WINE" wineboot --init >>"$LOG" 2>&1
  wait_prefix 120
  "$WINE" reg add "HKCU\\Software\\Wine" /v Version /d win10 /f >>"$LOG" 2>&1
  wait_prefix 60
  if [[ ! -f "$BOTTLE/system.reg" || ! -d "$BOTTLE/drive_c/windows/system32" ]]; then
    echo "A garrafa não foi criada. Veja: zog.sh log"; return 1
  fi
  {
    print -r -- "nome=${2:-$PREFIX_NAME}"
    print -r -- "origem=${3:-}"
    print -r -- "criado=$(date +%Y-%m-%dT%H:%M:%S)"
  } > "$BOTTLE/.zog/info"
  echo "garrafa \"$PREFIX_NAME\" pronta"
}

prefix_info() {   # prefix_info <nome> <campo>
  local f="$PREFIXES/$1/.zog/info"
  [[ -f "$f" ]] && grep -m1 "^$2=" "$f" | cut -d= -f2-
}

# Remove só a garrafa pedida (programa, registro, atalhos e configurações dela).
remove_prefix() {
  local n; n="$(prefix_slug "$1")"
  [[ -d "$PREFIXES/$n" && "$PREFIXES/$n" == "$PREFIXES"/?* ]] || { echo "Garrafa '$n' não existe."; return 1; }
  kill_prefix "$n"
  sleep 1
  rm -rf "$PREFIXES/$n"
  rm -f "$PROFILES/app-$n.env"
  echo "garrafa \"$n\" removida"
}

# Lista: nome|nome de exibição|tamanho|nº de programas
list_prefixes() {
  local p n size count
  for p in "$PREFIXES"/*(N/); do
    [[ -f "$p/system.reg" ]] || continue
    n="${p:t}"
    size=$(du -sh "$p" 2>/dev/null | cut -f1)
    count=$(programs_in "$p" | wc -l | tr -d ' ')
    print -r -- "$n|$(prefix_info "$n" nome)|$size|$count"
  done
}

# Programas (atalhos do Menu Iniciar) de uma garrafa: nome|caminho do .lnk
programs_in() {
  find "$1/drive_c/ProgramData/Microsoft/Windows/Start Menu" \
       "$1/drive_c/users"/*/"AppData/Roaming/Microsoft/Windows/Start Menu" \
       -iname '*.lnk' 2>/dev/null \
    | grep -viE 'uninstall|desinstal|remover|readme|leia-me|help|ajuda|website|manual' \
    | while read -r l; do print -r -- "${${l:t}%.lnk}|$l"; done | sort -u -t'|' -k1,1
}

# Versões até a 1.1 usavam bottles/steam (e bottles/windows). Move para Prefixes/ uma vez só.
migrate_old_layout() {
  local old
  for old in steam windows; do
    if [[ -d "$ZOG/bottles/$old/drive_c" && ! -e "$PREFIXES/${old/windows/geral}" ]]; then
      mkdir -p "$PREFIXES"
      mv "$ZOG/bottles/$old" "$PREFIXES/${old/windows/geral}"
      mkdir -p "$PREFIXES/${old/windows/geral}/.zog"
      [[ -f "$PREFIXES/${old/windows/geral}/.zog/info" ]] || \
        print -r -- "nome=${${old/steam/Steam}/windows/Geral}" > "$PREFIXES/${old/windows/geral}/.zog/info"
      echo "(garrafa antiga \"$old\" movida para Prefixes/${old/windows/geral})"
    fi
  done
  rmdir "$ZOG/bottles" 2>/dev/null
  # downloads antigos (cache/) vão para o cache compartilhado
  if [[ -d "$ZOG/cache" ]]; then
    mkdir -p "$DOWNLOADS"; mv -n "$ZOG"/cache/*(N.) "$DOWNLOADS/" 2>/dev/null; rmdir "$ZOG/cache" 2>/dev/null
  fi
  return 0
}
