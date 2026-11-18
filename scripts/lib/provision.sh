# provision.sh — DependencyProvisioner: instala pré-requisitos do Windows na garrafa atual,
# em fila, em silêncio, com progresso para o app e cache compartilhado entre garrafas.
#
#  vcredist  Visual C++ 2015–2022 (x64+x86)   instaladores oficiais da Microsoft   (testado)
#  dotnet48  .NET Framework 4.8               sequência do winetricks, feita aqui (testado)
#  corefonts fontes básicas da Microsoft      winetricks + cabextract compatível
#  msxml6    MSXML 6                          INDISPONÍVEL: o pacote da Microsoft usa compressão Quantum,
#                                             que o tar do macOS não abre; fica o MSXML do próprio Wine
#  vcrun2013 Visual C++ 2013                  winetricks
#  vcrun2010 Visual C++ 2010                  winetricks
#  webview2  Microsoft Edge WebView2          winetricks (EXPERIMENTAL: costuma falhar no Wine)

COMPONENTES=(
  "corefonts|Fontes do Windows (Arial, Times, Verdana…)"
  "vcredist|Visual C++ 2015–2022 (x64 e x86)"
  "vcrun2013|Visual C++ 2013"
  "vcrun2010|Visual C++ 2010"
  "dotnet48|.NET Framework 4.8"
  "msxml6|MSXML 6 (usa o do Wine; o da Microsoft não abre no Mac)"
  "webview2|Microsoft Edge WebView2 (experimental)"
)
comp_label() { local c; for c in $COMPONENTES; do [[ "${c%%|*}" == "$1" ]] && { print -r -- "${c#*|}"; return; }; done; print -r -- "$1"; }

WINETRICKS="$TOOLS/winetricks"

# Instalado de verdade? O Wine já traz arquivos com nomes iguais, então olha registro/arquivos reais.
comp_installed() {
  case "$1" in
    vcredist) grep -i -A8 'VisualStudio.*14\.0.*VC.*Runtimes.*X64\]' "$BOTTLE/system.reg" 2>/dev/null \
                | grep -qi '"Installed"=dword:00000001' ;;
    dotnet48) [[ -f "$BOTTLE/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll" \
                 && -f "$BOTTLE/drive_c/windows/system32/mscoree.dll" ]] \
                 && ! grep -q --text WINE_MONO_OVERRIDES "$BOTTLE/drive_c/windows/system32/mscoree.dll" ;;
    corefonts) [[ -f "$BOTTLE/drive_c/windows/Fonts/corefonts.installed" ]] ;;
    *) grep -qx "$1" "$BOTTLE/.zog/deps" 2>/dev/null ;;     # instalados pelo winetricks: anotados aqui
  esac
}
mark_installed() { mkdir -p "$BOTTLE/.zog"; grep -qx "$1" "$BOTTLE/.zog/deps" 2>/dev/null || print -r -- "$1" >> "$BOTTLE/.zog/deps"; }

# O winetricks roda pelo /bin/sh, que é protegido pelo macOS e APAGA as variáveis DYLD_* ao iniciar.
# Sem elas o Wine não acha as bibliotecas (libinotify…). Então o winetricks recebe "wine" e
# "wineserver" intermediários que recolocam as variáveis e chamam o motor de verdade.
make_wine_wrappers() {
  local w="$ZOG/engine/wrap" b
  mkdir -p "$w"
  # o winetricks também procura "wine64" (Linux); no motor Sikarugir o "wine" faz os dois papéis
  for b in wine wine64 wineserver; do
    local target="$b"; [[ "$b" == wine64 && ! -x "$WINE_DIR/bin/wine64" ]] && target=wine
    cat > "$w/$b" <<EOF
#!/bin/zsh
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_FALLBACK_LIBRARY_PATH"
export WINEDLLPATH_PREPEND="\${WINEDLLPATH_PREPEND:-${WINEDLLPATH_PREPEND:-}}"
export CX_D3DMETALPATH="\${CX_D3DMETALPATH:-${CX_D3DMETALPATH:-}}"
exec "$WINE_DIR/bin/$target" "\$@"
EOF
    chmod +x "$w/$b"
  done
  WRAP_DIR="$w"
}

# Roda um verbo do winetricks na garrafa atual, em modo silencioso, com tempo limite.
winetricks_verb() {
  [[ -f "$WINETRICKS" ]] || { echo "winetricks não encontrado em $WINETRICKS"; return 1; }
  mkdir -p "$W_CACHE"
  make_wine_wrappers
  # WINE/WINESERVER explícitos: o winetricks usa o motor do app, nunca um wine do sistema.
  WINE="$WRAP_DIR/wine" WINESERVER="$WRAP_DIR/wineserver" WINETRICKS_LATEST_VERSION_CHECK=disabled \
    run_timeout "${2:-1800}" /bin/sh "$WINETRICKS" --unattended --force "$1" >>"$LOG" 2>&1
}

install_component() {  # $1 = id
  local id="$1" f a rc=0
  comp_installed "$id" && { echo "$id: já instalado."; return 0; }
  case "$id" in
    vcredist)
      for a in x64 x86; do
        f="$DOWNLOADS/vc_redist.$a.exe"
        fetch "https://aka.ms/vs/17/release/vc_redist.$a.exe" "$f" || return 1
        echo "instalando Visual C++ ($a)..."
        wine_run 600 "$f" /install /quiet /norestart
      done ;;
    dotnet48)
      # Mesma sequência do winetricks (referência do Wine), testada aqui:
      #  1) tira o Wine Mono (substituto do .NET), que se passa por ".NET 4.8.1"
      #  2) .NET 4.0 fingindo ser Windows XP — é ele que coloca o mscoree.dll
      #  3) .NET 4.8 fingindo ser Windows 7 (no Windows 10 o instalador acha que já tem)
      #  4) usa o mscoree da Microsoft e volta para Windows 10
      local f40="$DOWNLOADS/dotNetFx40_Full_x86_x64.exe" f48="$DOWNLOADS/ndp48-x86-x64-allos-enu.exe" g d
      fetch "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe" "$f40" || return 1
      fetch "https://go.microsoft.com/fwlink/?linkid=2088631" "$f48" || return 1
      echo "removendo o Wine Mono (substituto do .NET)..."
      for d in 'Wine Mono Windows Support' 'Wine Mono Runtime' 'Wine Mono'; do
        g=$(WINEDEBUG=-all "$WINE" uninstaller --list 2>&1 | grep "$d" | cut -f1 -d'|' | grep -o '{[^}]*}' | head -1)
        [[ -n "$g" ]] && wine_run 300 uninstaller --remove "$g"
      done
      wine_run 60 reg delete "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v3.5" /f
      wine_run 60 reg delete "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v4" /f
      wait_prefix 120
      for d in system32 syswow64; do
        grep -q --text WINE_MONO_OVERRIDES "$BOTTLE/drive_c/windows/$d/mscoree.dll" 2>/dev/null \
          && rm -f "$BOTTLE/drive_c/windows/$d/mscoree.dll"
      done
      echo "instalando .NET Framework 4.0 (base)..."
      wine_run 60 reg add "HKCU\\Software\\Wine" /v Version /d winxp64 /f
      WINEDLLOVERRIDES="$WINEDLLOVERRIDES;fusion=b" wine_run 1800 "$f40" /q '/c:install.exe /q'
      wait_prefix 300
      wine_run 60 reg add "HKCU\\Software\\Wine\\DllOverrides" /v mscoree /d native /f
      wine_run 60 reg add "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" /v Install /t REG_DWORD /d 1 /f
      wine_run 60 reg add "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" /v Version /d 4.0.30319 /f
      wine_run 60 reg add "HKLM\\Software\\Microsoft\\.NETFramework" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f
      wine_run 60 reg add "HKLM\\Software\\Wow6432Node\\.NETFramework" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f
      echo "instalando .NET Framework 4.8 (demora alguns minutos)..."
      wine_run 60 reg add "HKCU\\Software\\Wine" /v Version /d win7 /f
      WINEDLLOVERRIDES="$WINEDLLOVERRIDES;fusion=b" wine_run 2400 "$f48" /sfxlang:1027 /q /norestart
      wait_prefix 300
      wine_run 60 reg add "HKCU\\Software\\Wine\\DllOverrides" /v mscoree /d native /f
      wine_run 60 reg add "HKCU\\Software\\Wine" /v Version /d win10 /f ;;
    msxml6)
      echo "MSXML 6: o instalador da Microsoft usa compressão Quantum, que não abre no Mac sem o cabextract"
      echo "original. O programa vai usar o MSXML que já vem no Wine (atende a maioria dos casos)."
      return 0 ;;
    corefonts|vcrun2013|vcrun2010|webview2)
      echo "instalando $(comp_label "$id")..."
      winetricks_verb "$id" 1800; rc=$?
      (( rc == 0 )) && mark_installed "$id" ;;
    *) echo "Componente desconhecido: $id"; return 1 ;;
  esac
  wait_prefix 300
  if comp_installed "$id"; then echo "$id: instalado."; return 0; fi
  echo "$id: não instalou (código $rc). Veja: zog.sh log"; return 1
}

# Fila: provision_queue comp1 comp2 ... → instala em ordem, com progresso para o app.
# Falha num componente não interrompe os outros; o resultado final volta como código de saída.
provision_queue() {
  local items=() c i=0 fails=0
  for c in "$@"; do [[ -n "$c" && "$c" != - ]] && ! comp_installed "$c" && items+=("$c"); done
  (( ${#items} )) || { echo "pré-requisitos: nada a instalar"; return 0; }
  for c in $items; do
    (( i++ ))
    progress "$i" "${#items}" "Instalando $(comp_label "$c")…"
    install_component "$c" || (( fails++ ))
  done
  progress "${#items}" "${#items}" "Pré-requisitos prontos"
  (( fails == 0 ))
}

# Base de toda garrafa nova de programa (não da Steam): fontes do Windows.
BASE_COMPONENTS=(corefonts)
