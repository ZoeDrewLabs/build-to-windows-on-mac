#!/bin/zsh
# Monta "Build to Windows on Mac.app" e o instalador .dmg para outros Macs com chip Apple.
# Uso: app/build.sh   (precisa só das Command Line Tools da Apple: xcode-select --install)
set -e
SRC="${0:A:h}"
ROOT="${SRC:h}"
OUT="$ROOT/dist"
APP="$OUT/Build to Windows on Mac.app"
VERSION="1.0"

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$APP/Contents/Resources/profiles"

echo "compilando..."
swiftc -parse-as-library -O -target arm64-apple-macos14 "$SRC/main.swift" -o "$APP/Contents/MacOS/BuildToWindowsOnMac"

cp "$ROOT/scripts/zog.sh" "$APP/Contents/Resources/scripts/"
chmod +x "$APP/Contents/Resources/scripts/zog.sh"
# perfis que vão junto (só o .env: as configurações salvas são de cada Mac)
cp "$ROOT"/profiles/*.env "$APP/Contents/Resources/profiles/"

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
mkdir -p "$APP/Contents/Resources/payload"
cp "$PC/engine.tar.xz" "$PC/frameworks.tar.xz" "$APP/Contents/Resources/payload/"

# ícone
if [[ -f "$SRC/AppIcon.icns" ]]; then cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/"; fi

sed "s/__VERSION__/$VERSION/g" "$SRC/Info.plist" > "$APP/Contents/Info.plist"

# assinatura local (ad-hoc): sem ela o macOS nem abre o app em chip Apple
codesign --force --deep -s - "$APP"

# Imagem de disco: arrastar o app para Aplicativos
DMG="$OUT/BuildToWindowsOnMac-$VERSION.dmg"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Aplicativos"
cp "$SRC/LEIA-ME.txt" "$STAGE/LEIA-ME.txt"
hdiutil create -volname "Build to Windows on Mac" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "pronto: $APP"
echo "instalador para outros Macs: $DMG ($(du -h "$DMG" | cut -f1))"
