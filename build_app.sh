#!/usr/bin/env zsh
set -euo pipefail

APP_NAME="Varredor"
BUNDLE_ID="com.luirdi.Varredor"
APP_BUNDLE="${APP_NAME}.app"

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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
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

echo "✅ ${APP_BUNDLE} gerado com sucesso em: $(pwd)/${APP_BUNDLE}"
