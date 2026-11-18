#!/bin/zsh
# Build to Windows on Mac — programas e jogos de Windows no Mac (Wine Sikarugir 10 + D3DMetal da Apple)
#
# Uso:
#   zog.sh setup                instala a tradução num Mac novo (motor do Wine, tradutores, "Windows")
#   zog.sh programas            lista os programas de Windows instalados
#   zog.sh abrir-programa <nome> abre um programa instalado
#   zog.sh instalar-steam       instala a Steam de Windows (opcional, para jogos)
#   zog.sh steam                abre a Steam
#   zog.sh jogar <jogo>         abre um jogo pela Steam com o perfil dele (ex.: zog.sh jogar peak)
#   zog.sh peak                 atalho para "zog.sh jogar peak"
#   zog.sh jogos                lista os perfis de jogos
#   zog.sh novo <jogo> <appid>  cria o perfil de um jogo novo (appid = número da loja Steam)
#   zog.sh salvar <jogo>        guarda as configurações gráficas atuais do jogo no perfil
#   zog.sh restaurar <jogo>     volta as configurações guardadas (com o jogo fechado)
#   zog.sh abrir <arquivo>      roda qualquer programa de Windows (.exe, .msi, .bat)
#   zog.sh componentes          lista os componentes do Windows (Visual C++, .NET) e se estão instalados
#   zog.sh instalar-componente <id>  instala um componente (vcredist, dotnet48)
#   zog.sh catalogo <arquivo>   mostra o que o app sabe sobre um programa (tem versão Mac? funciona?)
#   zog.sh log [linhas]         mostra o fim do último log (para colar no Claude)
#   zog.sh kill                 fecha tudo que está rodando na garrafa
#   zog.sh cfg                  abre o winecfg
#   zog.sh onde                 mostra a pasta de dados em uso
#   zog.sh tela                 confere a tela (Retina/externa) e ajusta a escala do Windows
#   zog.sh atualizacoes         verifica se há motor/tradutores mais novos
#   zog.sh atualizar            instala as versões novas (as antigas ficam guardadas)
#   zog.sh voltar               volta para o motor testado e os tradutores anteriores
#   zog.sh motor [nome]         lista os motores instalados ou escolhe um
#
# Pasta de dados (motor, garrafa, perfis, logs): $ZOG_HOME, ou a escolhida no app
# (~/Library/Application Support/BuildToWindowsOnMac/home), ou ~/Library/Application Support/BuildToWindowsOnMac/data

set -u
SCRIPTS="${0:A:h}"                       # pasta deste script (dentro do app ou no projeto)
SUPPORT="$HOME/Library/Application Support/BuildToWindowsOnMac"
if [[ -n "${ZOG_HOME:-}" ]]; then ZOG="$ZOG_HOME"
elif [[ -f "$SUPPORT/home" ]]; then ZOG="$(<"$SUPPORT/home")"
else ZOG="$SUPPORT/data"; fi

# Versões testadas (17/11/2026, MacBook Air M4, macOS 27.2): a Steam só funcionou com este motor.
ENGINE_NAME="WS12WineSikarugir10.0_6"
TEMPLATE_NAME="Template-1.0.11"
ENGINES_REPO="Sikarugir-App/Engines"; WRAPPER_REPO="Sikarugir-App/Wrapper"
ENGINE_URL="https://github.com/$ENGINES_REPO/releases/download/v1.0/$ENGINE_NAME.tar.xz"
TEMPLATE_URL="https://github.com/$WRAPPER_REPO/releases/download/v1.0/$TEMPLATE_NAME.tar.xz"
STEAM_SETUP_URL="https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
# Pacote que vem dentro do app (instala sem internet): Resources/payload
PAYLOAD="$SCRIPTS/../payload"

# Motor em uso: engine/current (gravado por "atualizar"/"motor"), senão s10
ENGINE="${ZOG_ENGINE:-}"
[[ -z "$ENGINE" && -f "$ZOG/engine/current" ]] && ENGINE="$(<"$ZOG/engine/current")"
ENGINE="${ENGINE:-s10}"
WINE_DIR="$ZOG/engine/$ENGINE"
FW="$ZOG/engine/frameworks"
# Garrafa = o "Windows" traduzido onde ficam os programas. Instalações antigas usavam "steam".
if [[ -n "${ZOG_BOTTLE:-}" ]]; then BOTTLE="$ZOG_BOTTLE"
elif [[ -d "$ZOG/bottles/steam/drive_c" ]]; then BOTTLE="$ZOG/bottles/steam"
else BOTTLE="$ZOG/bottles/windows"; fi
LOGS="$ZOG/logs"
PROFILES="$ZOG/profiles"

export PATH="$WINE_DIR/bin:$PATH"
# Bibliotecas de apoio (freetype, gnutls, SDL2, MoltenVK, GStreamer...) do pacote Sikarugir
export DYLD_FALLBACK_LIBRARY_PATH="$FW:$FW/moltenvkcx:$FW/GStreamer.framework/Versions/Current/lib:/usr/lib"
export WINEPREFIX="$BOTTLE"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all,err+all}"
# Sincronização rápida (menos travadinhas). Todo comando wine na mesma garrafa precisa
# usar os MESMOS valores, senão crasha (exit 136).
export WINEMSYNC=1
export WINEESYNC=1
# Avisa ao jogo que a CPU tem AVX (Rosetta traduz AVX/AVX2; Unity às vezes exige)
export ROSETTA_ADVERTISE_AVX=1
# Contador de FPS da Apple: ZOG_HUD=1 zog.sh peak (ou "Mostrar FPS" no app)
[[ "${ZOG_HUD:-0}" == 1 ]] && export MTL_HUD_ENABLED=1

WINE="$WINE_DIR/bin/wine"; [[ -x "$WINE" ]] || WINE="$WINE_DIR/bin/wine64"
STEAM_EXE="$BOTTLE/drive_c/Program Files (x86)/Steam/steam.exe"
STEAM_ARGS=()   # flags extras da Steam; adicionamos conforme os bugs aparecerem

# Tradutor gráfico do DirectX. Padrão: d3dmetal (Apple). Troca por jogo no perfil ou assim:
#   ZOG_RENDERER=dxmt zog.sh jogar x     (dxmt = DirectX 11 → Metal, open source)
#   ZOG_RENDERER=wined3d zog.sh jogar x  (o do próprio Wine, mais lento, último recurso)
set_renderer() {
  unset WINEDLLPATH_PREPEND CX_D3DMETALPATH
  case "${ZOG_RENDERER:-d3dmetal}" in
    d3dmetal) export WINEDLLPATH_PREPEND="$FW/renderer/d3dmetal/wine"
              export CX_D3DMETALPATH="$FW/renderer/d3dmetal/external" ;;
    dxmt)     export WINEDLLPATH_PREPEND="$FW/renderer/dxmt/wine" ;;
    wined3d)  ;;
  esac
  echo "tradutor gráfico: ${ZOG_RENDERER:-d3dmetal}"
}

need_data() {
  if [[ ! -d "$ZOG" ]]; then
    echo "A pasta de dados não existe: $ZOG"
    [[ "$ZOG" == /Volumes/* ]] && echo "Ela fica num disco externo. O SSD está conectado?"
    exit 1
  fi
  [[ -x "$WINE" ]] || { echo "Motor do Wine não instalado em $ZOG. Rode: zog.sh setup"; exit 1; }
  mkdir -p "$LOGS"
}

need_rosetta() {
  if [[ "$(uname -m)" != arm64 ]]; then
    echo "Este app é para Macs com chip Apple (M1 ou mais novo)."; exit 1
  fi
  if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
    echo "Falta o Rosetta 2 (tradutor da Apple). Rode no Terminal e digite a senha do Mac:"
    echo "  softwareupdate --install-rosetta --agree-to-license"
    exit 1
  fi
}

newlog() { LOG="$LOGS/$1-$(date +%Y%m%d-%H%M%S).log"; ln -sf "$LOG" "$LOGS/ultimo.log"; echo "log: $LOG"; }

load_profile() {   # perfis por jogo: variáveis extras em profiles/<nome>.env
  local f="$PROFILES/$1.env"
  [[ -f "$f" ]] && { set -a; source "$f"; set +a; echo "perfil: $1"; }
}
winepath_of() { print -r -- "Z:${1//\//\\}"; }   # print -r: o echo do zsh estraga \U, \z...

fetch() {   # baixa $1 para $2 (com retomada) se ainda não existir
  [[ -f "$2" ]] && return 0
  echo "baixando $(basename "$2")..."
  curl -fL --retry 3 -C - -o "$2.part" "$1" && mv "$2.part" "$2"
}

steam_running() { pgrep -qf 'Steam[/\\]steam\.exe|steamwebhelper\.exe'; }


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

# Lê a tela principal (onde os programas de Windows abrem): nome, interna/externa,
# pontos (o que o macOS mostra), pixels reais e frequência. Resultado em TELA_*.
# Só usa ferramentas que todo Mac tem (system_profiler + plutil) — nada de Python,
# que num Mac sem as ferramentas de desenvolvedor abriria uma janela pedindo instalação.
detect_display() {
  local j g d ng nd k first="" pick="" v
  TELA_NOME="?"; TELA_TIPO="?"; TELA_PTW=0; TELA_PTH=0; TELA_PXW=0; TELA_PXH=0; TELA_HZ=60
  j=$(mktemp -t zogtela) || return
  system_profiler -json SPDisplaysDataType > "$j" 2>/dev/null
  pj() { plutil -extract "$1" raw -o - "$j" 2>/dev/null; }
  ng=$(pj SPDisplaysDataType); [[ "$ng" == <-> ]] || ng=0
  for (( g = 0; g < ng; g++ )); do
    nd=$(pj "SPDisplaysDataType.$g.spdisplays_ndrvs"); [[ "$nd" == <-> ]] || continue
    for (( d = 0; d < nd; d++ )); do
      k="SPDisplaysDataType.$g.spdisplays_ndrvs.$d"
      [[ "$(pj $k.spdisplays_online)" == spdisplays_no ]] && continue
      [[ -z "$first" ]] && first="$k"
      [[ "$(pj $k.spdisplays_main)" == spdisplays_yes ]] && { pick="$k"; break 2; }
    done
  done
  pick="${pick:-$first}"
  if [[ -n "$pick" ]]; then
    TELA_NOME="$(pj $pick._name)"
    [[ "$(pj $pick.spdisplays_connection_type)" == spdisplays_internal ]] && TELA_TIPO=interna || TELA_TIPO=externa
    v=(${(s: :)$(pj $pick._spdisplays_pixels)});     TELA_PXW=${v[1]:-0}; TELA_PXH=${v[3]:-0}
    v=(${(s: :)$(pj $pick._spdisplays_resolution)}); TELA_PTW=${v[1]:-0}; TELA_PTH=${v[3]:-0}
    [[ "${v[5]:-}" == [0-9]* ]] && TELA_HZ=${${v[5]%Hz}%%.*}
  fi
  rm -f "$j"
  [[ "$TELA_PTW" == <-> ]] || TELA_PTW=0; [[ "$TELA_PXW" == <-> ]] || TELA_PXW=0
  TELA_ESCALA=1
  (( TELA_PTW > 0 && TELA_PXW >= TELA_PTW * 3 / 2 )) && TELA_ESCALA=2
}

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

# ---------- componentes do Windows (instaladores oficiais da Microsoft) ----------
# id|nome
COMPONENTES=(
  "vcredist|Visual C++ 2015–2022 (x64 e x86)"
  "dotnet48|.NET Framework 4.8"
)
# Instalado de verdade? (o Wine já traz arquivos com esses nomes, então não basta ver o arquivo)
#  - Visual C++: o instalador da Microsoft grava VC\Runtimes\X64 Installed=1 no registro
#  - .NET: o .NET real tem clr.dll; o substituto do Wine (Wine Mono) não tem
comp_installed() {   # $1 = id
  case "$1" in
    vcredist) grep -i -A8 'VisualStudio.*14\.0.*VC.*Runtimes.*X64\]' "$BOTTLE/system.reg" 2>/dev/null \
                | grep -qi '"Installed"=dword:00000001' ;;
    dotnet48) [[ -f "$BOTTLE/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll" \
                 && -f "$BOTTLE/drive_c/windows/system32/mscoree.dll" ]] \
                 && ! grep -q --text WINE_MONO_OVERRIDES "$BOTTLE/drive_c/windows/system32/mscoree.dll" ;;
    *) return 1 ;;
  esac
}
install_component() {  # $1 = id
  local id="$1" f
  comp_installed "$id" && { echo "$id: já instalado."; return 0; }
  mkdir -p "$ZOG/cache"
  case "$id" in
    vcredist)
      for a in x64 x86; do
        f="$ZOG/cache/vc_redist.$a.exe"
        fetch "https://aka.ms/vs/17/release/vc_redist.$a.exe" "$f" || return 1
        echo "instalando Visual C++ ($a)..."
        "$WINE" "$f" /install /quiet /norestart >>"$LOG" 2>&1
      done ;;
    dotnet48)
      # Mesma sequência do winetricks (referência do Wine para instalar o .NET de verdade):
      #  1) tira o Wine Mono (o substituto do .NET que vem no Wine), que se passa por ".NET 4.8.1"
      #  2) instala o .NET 4.0 fingindo ser Windows XP — é ele que coloca o mscoree.dll
      #  3) instala o .NET 4.8 fingindo ser Windows 7 (no Windows 10 o instalador acha que já tem)
      #  4) manda o Wine usar o mscoree da Microsoft e volta para Windows 10
      local f40="$ZOG/cache/dotNetFx40_Full_x86_x64.exe" f48="$ZOG/cache/ndp48-x86-x64-allos-enu.exe" g d
      fetch "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe" "$f40" || return 1
      fetch "https://go.microsoft.com/fwlink/?linkid=2088631" "$f48" || return 1
      echo "removendo o Wine Mono (substituto do .NET)..."
      for d in 'Wine Mono Windows Support' 'Wine Mono Runtime' 'Wine Mono'; do
        g=$(WINEDEBUG=-all "$WINE" uninstaller --list 2>&1 | grep "$d" | cut -f1 -d'|' | grep -o '{[^}]*}' | head -1)
        [[ -n "$g" ]] && "$WINE" uninstaller --remove "$g" >>"$LOG" 2>&1
      done
      "$WINE" reg delete "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v3.5" /f >>"$LOG" 2>&1
      "$WINE" reg delete "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v4" /f >>"$LOG" 2>&1
      "$WINE_DIR/bin/wineserver" -w
      for d in system32 syswow64; do
        grep -q --text WINE_MONO_OVERRIDES "$BOTTLE/drive_c/windows/$d/mscoree.dll" 2>/dev/null \
          && rm -f "$BOTTLE/drive_c/windows/$d/mscoree.dll"
      done
      echo "instalando .NET Framework 4.0 (base)..."
      "$WINE" reg add "HKCU\\Software\\Wine" /v Version /d winxp64 /f >>"$LOG" 2>&1
      WINEDLLOVERRIDES=fusion=b "$WINE" "$f40" /q '/c:install.exe /q' >>"$LOG" 2>&1
      "$WINE_DIR/bin/wineserver" -w
      "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v mscoree /d native /f >>"$LOG" 2>&1
      "$WINE" reg add "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" /v Install /t REG_DWORD /d 1 /f >>"$LOG" 2>&1
      "$WINE" reg add "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" /v Version /d 4.0.30319 /f >>"$LOG" 2>&1
      "$WINE" reg add "HKLM\\Software\\Microsoft\\.NETFramework" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f >>"$LOG" 2>&1
      "$WINE" reg add "HKLM\\Software\\Wow6432Node\\.NETFramework" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f >>"$LOG" 2>&1
      echo "instalando .NET Framework 4.8 (demora alguns minutos)..."
      "$WINE" reg add "HKCU\\Software\\Wine" /v Version /d win7 /f >>"$LOG" 2>&1
      WINEDLLOVERRIDES=fusion=b "$WINE" "$f48" /sfxlang:1027 /q /norestart >>"$LOG" 2>&1
      "$WINE_DIR/bin/wineserver" -w
      "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v mscoree /d native /f >>"$LOG" 2>&1
      "$WINE" reg add "HKCU\\Software\\Wine" /v Version /d win10 /f >>"$LOG" 2>&1 ;;
    *) echo "Componente desconhecido: $id"; return 1 ;;
  esac
  "$WINE_DIR/bin/wineserver" -w
  comp_installed "$id" && echo "$id: instalado." || { echo "$id: não instalou. Veja: zog.sh log"; return 1; }
}

# Antes de abrir qualquer coisa: Retina e escala do Windows de acordo com a tela.
#  - tela Retina (escala 2x, interna ou externa): Retina ligado + Windows em 200% (192 DPI)
#    → nítido e no tamanho certo, sem janela gigante nem letra minúscula.
#  - monitor comum (escala 1x): Retina desligado + Windows em 100% (96 DPI).
# Um perfil pode forçar: ZOG_RETINA=y|n e ZOG_DPI=96|120|144|192.
apply_display() {
  detect_display
  local retina dpi
  if (( TELA_ESCALA == 2 )); then retina=y; dpi=192; else retina=n; dpi=96; fi
  retina="${ZOG_RETINA:-$retina}"; dpi="${ZOG_DPI:-$dpi}"
  echo "tela: $TELA_NOME ($TELA_TIPO) ${TELA_PTW}x${TELA_PTH} pontos, ${TELA_PXW}x${TELA_PXH} pixels, ${TELA_ESCALA}x, ${TELA_HZ}Hz → Retina $retina, Windows $(( dpi * 100 / 96 ))%"
  local state="$retina $dpi" cache="$BOTTLE/.tela-aplicada"
  [[ -f "$cache" && "$(<"$cache")" == "$state" ]] && return 0
  "$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /d "$retina" /f >/dev/null 2>&1
  "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1
  "$WINE" reg add "HKLM\\System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts" /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1
  print -r -- "$state" > "$cache"
  steam_running && echo "(a Steam já aberta só pega a nova escala quando for reaberta)"
}

cmd="${1:-help}"; shift 2>/dev/null
case "$cmd" in
  setup)
    need_rosetta
    mkdir -p "$ZOG"/{engine,bottles,logs,profiles,cache}
    echo "pasta de dados: $ZOG"
    if [[ ! -x "$ZOG/engine/s10/bin/wine" ]]; then
      if [[ -f "$PAYLOAD/engine.tar.xz" ]]; then
        echo "instalando o motor do Wine (do pacote do app)..."
        tar -xJf "$PAYLOAD/engine.tar.xz" -C "$ZOG/engine"          # cria engine/s10
      else
        fetch "$ENGINE_URL" "$ZOG/cache/engine.tar.xz" || { echo "falhou o download do motor"; exit 1; }
        echo "instalando o motor do Wine..."
        rm -rf "$ZOG/cache/x" && mkdir -p "$ZOG/cache/x"
        tar -xJf "$ZOG/cache/engine.tar.xz" -C "$ZOG/cache/x" && mv "$ZOG/cache/x/wswine.bundle" "$ZOG/engine/s10"
      fi
      print -r -- "s10" > "$ZOG/engine/current"
      print -r -- "$ENGINE_NAME" > "$ZOG/engine/s10/.zog-version"
    fi
    if [[ ! -d "$FW/renderer/d3dmetal" ]]; then
      if [[ -f "$PAYLOAD/frameworks.tar.xz" ]]; then
        echo "instalando D3DMetal, DXMT e bibliotecas (do pacote do app)..."
        tar -xJf "$PAYLOAD/frameworks.tar.xz" -C "$ZOG/engine"      # cria engine/frameworks
      else
        fetch "$TEMPLATE_URL" "$ZOG/cache/template.tar.xz" || { echo "falhou o download dos tradutores"; exit 1; }
        echo "instalando D3DMetal, DXMT e bibliotecas..."
        rm -rf "$ZOG/cache/x" && mkdir -p "$ZOG/cache/x"
        tar -xJf "$ZOG/cache/template.tar.xz" -C "$ZOG/cache/x"
        cp -R "$ZOG"/cache/x/*.app/Contents/Frameworks "$FW"
      fi
      print -r -- "$TEMPLATE_NAME" > "$FW/.zog-version"
    fi
    rm -rf "$ZOG/cache/x" "$ZOG/cache/engine.tar.xz" "$ZOG/cache/template.tar.xz"
    # o motor acabou de ser instalado: escolhe o executável de novo
    WINE="$WINE_DIR/bin/wine"; [[ -x "$WINE" ]] || WINE="$WINE_DIR/bin/wine64"
    [[ -x "$WINE" ]] || { echo "O motor do Wine não ficou instalado em $WINE_DIR"; exit 1; }
    mkdir -p "$LOGS"
    # perfis que vêm com o app (não sobrescreve os que já existem)
    for f in "$SCRIPTS"/../profiles/*(N); do [[ -e "$PROFILES/${f:t}" ]] || cp "$f" "$PROFILES/"; done
    if [[ ! -d "$BOTTLE/drive_c" ]]; then
      echo "criando a garrafa do Windows..."
      newlog init
      "$WINE" wineboot --init >"$LOG" 2>&1
      "$WINE" reg add "HKCU\\Software\\Wine" /v Version /d win10 /f >>"$LOG" 2>&1
      # Retina e escala do Windows são ajustadas pela tela antes de cada abertura (apply_display)
      "$WINE" reg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /d y /f >>"$LOG" 2>&1
      "$WINE" reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d 192 /f >>"$LOG" 2>&1
      "$WINE" reg add "HKLM\\System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts" /v LogPixels /t REG_DWORD /d 192 /f >>"$LOG" 2>&1
      "$WINE_DIR/bin/wineserver" -w
    fi
    [[ -d "$BOTTLE/drive_c" ]] || { echo "A garrafa do Windows não foi criada. Veja: zog.sh log"; exit 1; }
    echo "Pronto! Arraste um instalador ou programa de Windows (.exe/.msi) para o app — ou instale a Steam."
    if [[ "$(scutil --get HostName 2>/dev/null)" == "" ]] && hostname | grep -qE '^[0-9]'; then
      echo "Aviso: o nome de rede deste Mac é um número ($(hostname)). Se a Steam der 'erro de transporte', rode:"
      echo "  sudo scutil --set HostName \"$(scutil --get LocalHostName)\""
    fi ;;
  instalar-steam)
    # A Steam é opcional: só para quem quer jogos de Windows.
    need_data; need_rosetta
    [[ -f "$STEAM_EXE" ]] && { echo "A Steam já está instalada."; exit 0; }
    mkdir -p "$ZOG/cache"
    fetch "$STEAM_SETUP_URL" "$ZOG/cache/SteamSetup.exe" || { echo "Não consegui baixar a Steam (internet?)."; exit 1; }
    echo "instalando a Steam de Windows..."
    newlog install-steam
    "$WINE" "$ZOG/cache/SteamSetup.exe" /S >"$LOG" 2>&1
    "$WINE_DIR/bin/wineserver" -w
    [[ -f "$STEAM_EXE" ]] && echo "Steam instalada! Clique em Abrir Steam e entre na sua conta." \
                          || { echo "A Steam não instalou. Veja: zog.sh log"; exit 1; } ;;
  steam)
    need_data; need_rosetta
    [[ -f "$STEAM_EXE" ]] || { echo "A Steam não está instalada. Use: zog.sh instalar-steam"; exit 1; }
    apply_display; set_renderer; newlog steam
    "$WINE" "$STEAM_EXE" "${STEAM_ARGS[@]}" "$@" >"$LOG" 2>&1 & disown ;;
  jogar|peak)
    need_data
    [[ "$cmd" == peak ]] && GAME=peak || { GAME="${1:-}"; shift 2>/dev/null; }
    [[ -f "$PROFILES/$GAME.env" ]] || { echo "Não tem perfil '$GAME'. Perfis: $(cd "$PROFILES" && ls *.env(N) | sed 's/\.env//' | tr '\n' ' ')"; exit 1; }
    [[ -f "$STEAM_EXE" ]] || { echo "Esse jogo é da Steam, e a Steam não está instalada. Use: zog.sh instalar-steam"; exit 1; }
    need_rosetta; load_profile "$GAME"; apply_display; set_renderer
    [[ -n "${STEAM_APPID:-}" ]] || { echo "O perfil $GAME não tem STEAM_APPID."; exit 1; }
    if steam_running; then
      echo "Aviso: a Steam já estava aberta, então o jogo usa as configurações com que ela foi aberta."
      echo "Se o perfil mudou algo (tradutor gráfico, FPS), saia da Steam e rode de novo."
    fi
    newlog "$GAME"
    "$WINE" "$STEAM_EXE" "${STEAM_ARGS[@]}" -applaunch "$STEAM_APPID" "$@" >"$LOG" 2>&1 & disown ;;
  jogos)
    for f in "$PROFILES"/*.env(N); do
      n=$(basename "$f" .env); a=$(grep -m1 '^STEAM_APPID=' "$f" | cut -d= -f2)
      c=""; [[ -f "$PROFILES/$n.config.reg" ]] && c="(configurações salvas)"
      echo "  $n  appid=$a $c"
    done ;;
  novo)
    GAME="${1:?uso: zog.sh novo <jogo> <appid>}"; APPID="${2:?falta o appid da Steam}"
    mkdir -p "$PROFILES"
    f="$PROFILES/$GAME.env"; [[ -f "$f" ]] && { echo "Já existe: $f"; exit 1; }
    # Nome e plataformas na loja da Steam (plutil lê JSON; não precisa de Python)
    J=$(mktemp -t zogsteam); curl -s "https://store.steampowered.com/api/appdetails?appids=$APPID&filters=basic,platforms" > "$J"
    NAME=$(plutil -extract "$APPID.data.name" raw -o - "$J" 2>/dev/null)
    PLAT=""; for o in windows mac linux; do
      [[ "$(plutil -extract "$APPID.data.platforms.$o" raw -o - "$J" 2>/dev/null)" == true ]] && PLAT+="$o,"
    done; PLAT="${PLAT%,}"; rm -f "$J"
    cat > "$f" <<EOF
# Perfil de ${NAME:-$GAME} (Steam appid $APPID)
# Cada correção de bug deste jogo entra aqui, com um comentário dizendo o porquê.
STEAM_APPID=$APPID

# Chave do registro onde o jogo guarda as configurações gráficas (para salvar/restaurar).
# Jogos Unity: HKCU\\Software\\<Empresa>\\<Jogo>. Descobrimos na primeira vez que ele rodar.
SETTINGS_KEY=

# Tradutor gráfico: d3dmetal (padrão), dxmt ou wined3d
# ZOG_RENDERER=d3dmetal

# Contador de FPS da Apple sempre ligado? Descomente:
# MTL_HUD_ENABLED=1
EOF
    echo "Perfil criado: ${NAME:-?} (plataformas na Steam: ${PLAT:-?})"
    [[ "$PLAT" == *mac* ]] && echo "Atenção: esse jogo tem versão nativa para Mac — costuma rodar melhor sem o Wine."
    echo "Abra com: zog.sh jogar $GAME" ;;
  salvar|restaurar)
    need_data
    GAME="${1:?uso: zog.sh $cmd <jogo>}"
    load_profile "$GAME" >/dev/null
    [[ -n "${SETTINGS_KEY:-}" ]] || { echo "O perfil $GAME ainda não tem SETTINGS_KEY."; exit 1; }
    out="$PROFILES/$GAME.config.reg"
    if [[ "$cmd" == salvar ]]; then
      rm -f "$out"
      "$WINE" reg export "$SETTINGS_KEY" "$(winepath_of "$out")" /y >/dev/null 2>&1 \
        && echo "Configurações de $GAME salvas." || echo "Não consegui ler $SETTINGS_KEY"
    else
      [[ -f "$out" ]] || { echo "Nada salvo para $GAME ainda."; exit 1; }
      "$WINE" regedit /S "$(winepath_of "$out")" >/dev/null 2>&1 && echo "Configurações de $GAME restauradas."
    fi ;;
  run|abrir)
    # Qualquer programa de Windows: .exe roda direto, .msi instala, .bat roda no cmd.
    need_data; need_rosetta
    FILE="${1:?uso: zog.sh abrir <arquivo.exe|.msi|.bat>}"; shift
    [[ -f "$FILE" ]] || { echo "Não achei: $FILE"; exit 1; }
    FILE="${FILE:A}"
    NAME="${FILE:t:r}"
    if info=$(catalog_match "$NAME"); then
      IFS=$'\t' read -r C_NOME C_SIT C_LINK C_COMP C_NOTA <<<"$info"
      if [[ "${ZOG_FORCAR:-0}" != 1 ]]; then
        case "$C_SIT" in
          mac) echo "AVISO-MAC|$C_NOME|$C_LINK|$C_NOTA"; exit 20 ;;      # o app mostra o aviso e oferece abrir mesmo assim
          nao) echo "AVISO-NAO|$C_NOME|-|$C_NOTA";       exit 21 ;;
        esac
      fi
      echo "programa reconhecido: $C_NOME ($C_SIT) — $C_NOTA"
      newlog "app-${NAME// /_}"
      for c in ${(s:,:)C_COMP}; do [[ "$c" == - ]] || install_component "$c" || true; done
    fi
    load_profile "app-${NAME:l}" >/dev/null 2>&1   # perfil opcional profiles/app-<nome>.env
    apply_display; set_renderer; newlog "app-${NAME// /_}"
    cd "${FILE:h}"                                   # muitos programas procuram arquivos na própria pasta
    case "${FILE:e:l}" in
      msi) echo "instalando $NAME..."; "$WINE" msiexec /i "$FILE" "$@" >"$LOG" 2>&1 & disown ;;
      bat|cmd) "$WINE" cmd /c "$FILE" "$@" >"$LOG" 2>&1 & disown ;;
      *)   echo "abrindo $NAME..."; "$WINE" "$FILE" "$@" >"$LOG" 2>&1 & disown ;;
    esac ;;
  componentes)
    # lista: id|nome|instalado(sim/nao)
    need_data
    for c in $COMPONENTES; do
      id="${c%%|*}"; comp_installed "$id" && st=sim || st=nao
      print -r -- "$id|${c#*|}|$st"
    done ;;
  instalar-componente)
    need_data; need_rosetta
    steam_running && echo "(a Steam está aberta; tudo bem, mas feche programas de Windows abertos se der erro)"
    newlog "componente-${1:-x}"
    install_component "${1:?uso: zog.sh instalar-componente vcredist|dotnet48}" ;;
  catalogo)
    # testa o catálogo com um nome de arquivo: zog.sh catalogo CorelDRAW_2024_Setup.exe
    catalog_match "${1:?uso: zog.sh catalogo <nome do arquivo>}" || echo "não está no catálogo" ;;
  programas)
    # Programas instalados no "Windows" (atalhos do Menu Iniciar), um por linha: nome|caminho do .lnk
    need_data
    find "$BOTTLE/drive_c/ProgramData/Microsoft/Windows/Start Menu" \
         "$BOTTLE/drive_c/users"/*/"AppData/Roaming/Microsoft/Windows/Start Menu" \
         -iname '*.lnk' 2>/dev/null \
      | grep -viE 'uninstall|desinstal|remover|readme|leia-me|help|ajuda|website|manual' \
      | while read -r l; do print -r -- "${${l:t}%.lnk}|$l"; done | sort -u -t'|' -k1,1 ;;
  abrir-programa)
    # Abre um programa instalado pelo nome (como aparece em "programas")
    need_data; need_rosetta
    NAME="${1:?uso: zog.sh abrir-programa <nome>}"
    LNK=$("$0" programas | awk -F'|' -v n="$NAME" '$1==n{print $2; exit}')
    [[ -n "$LNK" ]] || { echo "Não achei o programa '$NAME'."; exit 1; }
    load_profile "app-${NAME:l}" >/dev/null 2>&1
    apply_display; set_renderer; newlog "app-${NAME// /_}"
    echo "abrindo $NAME..."
    "$WINE" start /unix "$LNK" >"$LOG" 2>&1 & disown ;;
  cfg)  need_data; need_rosetta; "$WINE" winecfg ;;
  log)  tail -n "${1:-80}" "$LOGS/ultimo.log" ;;
  kill) need_data; "$WINE_DIR/bin/wineserver" -k 2>/dev/null; echo "tudo fechado." ;;
  atualizacoes)
    # Só verifica (rápido, silencioso sem internet). Sai com 10 se houver novidade.
    need_data >/dev/null 2>&1 || exit 0
    cur_e="$( [[ -f "$WINE_DIR/.zog-version" ]] && <"$WINE_DIR/.zog-version" || echo "$ENGINE_NAME")"
    cur_t="$( [[ -f "$FW/.zog-version" ]] && <"$FW/.zog-version" || echo "$TEMPLATE_NAME")"
    latest=$(latest_versions) || exit 0
    new_e="${latest%%|*}"; new_t="${latest#*|}"
    # versão que já foi testada e falhou neste Mac: não oferecer de novo
    [[ -f "$ZOG/engine/ignorar" && "$(<"$ZOG/engine/ignorar")" == "$latest" ]] && { echo "Tudo em dia."; exit 0; }
    msg=()
    [[ -n "$new_e" && "$new_e" != "$cur_e" ]] && msg+=("motor do Wine: $cur_e → $new_e")
    [[ -n "$new_t" && "$new_t" != "$cur_t" ]] && msg+=("tradutores gráficos: $cur_t → $new_t")
    (( ${#msg} )) || { echo "Tudo em dia."; exit 0; }
    echo "Atualização disponível — ${(j:; :)msg}. A versão atual fica guardada para voltar se algo quebrar."
    exit 10 ;;
  atualizar)
    need_data; need_rosetta
    steam_running && { echo "Saia da Steam e feche os programas de Windows antes de atualizar."; exit 1; }
    latest=$(latest_versions) || { echo "Sem internet ou GitHub fora do ar."; exit 1; }
    new_e="${latest%%|*}"; new_t="${latest#*|}"
    cur_e="$( [[ -f "$WINE_DIR/.zog-version" ]] && <"$WINE_DIR/.zog-version" || echo "$ENGINE_NAME")"
    cur_t="$( [[ -f "$FW/.zog-version" ]] && <"$FW/.zog-version" || echo "$TEMPLATE_NAME")"
    if [[ -n "$new_e" && "$new_e" != "$cur_e" ]]; then
      d="$ZOG/engine/$new_e"
      if [[ ! -x "$d/bin/wine" ]]; then
        fetch "https://github.com/$ENGINES_REPO/releases/download/v1.0/$new_e.tar.xz" "$ZOG/cache/$new_e.tar.xz" || exit 1
        rm -rf "$ZOG/cache/x" && mkdir -p "$ZOG/cache/x"
        tar -xJf "$ZOG/cache/$new_e.tar.xz" -C "$ZOG/cache/x" && mv "$ZOG/cache/x/wswine.bundle" "$d"
        print -r -- "$new_e" > "$d/.zog-version"; rm -rf "$ZOG/cache/x" "$ZOG/cache/$new_e.tar.xz"
      fi
      print -r -- "$new_e" > "$ZOG/engine/current"
      WINE_DIR="$d"; WINE="$d/bin/wine"; export PATH="$d/bin:$PATH"
      echo "motor novo: $new_e (o anterior, $ENGINE, continua guardado)"
      "$WINE" wineboot -u >/dev/null 2>&1; "$WINE_DIR/bin/wineserver" -k 2>/dev/null
    fi
    if [[ -n "$new_t" && "$new_t" != "$cur_t" ]]; then
      fetch "https://github.com/$WRAPPER_REPO/releases/download/v1.0/$new_t.tar.xz" "$ZOG/cache/$new_t.tar.xz" || exit 1
      rm -rf "$ZOG/cache/x" && mkdir -p "$ZOG/cache/x"
      tar -xJf "$ZOG/cache/$new_t.tar.xz" -C "$ZOG/cache/x"
      rm -rf "$ZOG/engine/frameworks-anterior"; mv "$FW" "$ZOG/engine/frameworks-anterior"
      cp -R "$ZOG"/cache/x/*.app/Contents/Frameworks "$FW"
      print -r -- "$new_t" > "$FW/.zog-version"; rm -rf "$ZOG/cache/x" "$ZOG/cache/$new_t.tar.xz"
      echo "tradutores novos: $new_t (os anteriores ficam em engine/frameworks-anterior)"
    fi
    # Teste de verdade antes de dar como pronto: liga o "Windows" com o tradutor gráfico
    # e roda um comando. Se falhar, volta sozinho para a versão anterior.
    echo "testando a versão nova..."
    FW="$ZOG/engine/frameworks"; set_renderer >/dev/null
    export DYLD_FALLBACK_LIBRARY_PATH="$FW:$FW/moltenvkcx:$FW/GStreamer.framework/Versions/Current/lib:/usr/lib"
    "$WINE_DIR/bin/wineserver" -k 2>/dev/null
    out=$("$WINE" cmd /c echo zog-ok 2>&1)
    "$WINE_DIR/bin/wineserver" -k 2>/dev/null
    if [[ "$out" == *zog-ok* && "$out" != *"failed to start wineboot"* ]]; then
      echo "Pronto, a versão nova funcionou. Se algo parar de funcionar: zog.sh voltar"
    else
      print -r -- "$latest" > "$ZOG/engine/ignorar"
      "$0" voltar >/dev/null
      echo "A versão nova NÃO funcionou neste Mac — voltei sozinho para a anterior, que está funcionando."
      echo "Ela não vai ser oferecida de novo; o app avisa quando sair outra."
      exit 1
    fi ;;
  voltar)
    # desfaz a última atualização: motor s10 testado + tradutores anteriores
    need_data
    print -r -- "s10" > "$ZOG/engine/current"
    if [[ -d "$ZOG/engine/frameworks-anterior" ]]; then
      rm -rf "$ZOG/engine/frameworks-nova"; mv "$FW" "$ZOG/engine/frameworks-nova"
      mv "$ZOG/engine/frameworks-anterior" "$FW"
    fi
    echo "Voltei para o motor testado (s10) e os tradutores anteriores." ;;
  motor)
    need_data
    if [[ -n "${1:-}" ]]; then
      [[ -x "$ZOG/engine/$1/bin/wine" ]] || { echo "Motor '$1' não existe."; exit 1; }
      print -r -- "$1" > "$ZOG/engine/current"; echo "motor em uso: $1"
    else
      for d in "$ZOG"/engine/*/bin/wine(N); do e="${d:h:h:t}"; [[ "$e" == "$ENGINE" ]] && echo "* $e" || echo "  $e"; done
    fi ;;
  onde) echo "$ZOG" ;;
  tela) need_data; apply_display ;;
  *)    sed -n '2,32p' "$0" ;;
esac
