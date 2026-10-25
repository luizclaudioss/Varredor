# Varredor — Identificador de Arquivos e Programas Inativos no macOS

**Varredor** é um aplicativo nativo para macOS desenvolvido em **Swift / SwiftUI** que analisa pastas do usuário (`Downloads`, `Documents`, `Desktop`), pastas de aplicativos (`/Applications` e `~/Applications`) e diretórios personalizados para identificar arquivos e programas (`.app`) que não foram abertos nos últimos 30 dias (ou qualquer período configurável).

---

## Principais Funcionalidades

- **Detecção Precisa de Último Uso (macOS Spotlight + APFS)**:
  - Utiliza os metadados nativos do LaunchServices/Spotlight (`kMDItemLastUsedDate`) para saber exatamente quando um programa (`.app`) ou arquivo foi aberto pela última vez.
  - Identifica programas instalados que **nunca foram abertos** desde a instalação.
  - Calcula o tamanho real completo de pacotes `.app` sem listar milhares de arquivos internos do pacote.
- **Período de Inatividade Ajustável**:
  - Botões rápidos para `15d`, `30d` (padrão), `60d`, `90d`, `180d`, `365d` ou `Todos`, além de ajuste fino por dias.
- **Filtros e Ordenação Inteligentes**:
  - Categorias: *Todos*, *Programas (.app)*, *Documentos*, *Instaladores e Compactados (.dmg, .zip, .pkg)*, *Mídia* e *Outros Arquivos*.
  - Filtro de tamanho mínimo (`> 1 MB`, `> 10 MB`, `> 50 MB`, `> 100 MB`, `> 500 MB`).
  - Ordenação crescente/decrescente por **Tamanho**, **Dias sem uso**, **Data do último acesso** ou **Nome**.
- **Limpeza Segura e Integração com o Finder**:
  - **Mover para a Lixeira**: Envia os arquivos e aplicativos selecionados com segurança para a Lixeira do macOS (permitindo restauração caso necessário) e exibe o espaço total liberado.
  - **Mostrar no Finder**: Localiza qualquer item diretamente no Finder com um clique.
  - **Exportação CSV**: Exporta o relatório completo dos itens inativos.

---

## Como Executar ou Compilar

### 1. Abrir o aplicativo `.app` diretamente
O pacote nativo já está gerado na raiz do projeto:
```bash
open Varredor.app
```
Você também pode arrastar o `Varredor.app` para a sua pasta `/Applications`.

### 2. Recompilar o pacote `.app`
Para recompilar em modo *Release* e regerar o `Varredor.app`:
```bash
./build_app.sh
```

### 3. Executar via Swift Package Manager
```bash
swift run
```
