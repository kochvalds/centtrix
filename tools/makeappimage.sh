#!/bin/sh
set -e
cd "$(dirname "$0")/.."
ARCH=$(uname -m)
[ "$ARCH" = "amd64" ] && ARCH=x86_64
A=build/AppDir
OUT=Centtrix-Writer-$ARCH.AppImage

gcc -O2 -o build/centtrix-writer tools/writer.c $(pkg-config --cflags --libs gtk+-3.0)

rm -rf "$A"
mkdir -p "$A/usr/bin" "$A/usr/share/applications" "$A/usr/share/icons/hicolor/scalable/apps"
cp build/centtrix-writer "$A/usr/bin/centtrix-writer"
cp tools/writer.svg "$A/usr/share/icons/hicolor/scalable/apps/centtrix-writer.svg"
cp tools/writer.svg "$A/centtrix-writer.svg"
cp tools/centtrix-writer.desktop "$A/centtrix-writer.desktop"
cp tools/centtrix-writer.desktop "$A/usr/share/applications/centtrix-writer.desktop"
cat > "$A/AppRun" <<'EOF'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/bin/centtrix-writer" "$@"
EOF
chmod +x "$A/AppRun"

tool=${APPIMAGETOOL:-build/appimagetool}
if [ ! -x "$tool" ]; then
    curl -fsSL -o "$tool" \
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$ARCH.AppImage"
    chmod +x "$tool"
fi

case "$tool" in
    *.AppImage)
        abs=$(readlink -f "$tool")
        ext=build/appimagetool.dir
        if [ ! -x "$ext/AppRun" ]; then
            rm -rf build/ai-extract
            mkdir -p build/ai-extract
            ( cd build/ai-extract && "$abs" --appimage-extract >/dev/null )
            rm -rf "$ext"
            mv build/ai-extract/squashfs-root "$ext"
            rm -rf build/ai-extract
        fi
        ARCH=$ARCH "$ext/AppRun" "$A" "$OUT"
        ;;
    *)
        ARCH=$ARCH "$tool" "$A" "$OUT"
        ;;
esac
chmod +x "$OUT"
ls -l "$OUT"
