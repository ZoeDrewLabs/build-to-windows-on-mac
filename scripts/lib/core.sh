# core.sh — caminhos, motor do Wine, ambiente e utilidades comuns.
# Carregado pelo zog.sh. Não executar sozinho.

# ---------- pastas ----------
SUPPORT="$HOME/Library/Application Support/BuildToWindowsOnMac"
if [[ -n "${ZOG_HOME:-}" ]]; then ZOG="$ZOG_HOME"
elif [[ -f "$SUPPORT/home" ]]; then ZOG="$(<"$SUPPORT/home")"
else ZOG="$SUPPORT/data"; fi
PREFIXES="$ZOG/Prefixes"                       # uma garrafa (WINEPREFIX) por programa
LOGS="$ZOG/logs"
PROFILES="$ZOG/profiles"
CACHE="$HOME/Library/Caches/BuildToWindowsOnMac"   # downloads reaproveitados entre garrafas
DOWNLOADS="$CACHE/downloads"
export W_CACHE="$CACHE/winetricks"             # cache do winetricks

# Dentro do app: Contents/Resources/{scripts,runtime,tools,profiles}. No projeto: a raiz.
RES="${SCRIPTS:h}"
RUNTIME="$RES/runtime"; [[ -d "$RUNTIME" ]] || RUNTIME="$RES/payload"   # pacotes do motor (instala sem internet)
TOOLS="$RES/tools"
[[ -x "$TOOLS/peinspect" ]] || TOOLS_PE_DEV="$ZOG/tools/peinspect"

# ---------- motor do Wine (versões testadas: 17/11/2026, MacBook Air M4, macOS 27.2) ----------
ENGINE_NAME="WS12WineSikarugir10.0_6"
TEMPLATE_NAME="Template-1.0.11"
ENGINES_REPO="Sikarugir-App/Engines"; WRAPPER_REPO="Sikarugir-App/Wrapper"
ENGINE_URL="https://github.com/$ENGINES_REPO/releases/download/v1.0/$ENGINE_NAME.tar.xz"
TEMPLATE_URL="https://github.com/$WRAPPER_REPO/releases/download/v1.0/$TEMPLATE_NAME.tar.xz"
STEAM_SETUP_URL="https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"

ENGINE="${ZOG_ENGINE:-}"
[[ -z "$ENGINE" && -f "$ZOG/engine/current" ]] && ENGINE="$(<"$ZOG/engine/current")"
ENGINE="${ENGINE:-s10}"
WINE_DIR="$ZOG/engine/$ENGINE"
FW="$ZOG/engine/frameworks"
set_wine_paths() {
  WINE="$WINE_DIR/bin/wine"; [[ -x "$WINE" ]] || WINE="$WINE_DIR/bin/wine64"
  WINESERVER="$WINE_DIR/bin/wineserver"
}
set_wine_paths

# ---------- ambiente comum a todo processo do Wine ----------
# Novo WoW64: o motor Sikarugir 10 roda programas de 32 bits traduzindo as chamadas para 64 bits
# dentro do próprio Wine ("experimental wow64 mode" no log) — não precisa de bibliotecas de 32 bits
# no macOS. Tudo passa pelo Rosetta 2 (o motor é x86_64).
export PATH="$WINE_DIR/bin:$TOOLS:$PATH"        # tools/: cabextract compatível para o winetricks
export DYLD_FALLBACK_LIBRARY_PATH="$FW:$FW/moltenvkcx:$FW/GStreamer.framework/Versions/Current/lib:/usr/lib"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all,err+all}"
# Todo comando wine na mesma garrafa precisa usar os MESMOS valores, senão crasha (exit 136).
export WINEMSYNC=1
export WINEESYNC=1
export ROSETTA_ADVERTISE_AVX=1                  # Unity e outros exigem AVX; o Rosetta traduz
# Não criar atalhos/associações do Linux; o app cuida da lista de programas.
export WINEDLLOVERRIDES="winemenubuilder.exe=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
[[ "${ZOG_HUD:-0}" == 1 ]] && export MTL_HUD_ENABLED=1
# Nome no Dock: DESLIGADO. Para um processo fora de um .app, o Dock e o menu usam o nome do ARQUIVO,
# que precisa ser "wine" (o Wine exige), e os processos filhos sempre rodam por …/bin/wine (fora de
# qualquer .app). tools/docknome.dylib registra o nome no LaunchServices, mas o Dock não usa (testado
# em 18/11/2026). Só resolve compilando o Wine com uma mudança no winemac. Ligar para testes: ZOG_DOCK_ON=1
if [[ -f "$TOOLS/docknome.dylib" && "${ZOG_DOCK_ON:-0}" == 1 ]]; then
  export DYLD_INSERT_LIBRARIES="$TOOLS/docknome.dylib"
  if [[ -f "$PROFILES/nomes-dock.tsv" ]]; then export ZOG_DOCK_MAP="$PROFILES/nomes-dock.tsv"
  elif [[ -f "$RES/profiles/nomes-dock.tsv" ]]; then export ZOG_DOCK_MAP="$RES/profiles/nomes-dock.tsv"; fi
fi

# ---------- utilidades ----------
need_data() {
  if [[ ! -d "$ZOG" ]]; then
    echo "A pasta de dados não existe: $ZOG"
    [[ "$ZOG" == /Volumes/* ]] && echo "Ela fica num disco externo. O SSD está conectado?"
    exit 1
  fi
  [[ -x "$WINE" ]] || { echo "Motor do Wine não instalado em $ZOG. Rode: zog.sh setup"; exit 1; }
  mkdir -p "$LOGS" "$PREFIXES" "$DOWNLOADS" "$W_CACHE"
  seed_microsoft
  migrate_old_layout
}

# Componentes da Microsoft que vêm DENTRO do app (Contents/Resources/runtime/microsoft): Visual C++,
# .NET 4.0/4.8 e as fontes básicas, nos instaladores oficiais e sem modificação (redistribuíveis).
# Copiados uma vez para o cache — assim nenhuma garrafa precisa baixar nada.
seed_microsoft() {
  local m="$RUNTIME/microsoft"
  [[ -d "$m" ]] || return 0
  mkdir -p "$DOWNLOADS" "$W_CACHE"
  [[ -d "$m/downloads" ]] && cp -n "$m"/downloads/*(N.) "$DOWNLOADS/" 2>/dev/null
  [[ -d "$m/winetricks" ]] && cp -Rn "$m"/winetricks/* "$W_CACHE/" 2>/dev/null
  return 0
}

# Rosetta 2: o motor do Wine é x86_64 e roda pelo tradutor da Apple. Ele NÃO pode ir dentro do app
# (componente do macOS; só a Apple distribui), mas o app instala direto da Apple com um clique.
# ZOG_SIMULAR_SEM_ROSETTA=1 finge que falta (para testar o fluxo do app num Mac que já tem).
rosetta_ok() { [[ "${ZOG_SIMULAR_SEM_ROSETTA:-0}" != 1 ]] && arch -x86_64 /usr/bin/true 2>/dev/null; }

need_rosetta() {
  [[ "$(uname -m)" == arm64 ]] || { echo "Este app é para Macs com chip Apple (M1 ou mais novo)."; exit 1; }
  if ! rosetta_ok; then
    echo "PRECISA-ROSETTA|Falta o Rosetta 2, o tradutor de programas Intel da Apple."
    echo "No app, clique em Instalar: ele baixa o Rosetta direto da Apple. Pelo Terminal: zog.sh instalar-rosetta"
    exit 30
  fi
}

# Instala o Rosetta pela ferramenta oficial da Apple (softwareupdate). Quem chama já mostrou a licença.
install_rosetta() {
  rosetta_ok && { echo "O Rosetta 2 já está instalado."; return 0; }
  echo "baixando e instalando o Rosetta 2 direto da Apple..."
  /usr/sbin/softwareupdate --install-rosetta --agree-to-license 2>&1 | grep -vE '^\s*$|agreetolicense|CTRL-C'
  if arch -x86_64 /usr/bin/true 2>/dev/null; then echo "Rosetta 2 instalado."; return 0; fi
  echo "O Rosetta não instalou. Confira a internet e tente de novo, ou rode no Terminal:"
  echo "  softwareupdate --install-rosetta --agree-to-license"
  return 1
}

LOG="/dev/null"
newlog() { LOG="$LOGS/$1-$(date +%Y%m%d-%H%M%S).log"; ln -sf "$LOG" "$LOGS/ultimo.log"; echo "log: $LOG"; }

# Progresso para o app: PROGRESSO|<etapa>|<total>|<texto>
progress() { print -r -- "PROGRESSO|$1|$2|$3"; }

load_profile() {   # variáveis extras em profiles/<nome>.env
  local f="$PROFILES/$1.env"
  [[ -f "$f" ]] && { set -a; source "$f"; set +a; echo "perfil: $1"; }
}
winepath_of() { print -r -- "Z:${1//\//\\}"; }   # print -r: o echo do zsh estraga \U, \z...

fetch() {   # baixa $1 para $2 (com retomada) se ainda não existir
  [[ -s "$2" ]] && return 0
  mkdir -p "${2:h}"
  echo "baixando ${2:t}..."
  curl -fL --retry 3 -C - -o "$2.part" "$1" 2>/dev/null && mv "$2.part" "$2"
}

# O wineserver de cada garrafa tem um socket em /tmp/.wine-<uid>/server-<disco>-<inode da garrafa>/
prefix_server_up() {
  local d; d=$(stat -f '%d %i' "${1:-$BOTTLE}" 2>/dev/null | awk '{printf "server-%x-%x", $1, $2}')
  [[ -n "$d" && -S "/tmp/.wine-$UID/$d/socket" ]]
}
# Steam aberta NESTA garrafa (não confunde com a Steam de outra pasta de dados)
steam_running() {
  if [[ "${ZOG_TESTE_SECO:-0}" == 1 ]]; then [[ -f "$BOTTLE/.zog/steam-tradutor" ]]; return; fi
  prefix_server_up "$BOTTLE" && pgrep -qf 'Steam[/\\]steam\.exe|steamwebhelper\.exe'
}

# Tradutor gráfico do DirectX. Padrão: d3dmetal (Apple). Por programa no perfil:
#   ZOG_RENDERER=dxmt | dxvk | wined3d
# Obs.: o D3DMetal entra pelo WINEDLLPATH_PREPEND; forçar "d3d11=n" para todos quebraria esse caminho.
set_renderer() {
  unset WINEDLLPATH_PREPEND CX_D3DMETALPATH
  case "${ZOG_RENDERER:-d3dmetal}" in
    d3dmetal) export WINEDLLPATH_PREPEND="$FW/renderer/d3dmetal/wine"
              export CX_D3DMETALPATH="$FW/renderer/d3dmetal/external" ;;
    dxmt)     export WINEDLLPATH_PREPEND="$FW/renderer/dxmt/wine" ;;
    dxvk)     export WINEDLLPATH_PREPEND="$FW/renderer/dxvk/wine" ;;   # DXVK → Vulkan → MoltenVK → Metal
    wined3d)  ;;
  esac
  echo "tradutor gráfico: ${ZOG_RENDERER:-d3dmetal}"
}
