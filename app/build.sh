#!/bin/zsh
# Monta "Build to Windows on Mac.app" e o instalador .dmg para outros Macs com chip Apple.
# Uso: app/build.sh                   edição geral
#      EDITION=gaming app/build.sh    edição "+ Gaming" (Steam instalada sozinha, tradutor por jogo)
#      EDITION=todas app/build.sh     as duas (os dois DMGs vão no mesmo Release)
# Precisa só das Command Line Tools da Apple: xcode-select --install
set -e
SRC="${0:A:h}"
ROOT="${SRC:h}"
OUT="$ROOT/dist"
VERSION="2.1.0"
EDITION="${EDITION:-geral}"
if [[ "$EDITION" == todas ]]; then
  EDITION=geral "$0" && EDITION=gaming "$0"; exit $?
fi
case "$EDITION" in
  geral)  NAME="Build to Windows on Mac";          BUNDLE_ID="local.buildtowindowsonmac.app"
          DMG_BASE="BuildToWindowsOnMac";           ICON="$SRC/AppIcon.icns";        README="$SRC/LEIA-ME.txt" ;;
  gaming) NAME="Build to Windows on Mac + Gaming"; BUNDLE_ID="local.buildtowindowsonmac.gaming"
          DMG_BASE="BuildToWindowsOnMac-Gaming";    ICON="$SRC/AppIcon-gaming.icns"; README="$SRC/LEIA-ME-gaming.txt" ;;
  *) echo "EDITION deve ser geral, gaming ou todas"; exit 1 ;;
esac
echo "== edição: $NAME $VERSION =="
APP="$OUT/$NAME.app"

R="$APP/Contents/Resources"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$R/scripts/lib" "$R/profiles" "$R/tools" "$R/runtime"

echo "compilando o app e o PEInspector..."
swiftc -parse-as-library -O -target arm64-apple-macos14 "$SRC/main.swift" "$SRC/PEInspector.swift" \
  -o "$APP/Contents/MacOS/BuildToWindowsOnMac"
swiftc -parse-as-library -O -target arm64-apple-macos14 "$SRC/PEInspector.swift" "$SRC/peinspect-cli.swift" \
  -o "$R/tools/peinspect"
cp "$R/tools/peinspect" "$ROOT/tools/peinspect"        # versão de desenvolvimento, usada pelo zog.sh do projeto
# nome no Dock (Intel e chip Apple: o Wine roda como Intel pelo Rosetta)
clang -dynamiclib -arch x86_64 -arch arm64 -mmacosx-version-min=12.0 -fobjc-arc -O2 "$SRC/docknome.m" \
  -o "$R/tools/docknome.dylib" -framework Foundation -framework CoreServices
cp "$R/tools/docknome.dylib" "$ROOT/tools/docknome.dylib"

# lançador + módulos (PrefixManager, Provisioner…) e ferramentas
cp "$ROOT/scripts/zog.sh" "$R/scripts/"; cp "$ROOT"/scripts/lib/*.sh "$R/scripts/lib/"
print -r -- "$EDITION" > "$R/edition"           # o zog.sh lê (gaming.sh: is_gaming)
cp "$ROOT/tools/winetricks" "$ROOT/tools/cabextract" "$R/tools/"
chmod +x "$R/scripts/zog.sh" "$R/tools/"*
# perfis que vão junto (só o .env: as configurações salvas são de cada Mac)
cp "$ROOT"/profiles/catalogo.tsv "$ROOT"/profiles/nomes-dock.tsv "$R/profiles/"
for f in "$ROOT"/profiles/*.env(N); do [[ "${f:t}" == app-* ]] || cp "$f" "$R/profiles/"; done   # perfis de jogos; os app-* são de cada Mac

# Pacote embutido (instala sem internet): motor do Wine e tradutores gráficos. A Steam é opcional (baixada no app).
# Gerado uma vez a partir da instalação testada em engine/ e guardado em app/payload-cache.
PC="$SRC/payload-cache"
mkdir -p "$PC"
# Quem clonou do GitHub não tem engine/: baixa as versões testadas direto do Sikarugir.
if [[ ! -x "$ROOT/engine/s10/bin/wine" || ! -d "$ROOT/engine/frameworks/renderer/d3dmetal" ]] \
   && [[ ! -f "$PC/engine.tar.xz" || ! -f "$PC/frameworks.tar.xz" ]]; then
  echo "baixando motor do Wine e tradutores gráficos (versões testadas)..."
  TMP="$(mktemp -d)"
  curl -fL -o "$TMP/e.tar.xz" https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz
  curl -fL -o "$TMP/t.tar.xz" https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz
  mkdir -p "$ROOT/engine" "$TMP/t"
  tar -xJf "$TMP/e.tar.xz" -C "$TMP" && mv "$TMP/wswine.bundle" "$ROOT/engine/s10"
  tar -xJf "$TMP/t.tar.xz" -C "$TMP/t" && cp -R "$TMP"/t/*.app/Contents/Frameworks "$ROOT/engine/frameworks"
  printf %s WS12WineSikarugir10.0_6 > "$ROOT/engine/s10/.zog-version"
  printf %s Template-1.0.11 > "$ROOT/engine/frameworks/.zog-version"
  rm -rf "$TMP"
fi
if [[ ! -f "$PC/engine.tar.xz" ]]; then
  echo "empacotando o motor do Wine (demora alguns minutos)..."
  tar -C "$ROOT/engine" -cJf "$PC/engine.tar.xz.part" s10 && mv "$PC/engine.tar.xz.part" "$PC/engine.tar.xz"
fi
if [[ ! -f "$PC/frameworks.tar.xz" ]]; then
  echo "empacotando D3DMetal, DXMT e bibliotecas (demora alguns minutos)..."
  tar -C "$ROOT/engine" -cJf "$PC/frameworks.tar.xz.part" frameworks && mv "$PC/frameworks.tar.xz.part" "$PC/frameworks.tar.xz"
fi
# Contents/Resources/runtime: o motor vai compactado e é extraído na 1ª abertura. Extraído, ele fica sem a
# "marca de baixado da internet" do macOS — executar centenas de binários do Wine marcados e sem assinatura
# da Apple faria o Gatekeeper bloquear. (Com Developer ID + notarização dá para rodar direto daqui.)
cp "$PC/engine.tar.xz" "$PC/frameworks.tar.xz" "$R/runtime/"

# Componentes da Microsoft embutidos (instaladores oficiais, sem modificação — redistribuíveis):
# Visual C++ 2015–2022, .NET 4.0 + 4.8 e as fontes básicas (corefonts). Instalam sem internet.
MS="$R/runtime/microsoft"; mkdir -p "$MS/downloads" "$MS/winetricks/corefonts"
MC="$HOME/Library/Caches/BuildToWindowsOnMac"
typeset -A MSURL=(
  vc_redist.x64.exe "https://aka.ms/vs/17/release/vc_redist.x64.exe"
  vc_redist.x86.exe "https://aka.ms/vs/17/release/vc_redist.x86.exe"
  dotNetFx40_Full_x86_x64.exe "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
  ndp48-x86-x64-allos-enu.exe "https://go.microsoft.com/fwlink/?linkid=2088631"
)
for f u in ${(kv)MSURL}; do
  [[ -s "$MC/downloads/$f" ]] || { mkdir -p "$MC/downloads"; curl -fL -o "$MC/downloads/$f" "$u"; }
  cp "$MC/downloads/$f" "$MS/downloads/"
done
if [[ -d "$MC/winetricks/corefonts" ]] && ls "$MC"/winetricks/corefonts/*.exe >/dev/null 2>&1; then
  cp "$MC"/winetricks/corefonts/*.exe "$MS/winetricks/corefonts/"
else
  echo "aviso: fontes (corefonts) ainda não estão no cache; instale uma vez com: zog.sh instalar-componente <garrafa> corefonts"
fi
echo "componentes Microsoft embutidos: $(du -sh "$MS" | cut -f1)"

# ícone (o da + Gaming é gerado pelo icon.swift na primeira vez)
if [[ "$EDITION" == gaming && ! -f "$ICON" ]]; then
  T="$(mktemp -d)"; swift "$SRC/icon.swift" "$T" gaming && iconutil -c icns "$T/AppIcon.iconset" -o "$ICON"; rm -rf "$T"
fi
if [[ -f "$ICON" ]]; then cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"; fi

sed -e "s/__VERSION__/$VERSION/g" -e "s/__NAME__/$NAME/g" -e "s/__BUNDLEID__/$BUNDLE_ID/g" -e "s/__EDITION__/$EDITION/g" \
  "$SRC/Info.plist" > "$APP/Contents/Info.plist"

# assinatura local (ad-hoc): sem ela o macOS nem abre o app em chip Apple
codesign --force --deep -s - "$APP"

# Imagem de disco: arrastar o app para Aplicativos
DMG="$OUT/$DMG_BASE-$VERSION.dmg"
STAGE="$OUT/dmg-stage-$EDITION"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Aplicativos"
cp "$README" "$STAGE/LEIA-ME.txt"
cp "$ROOT/LICENSE.md" "$STAGE/LICENCA.md"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "pronto: $APP"
echo "instalador para outros Macs: $DMG ($(du -h "$DMG" | cut -f1))"
