#!/usr/bin/env zsh
set -euo pipefail

APP_NAME="Varredor"
BUNDLE_ID="com.luirdi.Varredor"
APP_BUNDLE="${APP_NAME}.app"

if [ ! -f "AppIcon.icns" ]; then
    echo "🎨 Gerando ícone da vassoura (AppIcon.icns)..."
    swift generate_icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

echo "🔨 Compilando ${APP_NAME} (Release)..."
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)/${APP_NAME}

echo "🔄 Encerrando instância anterior (se aberta)..."
killall "${APP_NAME}" 2>/dev/null || true

echo "📦 Empacotando ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.0</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Arquivo Compactado</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>zip</string>
                <string>rar</string>
                <string>7z</string>
                <string>iso</string>
                <string>dmg</string>
                <string>cdr</string>
                <string>img</string>
                <string>tar</string>
                <string>tgz</string>
                <string>gz</string>
                <string>tbz</string>
                <string>tbz2</string>
                <string>bz2</string>
                <string>txz</string>
                <string>xz</string>
                <string>xar</string>
                <string>pkg</string>
                <string>cab</string>
                <string>cpio</string>
                <string>deb</string>
                <string>rpm</string>
                <string>cbz</string>
                <string>cbr</string>
                <string>cb7</string>
            </array>
        </dict>
    </array>
    <key>NSDesktopFolderUsageDescription</key>
    <string>O Varredor precisa acessar a pasta Mesa para identificar arquivos inativos.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>O Varredor precisa acessar a pasta Documentos para identificar arquivos inativos.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>O Varredor precisa acessar a pasta Downloads para identificar arquivos inativos.</string>
    <key>NSAppManagementUsageDescription</key>
    <string>O Varredor precisa de permissão para desinstalar aplicativos inativos e limpar todos os seus arquivos de preferências, caches e containers.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>O Varredor utiliza eventos do sistema e do Finder para remover aplicativos protegidos por permissões de administrador.</string>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>O Varredor solicita privilégios de administrador para desinstalar aplicativos protegidos e limpar seus registros do sistema.</string>
</dict>
</plist>
EOF

echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

codesign --force --deep --sign - "${APP_BUNDLE}"
touch "${APP_BUNDLE}"

echo "✅ ${APP_BUNDLE} gerado com sucesso com ícone em: $(pwd)/${APP_BUNDLE}"
