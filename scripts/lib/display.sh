# display.sh — confere a tela (Retina/externa) e ajusta Retina + escala do Windows por garrafa.

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
