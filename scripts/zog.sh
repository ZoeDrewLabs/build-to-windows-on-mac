#!/bin/zsh
# Build to Windows on Mac — programas e jogos de Windows no Mac, sem máquina virtual
# (Wine Sikarugir 10 com o novo WoW64 + Rosetta 2 + D3DMetal da Apple). Uma garrafa isolada por programa.
#
# Uso:
#   zog.sh setup                       instala a tradução num Mac novo (motor do Wine e tradutores gráficos)
#   zog.sh abrir <arquivo> [garrafa]   instala/roda um programa de Windows (.exe .msi .bat) na garrafa dele
#   zog.sh programas                   programas instalados, de todas as garrafas: garrafa|nome|atalho
#   zog.sh abrir-programa <garrafa> <nome>   abre um programa instalado
#   zog.sh garrafas                    lista as garrafas: nome|exibição|tamanho|programas
#   zog.sh criar-garrafa <nome>        cria uma garrafa vazia (com as fontes do Windows)
#   zog.sh remover-garrafa <nome>      apaga uma garrafa e tudo o que está nela (só ela)
#   zog.sh inspecionar <arquivo.exe>   mostra arquitetura, DLLs importadas e pré-requisitos
#   zog.sh tradutor <garrafa> [nome]   mostra/troca o tradutor gráfico (d3dmetal, dxmt, dxvk, wined3d)
#   zog.sh componentes [garrafa]       componentes do Windows e se estão instalados: id|nome|sim/nao
#   zog.sh instalar-componente <garrafa> <id>...   instala componentes (fila com progresso)
#   zog.sh catalogo <arquivo>          o que o app sabe sobre um programa (versão Mac? funciona?)
#   zog.sh instalar-steam | steam      Steam de Windows (opcional, na garrafa "steam")
#   zog.sh jogar <jogo> | peak         abre um jogo da Steam com o perfil dele
#   zog.sh jogos | novo <jogo> <appid> | salvar <jogo> | restaurar <jogo>   perfis de jogos
#   zog.sh kill [garrafa]              encerra os processos de uma garrafa (ou de todas)
#   zog.sh log [linhas] | cfg [garrafa] | onde | tela [garrafa]
#   zog.sh atualizacoes | atualizar | voltar | motor [nome]   motor do Wine (só pelo Terminal)
#
# Pasta de dados: $ZOG_HOME, ou a escolhida no app (~/Library/Application Support/BuildToWindowsOnMac/home).
# Cache de downloads (compartilhado entre garrafas): ~/Library/Caches/BuildToWindowsOnMac

set -u
SCRIPTS="${0:A:h}"
for m in core process prefix display catalog provision; do source "$SCRIPTS/lib/$m.sh"; done
PEINSPECT="$TOOLS/peinspect"; [[ -x "$PEINSPECT" ]] || PEINSPECT="$ZOG/tools/peinspect"
STEAM_ARGS=()

# Garrafa padrão quando nenhuma é indicada
use_prefix "${ZOG_PREFIXO:-steam}"

# Cancelado pelo app (SIGTERM) ou Ctrl-C: encerra os processos da garrafa em uso, sem deixar órfãos.
trap 'echo "cancelado — encerrando a garrafa $PREFIX_NAME"; WINEPREFIX="$BOTTLE" "$WINESERVER" -k 2>/dev/null; exit 143' TERM INT

# Depois que um instalador termina: olha os .exe novos e instala o que eles importam.
post_install_scan() {
  local marker="$1" exes deps
  exes=("${(@f)$(find "$BOTTLE/drive_c/Program Files" "$BOTTLE/drive_c/Program Files (x86)" \
                 "$BOTTLE/drive_c/users" -iname '*.exe' -newer "$marker" -size +20k 2>/dev/null \
                 | grep -viE 'unins|uninst|setup|update|crash|helper' | head -60)}")
  (( ${#exes} )) && [[ -n "${exes[1]}" ]] || { echo "nenhum programa novo para analisar"; return 0; }
  deps=$("$PEINSPECT" --deps "${exes[@]}" 2>/dev/null)
  echo "programa instalado analisado (${#exes} executáveis): pré-requisitos = ${deps:-nenhum}"
  [[ -n "$deps" ]] && provision_queue ${(s:,:)deps}
  return 0
}

cmd="${1:-help}"; shift 2>/dev/null
case "$cmd" in
  setup)
    need_rosetta
    mkdir -p "$ZOG"/{engine,logs,profiles} "$PREFIXES" "$DOWNLOADS"
    echo "pasta de dados: $ZOG"
    if [[ ! -x "$ZOG/engine/s10/bin/wine" ]]; then
      if [[ -f "$RUNTIME/engine.tar.xz" ]]; then
        echo "instalando o motor do Wine (do pacote do app)..."
        tar -xJf "$RUNTIME/engine.tar.xz" -C "$ZOG/engine"          # cria engine/s10
      else
        fetch "$ENGINE_URL" "$DOWNLOADS/$ENGINE_NAME.tar.xz" || { echo "falhou o download do motor"; exit 1; }
        T=$(mktemp -d); tar -xJf "$DOWNLOADS/$ENGINE_NAME.tar.xz" -C "$T" && mv "$T/wswine.bundle" "$ZOG/engine/s10"; rm -rf "$T"
      fi
      print -r -- "s10" > "$ZOG/engine/current"
      print -r -- "$ENGINE_NAME" > "$ZOG/engine/s10/.zog-version"
    fi
    if [[ ! -d "$FW/renderer/d3dmetal" ]]; then
      if [[ -f "$RUNTIME/frameworks.tar.xz" ]]; then
        echo "instalando D3DMetal, DXMT e bibliotecas (do pacote do app)..."
        tar -xJf "$RUNTIME/frameworks.tar.xz" -C "$ZOG/engine"      # cria engine/frameworks
      else
        fetch "$TEMPLATE_URL" "$DOWNLOADS/$TEMPLATE_NAME.tar.xz" || { echo "falhou o download dos tradutores"; exit 1; }
        T=$(mktemp -d); tar -xJf "$DOWNLOADS/$TEMPLATE_NAME.tar.xz" -C "$T" && cp -R "$T"/*.app/Contents/Frameworks "$FW"; rm -rf "$T"
      fi
      print -r -- "$TEMPLATE_NAME" > "$FW/.zog-version"
    fi
    ENGINE=s10; WINE_DIR="$ZOG/engine/s10"; set_wine_paths
    [[ -x "$WINE" ]] || { echo "O motor do Wine não ficou instalado em $WINE_DIR"; exit 1; }
    mkdir -p "$LOGS"
    for f in "$RES"/profiles/*(N); do [[ -e "$PROFILES/${f:t}" ]] || cp "$f" "$PROFILES/"; done
    migrate_old_layout
    echo "Pronto! Arraste um instalador ou programa de Windows (.exe/.msi) para o app — cada um ganha a própria garrafa."
    if [[ "$(scutil --get HostName 2>/dev/null)" == "" ]] && hostname | grep -qE '^[0-9]'; then
      echo "Aviso: o nome de rede deste Mac é um número ($(hostname)). Se a Steam der 'erro de transporte', rode:"
      echo "  sudo scutil --set HostName \"$(scutil --get LocalHostName)\""
    fi ;;

  # ---------------- programas ----------------
  abrir|run)
    need_data; need_rosetta
    FILE="${1:?uso: zog.sh abrir <arquivo.exe|.msi|.bat> [garrafa]}"
    [[ -f "$FILE" ]] || { echo "Não achei: $FILE"; exit 1; }
    FILE="${FILE:A}"; NAME="${FILE:t:r}"; EXT="${(L)FILE:e}"
    # catálogo: tem versão Mac? não funciona? (o app pergunta antes; ZOG_FORCAR=1 pula)
    C_NOME="" C_COMP=""
    if info=$(catalog_match "$NAME"); then
      IFS=$'\t' read -r C_NOME C_SIT C_LINK C_COMP C_NOTA <<<"$info"
      if [[ "${ZOG_FORCAR:-0}" != 1 ]]; then
        case "$C_SIT" in
          mac) echo "AVISO-MAC|$C_NOME|$C_LINK|$C_NOTA"; exit 20 ;;
          nao) echo "AVISO-NAO|$C_NOME|-|$C_NOTA";       exit 21 ;;
        esac
      fi
      echo "programa reconhecido: $C_NOME ($C_SIT) — $C_NOTA"
    fi
    # garrafa: a indicada, a do catálogo ou uma com o nome do instalador
    PNAME="${2:-${ZOG_PREFIXO:-}}"
    [[ -z "$PNAME" && -n "$C_NOME" ]] && PNAME="$(prefix_slug "$C_NOME")"
    [[ -z "$PNAME" ]] && PNAME="$(prefix_name_for_file "$FILE")"
    use_prefix "$PNAME"
    newlog "app-$PREFIX_NAME"
    # inspeção do cabeçalho PE: arquitetura, importações, instalador?
    PE=""; DEPS=""; KIND=""; ARCH=""; FLAGS=""
    if [[ "$EXT" == exe && -x "$PEINSPECT" ]]; then
      PE=$("$PEINSPECT" "$FILE" 2>/dev/null)
      ARCH=$(print -r -- "$PE" | sed -n 's/^arch=//p'); KIND=$(print -r -- "$PE" | sed -n 's/^installer=//p')
      DEPS=$(print -r -- "$PE" | sed -n 's/^deps=//p'); FLAGS=$(print -r -- "$PE" | sed -n 's/^flags=//p')
      echo "executável: ${ARCH:-?}${KIND:+, instalador $KIND}${DEPS:+, precisa de $DEPS}${FLAGS:+, $FLAGS}"
    fi
    [[ "$EXT" == msi ]] && KIND=msi
    # garrafa nova: cria + base (fontes do Windows)
    NOVA=0
    if ! prefix_exists "$PREFIX_NAME"; then
      NOVA=1
      progress 0 1 "Configurando ambiente…"
      create_prefix "$PREFIX_NAME" "${C_NOME:-$NAME}" "$FILE" || exit 1
    fi
    load_profile "app-$PREFIX_NAME" >/dev/null 2>&1
    apply_display; set_renderer
    # pré-requisitos: base (garrafa nova) + catálogo + o que o executável importa
    WANT=()
    (( NOVA )) && WANT+=($BASE_COMPONENTS)
    [[ -n "$C_COMP" && "$C_COMP" != - ]] && WANT+=(${(s:,:)C_COMP})
    [[ -n "$DEPS" ]] && WANT+=(${(s:,:)DEPS})
    (( ${#WANT} )) && provision_queue ${(u)WANT}
    # Tradutor gráfico automático por tipo de programa (só se o perfil ainda não escolheu um)
    if [[ "$FLAGS" == *gamemaker* ]] && ! grep -q '^ZOG_RENDERER=' "$PROFILES/app-$PREFIX_NAME.env" 2>/dev/null; then
      print -r -- 'ZOG_RENDERER=dxmt   # GameMaker: o D3DMetal falha em CheckMultisampleQualityLevels' >> "$PROFILES/app-$PREFIX_NAME.env"
      export ZOG_RENDERER=dxmt; set_renderer
    fi
    # Electron/WebView2: guarda as flags no perfil do programa para as próximas aberturas
    if [[ "$FLAGS" == *electron* ]]; then
      grep -q '^ZOG_ARGS=' "$PROFILES/app-$PREFIX_NAME.env" 2>/dev/null || \
        print -r -- 'ZOG_ARGS="--no-sandbox"   # Electron no Wine: o sandbox do Chromium não funciona' >> "$PROFILES/app-$PREFIX_NAME.env"
      ZOG_ARGS="--no-sandbox"
    fi
    cd "${FILE:h}"
    MARKER="$BOTTLE/.zog/antes-da-instalacao"; touch "$MARKER"
    if [[ -n "$KIND" ]]; then
      # Instalador: espera terminar (a pessoa segue as janelas dele), depois analisa o que foi instalado.
      progress 0 1 "Instalando ${C_NOME:-$NAME} — siga as janelas do instalador"
      echo "instalando ${C_NOME:-$NAME} na garrafa \"$PREFIX_NAME\"..."
      case "$EXT" in
        msi) wine_run "${ZOG_TIMEOUT_INSTALADOR:-7200}" msiexec /i "$FILE" ;;
        *)   wine_run "${ZOG_TIMEOUT_INSTALADOR:-7200}" "$FILE" ;;
      esac
      rc=$?
      wait_prefix 120
      (( rc == 124 )) && { echo "O instalador passou do tempo limite e foi encerrado."; exit 124; }
      post_install_scan "$MARKER"
      echo "instalação terminada (código $rc). Os programas aparecem na lista do app."
      exit 0
    fi
    # Programa comum: roda solto
    echo "abrindo ${C_NOME:-$NAME} na garrafa \"$PREFIX_NAME\"..."
    case "$EXT" in
      bat|cmd) wine_run 0 cmd /c "$FILE" ;;
      *)       wine_run 0 "$FILE" ${=ZOG_ARGS:-} ;;
    esac ;;
  programas)
    need_data
    for p in "$PREFIXES"/*(N/); do
      programs_in "$p" | while IFS='|' read -r n l; do print -r -- "${p:t}|$n|$l"; done
    done ;;
  abrir-programa)
    need_data; need_rosetta
    use_prefix "${1:?uso: zog.sh abrir-programa <garrafa> <nome>}"
    NAME="${2:?falta o nome do programa}"
    LNK=$(programs_in "$BOTTLE" | awk -F'|' -v n="$NAME" '$1==n{print $2; exit}')
    [[ -n "$LNK" ]] || { echo "Não achei o programa '$NAME' na garrafa $PREFIX_NAME."; exit 1; }
    load_profile "app-$PREFIX_NAME" >/dev/null 2>&1
    apply_display; set_renderer; newlog "app-$PREFIX_NAME"
    echo "abrindo $NAME..."
    wine_run 0 start /unix "$LNK" ${=ZOG_ARGS:-} ;;
  garrafas)       need_data; list_prefixes ;;
  tradutor)
    # zog.sh tradutor <garrafa> [d3dmetal|dxmt|dxvk|wined3d] — mostra ou troca o tradutor gráfico do programa
    need_data; use_prefix "${1:?uso: zog.sh tradutor <garrafa> [d3dmetal|dxmt|dxvk|wined3d]}"
    f="$PROFILES/app-$PREFIX_NAME.env"
    if [[ -z "${2:-}" ]]; then
      print -r -- "$(grep -m1 '^ZOG_RENDERER=' "$f" 2>/dev/null | cut -d= -f2 | cut -d' ' -f1 || true)"; exit 0
    fi
    [[ "$2" == (d3dmetal|dxmt|dxvk|wined3d) ]] || { echo "Tradutor desconhecido: $2"; exit 1; }
    mkdir -p "$PROFILES"; touch "$f"
    grep -v '^ZOG_RENDERER=' "$f" > "$f.tmp"; mv "$f.tmp" "$f"
    print -r -- "ZOG_RENDERER=$2   # escolhido no app em $(date +%d/%m/%Y)" >> "$f"
    echo "garrafa $PREFIX_NAME: tradutor gráfico = $2 (vale na próxima vez que o programa abrir)" ;;
  criar-garrafa)
    need_data; need_rosetta
    create_prefix "${1:?uso: zog.sh criar-garrafa <nome>}" "${2:-$1}" || exit 1
    provision_queue $BASE_COMPONENTS ;;
  remover-garrafa) need_data; remove_prefix "${1:?uso: zog.sh remover-garrafa <nome>}" ;;
  inspecionar)
    [[ -x "$PEINSPECT" ]] || { echo "peinspect não encontrado"; exit 1; }
    "$PEINSPECT" "${1:?uso: zog.sh inspecionar <arquivo.exe>}" ;;

  # ---------------- componentes ----------------
  componentes)
    need_data
    [[ -n "${1:-}" ]] && use_prefix "$1"
    for c in $COMPONENTES; do
      id="${c%%|*}"; comp_installed "$id" && st=sim || st=nao
      print -r -- "$id|${c#*|}|$st"
    done ;;
  instalar-componente)
    need_data; need_rosetta
    use_prefix "${1:?uso: zog.sh instalar-componente <garrafa> <id>...}"; shift
    prefix_exists "$PREFIX_NAME" || { echo "Garrafa '$PREFIX_NAME' não existe."; exit 1; }
    newlog "componente-$PREFIX_NAME"
    provision_queue "$@" ;;
  catalogo) catalog_match "${1:?uso: zog.sh catalogo <nome do arquivo>}" || echo "não está no catálogo" ;;

  # ---------------- Steam e jogos (garrafa "steam") ----------------
  instalar-steam)
    need_data; need_rosetta; use_prefix steam
    [[ -f "$STEAM_EXE" ]] && { echo "A Steam já está instalada."; exit 0; }
    prefix_exists steam || create_prefix steam "Steam" "" || exit 1
    fetch "$STEAM_SETUP_URL" "$DOWNLOADS/SteamSetup.exe" || { echo "Não consegui baixar a Steam (internet?)."; exit 1; }
    echo "instalando a Steam de Windows..."
    newlog install-steam
    wine_run 900 "$DOWNLOADS/SteamSetup.exe" /S
    wait_prefix 120
    [[ -f "$STEAM_EXE" ]] && echo "Steam instalada! Clique em Abrir Steam e entre na sua conta." \
                          || { echo "A Steam não instalou. Veja: zog.sh log"; exit 1; } ;;
  steam)
    need_data; need_rosetta; use_prefix steam
    [[ -f "$STEAM_EXE" ]] || { echo "A Steam não está instalada. Use: zog.sh instalar-steam"; exit 1; }
    apply_display; set_renderer; newlog steam
    wine_run 0 "$STEAM_EXE" "${STEAM_ARGS[@]}" "$@" ;;
  jogar|peak)
    need_data; use_prefix steam
    [[ "$cmd" == peak ]] && GAME=peak || { GAME="${1:-}"; shift 2>/dev/null; }
    [[ -f "$PROFILES/$GAME.env" ]] || { echo "Não tem perfil '$GAME'. Perfis: $(cd "$PROFILES" && ls *.env(N) | grep -v '^app-' | sed 's/\.env//' | tr '\n' ' ')"; exit 1; }
    [[ -f "$STEAM_EXE" ]] || { echo "Esse jogo é da Steam, e a Steam não está instalada. Use: zog.sh instalar-steam"; exit 1; }
    need_rosetta; load_profile "$GAME"; apply_display; set_renderer
    [[ -n "${STEAM_APPID:-}" ]] || { echo "O perfil $GAME não tem STEAM_APPID."; exit 1; }
    if steam_running; then
      echo "Aviso: a Steam já estava aberta, então o jogo usa as configurações com que ela foi aberta."
      echo "Se o perfil mudou algo (tradutor gráfico, FPS), saia da Steam e rode de novo."
    fi
    newlog "$GAME"
    wine_run 0 "$STEAM_EXE" "${STEAM_ARGS[@]}" -applaunch "$STEAM_APPID" "$@" ;;
  jogos)
    for f in "$PROFILES"/*.env(N); do
      n=$(basename "$f" .env); [[ "$n" == app-* ]] && continue
      a=$(grep -m1 '^STEAM_APPID=' "$f" | cut -d= -f2)
      c=""; [[ -f "$PROFILES/$n.config.reg" ]] && c="(configurações salvas)"
      echo "  $n  appid=$a $c"
    done ;;
  novo)
    GAME="${1:?uso: zog.sh novo <jogo> <appid>}"; APPID="${2:?falta o appid da Steam}"
    mkdir -p "$PROFILES"
    f="$PROFILES/$GAME.env"; [[ -f "$f" ]] && { echo "Já existe: $f"; exit 1; }
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

# Tradutor gráfico: d3dmetal (padrão), dxmt, dxvk ou wined3d
# ZOG_RENDERER=d3dmetal

# Contador de FPS da Apple sempre ligado? Descomente:
# MTL_HUD_ENABLED=1
EOF
    echo "Perfil criado: ${NAME:-?} (plataformas na Steam: ${PLAT:-?})"
    [[ "$PLAT" == *mac* ]] && echo "Atenção: esse jogo tem versão nativa para Mac — costuma rodar melhor sem o Wine."
    echo "Abra com: zog.sh jogar $GAME" ;;
  salvar|restaurar)
    need_data; use_prefix steam
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

  # ---------------- manutenção ----------------
  kill)
    need_data
    if [[ -n "${1:-}" ]]; then kill_prefix "$(prefix_slug "$1")"; echo "garrafa $1 fechada."
    else kill_prefix; echo "tudo fechado."; fi ;;
  cfg)  need_data; need_rosetta; use_prefix "${1:-steam}"; "$WINE" winecfg ;;
  log)  tail -n "${1:-80}" "$LOGS/ultimo.log" ;;
  onde) echo "$ZOG" ;;
  tela) need_data; use_prefix "${1:-steam}"; apply_display ;;
  atualizacoes|atualizar|voltar|motor)
    source "$SCRIPTS/lib/engine-update.sh"; engine_update_cmd "$cmd" "$@" ;;
  *)    sed -n '2,26p' "$0" ;;
esac
