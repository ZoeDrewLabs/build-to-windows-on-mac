# gaming.sh — edição "+ Gaming": Steam pronta, tradutor gráfico certo para cada jogo,
# teste na primeira vez (atrás de uma tela de carregamento do app) e plano B automático.
#
# Edição: arquivo Contents/Resources/edition ("gaming"), gravado pelo app/build.sh, ou ZOG_EDITION.
# Na edição geral a escolha automática do tradutor também vale; o teste/plano B é só da + Gaming.
#
# Variáveis para testar (Terminal):
#   ZOG_SIMULAR_FALHA=d3dmetal,dxmt   finge que o jogo falhou com esses tradutores
#   ZOG_TESTE_SEGUNDOS (25)  ZOG_VIGIA_SEGUNDOS (60)  ZOG_ESPERA_JOGO (180)  ZOG_PLANO_B=0 desliga
#   ZOG_TESTE_SECO=1   não abre/fecha a Steam de verdade (só mostra o que faria)

EDITION="${ZOG_EDITION:-}"
[[ -z "$EDITION" && -f "$RES/edition" ]] && EDITION="$(<"$RES/edition")"
EDITION="${EDITION:-geral}"
is_gaming() { [[ "$EDITION" == gaming ]]; }

RENDERER_CHAIN=(d3dmetal dxmt dxvk wined3d)       # do mais rápido ao mais compatível
renderer_label() {
  case "$1" in d3dmetal) print D3DMetal ;; dxmt) print DXMT ;; dxvk) print DXVK ;; wined3d) print WineD3D ;; *) print -r -- "$1" ;; esac
}
# Ordem de tentativa: o escolhido primeiro, depois os outros na ordem da cadeia
renderer_candidates() {
  local r out=("$1") i
  i=${RENDERER_CHAIN[(i)$1]}
  for r in ${RENDERER_CHAIN[i+1,-1]} ${RENDERER_CHAIN[1,i-1]}; do out+=($r); done
  print -r -- "${out[@]}"
}

# Erros de DirectX/gráficos que, no log, querem dizer "este tradutor não serve para este jogo"
DX_ERR='CheckMultisampleQualityLevels|D3D1[012]CreateDevice[^\n]*fail|failed to create (a )?(d3d|direct3d|dx|graphics) ?device|DXGI_ERROR_|0x887a00|Direct3D[^\n]*(not supported|failed|error)|unable to create (the )?(device|swap ?chain)|Unhandled page fault|wine: Unhandled exception'

# ---------- Steam: bibliotecas e pasta do jogo ----------
# Caminho do Windows → Mac, dentro da garrafa atual (as letras de unidade ficam em dosdevices/)
win_to_mac() {
  local p="$1" rest
  rest="${p[3,-1]}"; rest="${rest//\\\\//}"; rest="${rest//\\//}"
  print -r -- "$BOTTLE/dosdevices/${(L)p[1]}:$rest"
}
acf_field() { grep -m1 -iE "^[[:space:]]*\"$2\"" "$1" 2>/dev/null | sed -E 's/^[[:space:]]*"[^"]*"[[:space:]]*"(.*)"[[:space:]]*$/\1/'; }

steam_libraries() {   # uma pasta por linha (a da Steam e as de libraryfolders.vdf), sem repetir
  local vdf="${STEAM_EXE:h}/steamapps/libraryfolders.vdf" line v
  {
    print -r -- "${STEAM_EXE:h:A}"
    [[ -f "$vdf" ]] && grep -E '^[[:space:]]*"path"' "$vdf" | while IFS= read -r line; do
      v="${line#*\"path\"}"; v="${v#*\"}"; v="${v%\"*}"
      v="$(win_to_mac "$v")"; [[ -d "$v" ]] && print -r -- "${v:A}"
    done
  } | awk '!s[$0]++'
}

# game_dir <appid> → GAME_DIR, GAME_INSTALLDIR, GAME_NAME (pelo appmanifest_<appid>.acf)
game_dir() {
  local lib acf
  GAME_DIR="" GAME_INSTALLDIR="" GAME_NAME=""
  for lib in "${(@f)$(steam_libraries)}"; do
    acf="$lib/steamapps/appmanifest_$1.acf"
    [[ -f "$acf" ]] || continue
    GAME_INSTALLDIR="$(acf_field "$acf" installdir)"; GAME_NAME="$(acf_field "$acf" name)"
    [[ -n "$GAME_INSTALLDIR" && -d "$lib/steamapps/common/$GAME_INSTALLDIR" ]] || continue
    GAME_DIR="$lib/steamapps/common/$GAME_INSTALLDIR"; return 0
  done
  return 1
}

# Jogos instalados na Steam: appid|nome|perfil|tradutor   (sem ferramentas/redistribuíveis)
steam_library_list() {
  local lib acf id name prof f
  for lib in "${(@f)$(steam_libraries)}"; do
    for acf in "$lib"/steamapps/appmanifest_*.acf(N); do
      id="$(acf_field "$acf" appid)"; name="$(acf_field "$acf" name)"
      [[ -z "$id" || "$id" == 228980 ]] && continue
      [[ "$name" == *(Redistributable|Steamworks|Proton|SDK|Dedicated\ Server|Steam\ Linux)* ]] && continue
      prof=""
      for f in "$PROFILES"/*.env(N); do
        [[ "${f:t}" == app-* ]] && continue
        grep -qx "STEAM_APPID=$id" "$f" && { prof="${f:t:r}"; break; }
      done
      print -r -- "$id|$name|$prof|${prof:+$(profile_renderer "$prof")}"
    done
  done
}

# Perfil do jogo pelo appid (cria um simples se ainda não existir) → GAME
profile_for_appid() {
  local f name
  for f in "$PROFILES"/*.env(N); do
    [[ "${f:t}" == app-* ]] && continue
    grep -qx "STEAM_APPID=$1" "$f" && { GAME="${f:t:r}"; return 0; }
  done
  game_dir "$1" >/dev/null; name="${GAME_NAME:-jogo-$1}"
  GAME="$(prefix_slug "$name")"; mkdir -p "$PROFILES"
  [[ -f "$PROFILES/$GAME.env" ]] && GAME="$GAME-$1"
  {
    print -r -- "# Perfil de $name (Steam appid $1)"
    print -r -- "# Criado sozinho na primeira vez que o jogo foi aberto pelo app."
    print -r -- "STEAM_APPID=$1"
  } > "$PROFILES/$GAME.env"
  echo "perfil novo: $GAME ($name)"
}

# ---------- escolha do tradutor pelo motor do jogo ----------
# detect_renderer <pasta do jogo> [exe principal] → DET_RENDERER, DET_MOTIVO, DET_JOGO (1 = é jogo)
detect_renderer() {
  local d="$1" main="${2:-}" exe imp exes
  DET_RENDERER=d3dmetal; DET_MOTIVO="padrão (motor do jogo não reconhecido)"; DET_JOGO=0
  [[ -d "$d" ]] || return 0
  if [[ -f "$d/data.win" || -f "$d/game.win" ]]; then
    DET_RENDERER=dxmt; DET_JOGO=1; DET_MOTIVO="GameMaker (data.win): o D3DMetal falha em CheckMultisampleQualityLevels"; return 0
  fi
  if [[ -f "$d/UnityPlayer.dll" ]]; then DET_RENDERER=d3dmetal; DET_JOGO=1; DET_MOTIVO="Unity (UnityPlayer.dll)"; return 0; fi
  if [[ -n "$(find "$d" -maxdepth 4 -iname '*-Shipping.exe' -print -quit 2>/dev/null)" ]]; then
    DET_RENDERER=d3dmetal; DET_JOGO=1; DET_MOTIVO="Unreal (*-Shipping.exe)"; return 0
  fi
  # Outros: olha o que os .exe da pasta importam. DirectX 9 → DXVK (o D3DMetal não tem DX9).
  [[ -x "$PEINSPECT" ]] || return 0
  exes=(${main:+"$main"} "$d"/*.exe(N.OL[1,6]))
  for exe in "${exes[@]}"; do
    [[ "${(L)exe:t}" == *(unins|crash|setup|redist|vcredist|dxsetup|launcherhelper)* ]] && continue
    imp=",$("$PEINSPECT" "$exe" 2>/dev/null | sed -n 's/^imports=//p'),"
    if [[ "$imp" == *,d3d9.dll,* ]]; then
      DET_RENDERER=dxvk; DET_JOGO=1; DET_MOTIVO="DirectX 9 (${exe:t} importa d3d9.dll; o D3DMetal não tem DX9)"; return 0
    fi
    if [[ "$imp" == *,(d3d11|d3d12|dxgi|d3d10|d3d10_1).dll,* ]]; then
      DET_JOGO=1; DET_MOTIVO="DirectX 10/11/12 (${exe:t})"
    fi
  done
  return 0
}

profile_renderer() {
  grep -E '^ZOG_RENDERER=' "$PROFILES/$1.env" 2>/dev/null | tail -1 | cut -d= -f2 | cut -d' ' -f1 | tr -d "\"'"
}
profile_tested() { grep -q '^ZOG_RENDERER_TESTADO=1' "$PROFILES/$1.env" 2>/dev/null; }
# profile_set_renderer <perfil> <tradutor> <comentário> [testado]
profile_set_renderer() {
  local f="$PROFILES/$1.env"
  mkdir -p "$PROFILES"; touch "$f"
  grep -vE '^(ZOG_RENDERER|ZOG_RENDERER_TESTADO)=' "$f" > "$f.tmp"; mv "$f.tmp" "$f"
  print -r -- "ZOG_RENDERER=$2   # $3" >> "$f"
  [[ "${4:-}" == testado ]] && print -r -- "ZOG_RENDERER_TESTADO=1   # o app testou e funcionou" >> "$f"
  return 0
}

# Escolhe o tradutor do jogo (se o perfil ainda não tem) e já deixa o ambiente pronto.
# auto_renderer <perfil> <pasta> [exe]
auto_renderer() {
  local cur; cur="$(profile_renderer "$1")"
  if [[ -z "$cur" ]]; then
    detect_renderer "$2" "${3:-}"
    if (( DET_JOGO )) || [[ "$1" != app-* ]]; then
      profile_set_renderer "$1" "$DET_RENDERER" "automático: $DET_MOTIVO ($(date +%d/%m/%Y))"
      echo "tradutor escolhido pelo motor do jogo: $(renderer_label $DET_RENDERER) — $DET_MOTIVO"
    fi
    cur="$DET_RENDERER"
  else
    detect_renderer "$2" "${3:-}" >/dev/null
  fi
  export ZOG_RENDERER="$cur"
  set_renderer
}

# ---------- vigiar o jogo nos primeiros segundos ----------
GAME_PAT=""        # pedaço da linha de comando do processo do jogo
GAME_LOG=""        # log onde aparece a saída do jogo
game_alive() {
  local l
  for l in "${(@f)$(ps -axo command= 2>/dev/null)}"; do
    [[ "${(L)l}" == *"${(L)GAME_PAT}"* && "$l" != *zog.sh* ]] && return 0
  done
  return 1
}
kill_game() {   # encerra só os processos do jogo (a Steam continua)
  local pid cmd
  ps -axo pid=,command= 2>/dev/null | while read -r pid cmd; do
    [[ "${(L)cmd}" == *"${(L)GAME_PAT}"* && "$cmd" != *zog.sh* ]] && kill "$pid" 2>/dev/null
  done
  sleep 2
}

# watch_game <segundos vigiando> <segundos esperando abrir> → 0 ok · 1 falhou (WATCH_MOTIVO) · 2 nem abriu
watch_game() {
  local secs="$1" wait="$2" off=0 t=0 gone=0 hit
  [[ -f "$GAME_LOG" ]] && off=$(stat -f %z "$GAME_LOG" 2>/dev/null || print 0)
  WATCH_MOTIVO=""
  progress 0 1 "Esperando o jogo abrir…"
  while ! game_alive; do
    (( t >= wait )) && return 2
    sleep 2; (( t += 2 ))
  done
  [[ -n "${TELA_TEXTO:-}" ]] && print -r -- "TELA-TESTE|on|$TELA_TEXTO"
  t=0
  while (( t < secs )); do
    sleep 3; (( t += 3 ))
    if [[ ",${ZOG_SIMULAR_FALHA:-}," == *",$ZOG_RENDERER,"* ]] && (( t >= 6 )); then
      WATCH_MOTIVO="falha simulada (ZOG_SIMULAR_FALHA)"; return 1
    fi
    if [[ -f "$GAME_LOG" ]]; then
      hit="$(tail -c +$(( off + 1 )) "$GAME_LOG" 2>/dev/null | grep -m1 -iE "$DX_ERR")"
      [[ -n "$hit" ]] && { WATCH_MOTIVO="erro gráfico: ${hit[1,140]}"; return 1; }
    fi
    if game_alive; then gone=0
    elif (( ++gone >= 2 )); then WATCH_MOTIVO="o jogo fechou sozinho depois de ${t}s"; return 1; fi
    progress $t $secs "${TELA_TEXTO:-Conferindo se o jogo abriu bem com $(renderer_label $ZOG_RENDERER)…}"
  done
  return 0
}

# play_loop <perfil> <função que abre> <função que fecha>
# 1ª vez (perfil sem ZOG_RENDERER_TESTADO): teste atrás da tela de carregamento do app, 25 s por tradutor.
# Depois: plano B — vigia 60 s; se o jogo fechar ou der erro de DirectX, tenta o próximo tradutor.
play_loop() {
  local prof="$1" open="$2" close="$3" first="${ZOG_RENDERER:-d3dmetal}" r n=0 testing=0 secs rc
  if ! is_gaming || [[ "${ZOG_PLANO_B:-1}" == 0 ]]; then $open; return; fi
  profile_tested "$prof" || testing=1
  local cands=($(renderer_candidates "$first"))
  for r in $cands; do
    (( n++ ))
    export ZOG_RENDERER=$r; set_renderer >/dev/null
    if (( testing )); then
      secs=${ZOG_TESTE_SEGUNDOS:-25}
      TELA_TEXTO="Preparando o jogo: testando o tradutor $(renderer_label $r) ($n de ${#cands})…"
      echo "teste da 1ª vez: tradutor $(renderer_label $r) ($n de ${#cands})"
    else
      secs=${ZOG_VIGIA_SEGUNDOS:-60}; TELA_TEXTO=""
      (( n > 1 )) && echo "plano B: tentando o tradutor $(renderer_label $r)"
    fi
    $open || { print -r -- "TELA-TESTE|off"; return 1; }
    export ZOG_REABRIR=1          # já combinado: nas próximas tentativas reabre a Steam sem perguntar
    WATCHING=1; watch_game "$secs" "${ZOG_ESPERA_JOGO:-180}"; rc=$?; WATCHING=0
    case $rc in
      0)
        print -r -- "TELA-TESTE|off"
        if (( testing )) || [[ "$r" != "$first" ]]; then
          profile_set_renderer "$prof" "$r" "funcionou no teste do app ($(date +%d/%m/%Y))" testado
          echo "tradutor gravado no perfil $prof: $(renderer_label $r)"
        fi
        echo "o jogo abriu bem com $(renderer_label $r)."
        return 0 ;;
      2)
        print -r -- "TELA-TESTE|off"
        echo "O jogo não apareceu em ${ZOG_ESPERA_JOGO:-180}s (a Steam pode estar atualizando ou pedindo login). Nada foi mudado."
        return 0 ;;
      *)
        echo "com $(renderer_label $r): $WATCH_MOTIVO"
        $close ;;
    esac
  done
  print -r -- "TELA-TESTE|off"
  profile_set_renderer "$prof" "$first" "nenhum tradutor passou no teste ($(date +%d/%m/%Y)); volta ao automático"
  echo "Nenhum tradutor gráfico funcionou com este jogo. Copie o log e mande para a autora do app."
  return 1
}

# ---------- Steam com o tradutor certo ----------
# Pela Steam, o tradutor vale para a Steam inteira (o jogo herda o ambiente dela).
steam_renderer_now() { [[ -s "$BOTTLE/.zog/steam-tradutor" ]] && print -r -- "$(<"$BOTTLE/.zog/steam-tradutor")" || print d3dmetal; }
steam_game_running() {
  local l
  seco && return 1
  for l in "${(@f)$(ps -axo command= 2>/dev/null)}"; do
    [[ "${(L)l}" == *'steamapps\common\'* && "${(L)l}" != *'steamworks shared'* ]] && return 0
  done
  return 1
}
seco() { [[ "${ZOG_TESTE_SECO:-0}" == 1 ]]; }

close_steam() {
  echo "fechando a Steam..."
  if seco; then echo "(seco) wine steam.exe -shutdown; wineserver -k"; rm -f "$BOTTLE/.zog/steam-tradutor"; return 0; fi
  "$WINE" "$STEAM_EXE" -shutdown >>"$LOG" 2>&1 &!
  local t=0
  while steam_running && (( t < 45 )); do sleep 1; (( t++ )); done
  WINEPREFIX="$BOTTLE" "$WINESERVER" -k 2>/dev/null
  wait_prefix 30
  rm -f "$BOTTLE/.zog/steam-tradutor"
}

# Se a Steam está aberta com outro tradutor, reabre com o deste jogo (avisando).
ensure_steam_renderer() {
  steam_running || return 0
  local cur; cur="$(steam_renderer_now)"
  [[ "$cur" == "${ZOG_RENDERER:-d3dmetal}" ]] && return 0
  if steam_game_running; then
    echo "Outro jogo da Steam está aberto com o tradutor $(renderer_label $cur). Feche esse jogo e clique em Jogar de novo."
    return 1
  fi
  if [[ "${ZOG_PERGUNTAR:-0}" == 1 && "${ZOG_REABRIR:-0}" != 1 ]]; then
    echo "AVISO-REABRIR|$(renderer_label $cur)|$(renderer_label $ZOG_RENDERER)"
    exit 22
  fi
  echo "A Steam estava aberta com o tradutor $(renderer_label $cur); este jogo precisa do $(renderer_label $ZOG_RENDERER). Reabrindo a Steam…"
  progress 0 1 "Reabrindo a Steam com o tradutor $(renderer_label $ZOG_RENDERER)…"
  close_steam
}

# Abre a Steam (ou manda o -applaunch para a Steam já aberta) com o tradutor atual
steam_launch() {
  ensure_steam_renderer || return 1
  if ! steam_running; then
    newlog steam
    mkdir -p "$BOTTLE/.zog"
    print -r -- "${ZOG_RENDERER:-d3dmetal}" > "$BOTTLE/.zog/steam-tradutor"
    print -r -- "$LOG" > "$BOTTLE/.zog/steam-log"
  fi
  GAME_LOG="$(<"$BOTTLE/.zog/steam-log" 2>/dev/null)"
  if seco; then      # teste sem Steam de verdade: um processo falso faz o papel do jogo
    echo "(seco) wine steam.exe $* [tradutor $(renderer_label ${ZOG_RENDERER:-d3dmetal})]"
    [[ -n "$GAME_PAT" ]] && ( exec -a "jogo-falso $GAME_PAT" sleep 600 ) >/dev/null 2>&1 </dev/null &!
    return 0
  fi
  wine_run 0 "$STEAM_EXE" "${STEAM_ARGS[@]}" "$@"
}

# ---------- instalação automática da Steam ----------
install_steam() {
  use_prefix steam
  [[ -f "$STEAM_EXE" ]] && { echo "A Steam já está instalada."; return 0; }
  progress 0 3 "Criando a garrafa da Steam…"
  prefix_exists steam || create_prefix steam "Steam" "" || return 1
  progress 1 3 "Baixando a Steam direto da Valve…"
  # Instalador oficial, baixado agora (os arquivos da Steam são da Valve: o app não os redistribui)
  rm -f "$DOWNLOADS/SteamSetup.exe"
  fetch "$STEAM_SETUP_URL" "$DOWNLOADS/SteamSetup.exe" || { echo "Não consegui baixar a Steam (internet?)."; return 1; }
  progress 2 3 "Instalando a Steam…"
  echo "instalando a Steam de Windows..."
  newlog install-steam
  wine_run 900 "$DOWNLOADS/SteamSetup.exe" /S
  wait_prefix 120
  [[ -f "$STEAM_EXE" ]] || { echo "A Steam não instalou. Veja: zog.sh log"; return 1; }
  apply_display | grep -v "Steam já aberta"           # Retina + escala do Windows pela tela deste Mac
  echo "Steam instalada (tradutor padrão: D3DMetal; cada jogo ganha o dele ao abrir)."
  echo "Na 1ª abertura a Steam se atualiza sozinha (uns minutos) e pede o login."
  progress 3 3 "Steam pronta"
}

# Biblioteca de jogos noutra pasta (ex.: SSD externo): letra de unidade na garrafa + libraryfolders.vdf
add_steam_library() {
  local base="${1:A}" dir letter l vdf n
  [[ -d "$base" ]] || { echo "Pasta não existe: $1"; return 1; }
  dir="$base/SteamLibrary"; [[ "${base:t}" == SteamLibrary ]] && dir="$base"
  use_prefix steam
  [[ -f "$STEAM_EXE" ]] || { echo "A Steam não está instalada."; return 1; }
  steam_running && { echo "Feche a Steam antes (ela regrava a lista de bibliotecas ao sair)."; return 1; }
  mkdir -p "$dir/steamapps/common" || return 1
  letter=""
  for l in "$BOTTLE"/dosdevices/?:(N@); do [[ "${l:A}" == "${dir:A}" ]] && { letter="${${l:t}[1]}"; break; }; done
  if [[ -z "$letter" ]]; then
    for l in s t u v w x y; do [[ -e "$BOTTLE/dosdevices/$l:" || -L "$BOTTLE/dosdevices/$l:" ]] || { letter=$l; break; }; done
    [[ -n "$letter" ]] || { echo "Sem letra de unidade livre na garrafa."; return 1; }
    ln -s "$dir" "$BOTTLE/dosdevices/$letter:"
  fi
  [[ -f "$dir/libraryfolder.vdf" ]] || printf '"libraryfolder"\n{\n\t"contentid"\t\t"0"\n\t"label"\t\t""\n}\n' > "$dir/libraryfolder.vdf"
  vdf="${STEAM_EXE:h}/steamapps/libraryfolders.vdf"
  mkdir -p "${vdf:h}"
  if [[ ! -f "$vdf" ]]; then
    printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"\n\t\t"label"\t\t""\n\t\t"contentid"\t\t"0"\n\t\t"totalsize"\t\t"0"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n}\n' > "$vdf"
  fi
  if grep -qiF "\"${(U)letter}:\\\\\"" "$vdf"; then
    echo "A biblioteca ${(U)letter}: já está na Steam."
  else
    n=$(grep -cE '^\t"[0-9]+"$' "$vdf")
    { sed '$d' "$vdf"
      printf '\t"%s"\n\t{\n\t\t"path"\t\t"%s:\\\\"\n\t\t"label"\t\t""\n\t\t"contentid"\t\t"0"\n\t\t"totalsize"\t\t"0"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n}\n' "$n" "${(U)letter}"
    } > "$vdf.tmp" && mv "$vdf.tmp" "$vdf"
  fi
  echo "Biblioteca de jogos em $dir (na Steam aparece como ${(U)letter}:\\). Ao instalar um jogo, escolha essa unidade."
}
