# engine-update.sh — trocar o motor do Wine (só pelo Terminal; o app não oferece mais isso).
# Testa a versão nova antes de usar e volta sozinho se ela não iniciar.
engine_update_cmd() {
  local cmd="$1"; shift
  case "$cmd" in
    atualizacoes)
      # Só verifica (rápido, silencioso sem internet). Sai com 10 se houver novidade.
      [[ -x "$WINE" ]] || exit 0
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
        engine_update_cmd voltar >/dev/null
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
  esac
}
