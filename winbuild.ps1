<#
.SYNOPSIS
    Native Windows build script for the WoW WOTLK Classic simulator.
    PowerShell equivalent of the makefile targets, so no WSL/Docker/make is needed.

.DESCRIPTION
    Usage: .\winbuild.ps1 <command>

    Commands:
      setup      Install/verify the toolchain (Go, protoc-gen-go, node modules).
                 Downloads a repo-local Go into .tools\go if Go is not installed
                 (no admin rights required).
      proto      Generate Go + TypeScript protobuf code.          (make proto)
      dist       Full client build into dist\wotlk.               (make dist/wotlk)
      host       Build client + host it on http://localhost:8080. (make host)
      devserver  Build server exe + run it serving .\dist on
                 http://localhost:3333/wotlk. Fastest way to
                 iterate on Go sim code.                          (make rundevserver)
      exe        Build bin\wowsimwotlk-windows.exe with the client
                 embedded. The bin\ folder is self-contained -
                 copy it to any Windows machine and run.          (make wowsimwotlk-windows.exe)
      run        Build exe + run it (opens the sim in a browser).
      cnassets   Download all wowhead/zamimg images referenced by
                 the UI into assets\zamimg so built clients never
                 need to reach blocked CDNs (China-friendly).
      test       Run the Go test suite.                           (make test)
      clean      Delete all generated files.                      (make clean)

    By default (dist/host/exe/run), external image URLs in the built client
    are rewritten to the local assets\zamimg copies. Pass -NoCnRedirect to
    keep the original wow.zamimg.com URLs instead.

    If PowerShell blocks the script, run it as:
      powershell -ExecutionPolicy Bypass -File .\winbuild.ps1 <command>
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'proto', 'dist', 'host', 'devserver', 'exe', 'run', 'cnassets', 'test', 'clean', 'help')]
    [string]$Command = 'help',

    # Port for the 'host' command's static file server.
    [int]$Port = 8080,

    # Version string stamped into the exe ("development" skips the update check).
    [string]$Version = 'development',

    # Keep original wow.zamimg.com image URLs instead of redirecting to the
    # local assets\zamimg mirror.
    [switch]$NoCnRedirect
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = $PSScriptRoot
$OutDir = Join-Path $RepoRoot 'dist\wotlk'
$ToolsDir = Join-Path $RepoRoot '.tools'
# Final build artifacts land here; the whole folder is distributable as-is.
$BinDir = Join-Path $RepoRoot 'bin'
$ExePath = Join-Path $BinDir 'wowsimwotlk-windows.exe'

# Local mirror of wowhead's image CDN (wow.zamimg.com), so clients behind
# restrictive networks (e.g. mainland China without a proxy) still get icons.
$CnAssetsDir = Join-Path $RepoRoot 'assets\zamimg'
$ZamimgUrlPrefix = 'https://wow.zamimg.com/'
# Absolute path under the site root; pages are always served at /wotlk/.
$ZamimgLocalPrefix = '/wotlk/assets/zamimg/'

# Keep in sync with go.mod: needs go >= 1.23; protoc-gen-go matches the
# google.golang.org/protobuf version pinned in go.mod.
$GoVersion = '1.23.4'
$ProtocGenGoVersion = 'v1.36.6'

# Keep in sync with HTML_INDECIES in the makefile.
$Specs = @(
    'balance_druid', 'feral_druid', 'feral_tank_druid', 'restoration_druid',
    'elemental_shaman', 'enhancement_shaman', 'restoration_shaman',
    'hunter', 'mage', 'rogue',
    'holy_paladin', 'protection_paladin', 'retribution_paladin',
    'healing_priest', 'shadow_priest', 'smite_priest',
    'warlock', 'warrior', 'protection_warrior',
    'deathknight', 'tank_deathknight',
    'raid', 'detailed_results'
)

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step([string]$Message) { Write-Host ">> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }

function Assert-LastExit([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $What (exit code $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
}

# npm/npx resolve to .ps1 shims; call the .cmd shims so exit codes are reliable.
function Invoke-Npx {
    & npx.cmd --no-install @args
}

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------

function Use-LocalGo {
    # Make a previously downloaded repo-local Go available on PATH.
    $localGoBin = Join-Path $ToolsDir 'go\bin'
    if (Test-Path (Join-Path $localGoBin 'go.exe')) {
        if ($env:Path -notlike "*$localGoBin*") {
            $env:Path = "$localGoBin;$env:Path"
        }
        return $true
    }
    return $false
}

function Test-Go {
    if (Get-Command go -ErrorAction SilentlyContinue) { return $true }
    return (Use-LocalGo)
}

function Install-Go {
    Write-Step "Go not found. Downloading Go $GoVersion to $ToolsDir\go (no admin needed)..."
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    $zipPath = Join-Path $ToolsDir "go$GoVersion.windows-amd64.zip"
    $urls = @(
        "https://dl.google.com/go/go$GoVersion.windows-amd64.zip",
        "https://golang.google.cn/dl/go$GoVersion.windows-amd64.zip"  # mirror for mainland China
    )
    $downloaded = $false
    foreach ($url in $urls) {
        try {
            Write-Host "   trying $url"
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
            $downloaded = $true
            break
        } catch {
            Write-Host "   download failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (-not $downloaded) {
        Write-Host "Could not download Go. Install it manually from https://go.dev/dl/ and re-run setup." -ForegroundColor Red
        exit 1
    }
    Write-Step 'Extracting Go...'
    Expand-Archive -Path $zipPath -DestinationPath $ToolsDir -Force
    Remove-Item $zipPath
    if (-not (Use-LocalGo)) {
        Write-Host 'Go extraction failed.' -ForegroundColor Red
        exit 1
    }
}

function Ensure-Go {
    if (-not (Test-Go)) {
        Write-Host "Go is not installed. Run '.\winbuild.ps1 setup' first." -ForegroundColor Red
        exit 1
    }
}

function Get-ProtocGenGo {
    $gopath = (& go env GOPATH).Trim()
    return (Join-Path $gopath 'bin\protoc-gen-go.exe')
}

function Ensure-ProtocGenGo {
    $plugin = Get-ProtocGenGo
    if (-not (Test-Path $plugin)) {
        Write-Step "Installing protoc-gen-go $ProtocGenGoVersion..."
        & go install "google.golang.org/protobuf/cmd/protoc-gen-go@$ProtocGenGoVersion"
        Assert-LastExit 'go install protoc-gen-go'
    }
    return $plugin
}

function Ensure-NodeModules {
    if (-not (Test-Path (Join-Path $RepoRoot 'node_modules'))) {
        Write-Step 'Installing npm dependencies (npm ci)...'
        & npm.cmd ci --no-audit --no-fund
        Assert-LastExit 'npm ci'
    }
}

function Invoke-Setup {
    Write-Step 'Checking Node.js...'
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Host 'Node.js >= 18 is required. Install it from https://nodejs.org/ and re-run setup.' -ForegroundColor Red
        exit 1
    }
    $nodeMajor = [int]((& node --version).TrimStart('v').Split('.')[0])
    if ($nodeMajor -lt 18) {
        Write-Host "Node.js >= 18 is required (found $(& node --version)). Please upgrade." -ForegroundColor Red
        exit 1
    }
    Write-Host "   node $(& node --version)"

    if (-not (Test-Go)) { Install-Go }
    Write-Host "   $(& go version)"

    Ensure-NodeModules

    Write-Step 'Downloading Go module dependencies...'
    Push-Location $RepoRoot
    try {
        & go mod download
        if ($LASTEXITCODE -ne 0) {
            # proxy.golang.org is unreachable from some networks (e.g. mainland
            # China); retry once with the goproxy.cn mirror.
            Write-Host '   go mod download failed; retrying with GOPROXY=https://goproxy.cn' -ForegroundColor Yellow
            & go env -w 'GOPROXY=https://goproxy.cn,direct'
            & go mod download
            Assert-LastExit 'go mod download'
        }
    } finally {
        Pop-Location
    }

    Ensure-ProtocGenGo | Out-Null

    Write-Ok 'Setup complete. Next: .\winbuild.ps1 host   (or: run / devserver)'
}

# ---------------------------------------------------------------------------
# Code generation
# ---------------------------------------------------------------------------

function Invoke-Proto {
    Ensure-Go
    Ensure-NodeModules
    $plugin = Ensure-ProtocGenGo
    Push-Location $RepoRoot
    try {
        Write-Step 'Generating Go protobuf code...'
        $protoFiles = Get-ChildItem 'proto' -Filter '*.proto' | ForEach-Object { "proto/$($_.Name)" }
        Invoke-Npx protoc "--plugin=protoc-gen-go=$plugin" '-I=./proto' '--go_out=./sim/core' @protoFiles
        Assert-LastExit 'protoc --go_out'

        Write-Step 'Generating TypeScript protobuf code...'
        New-Item -ItemType Directory -Force -Path 'ui\core\proto' | Out-Null
        Invoke-Npx protoc '--ts_opt' 'generate_dependencies' '--ts_out' 'ui/core/proto' '--proto_path' 'proto' 'proto/api.proto'
        Assert-LastExit 'protoc --ts_out api.proto'
        Invoke-Npx protoc '--ts_out' 'ui/core/proto' '--proto_path' 'proto' 'proto/test.proto'
        Assert-LastExit 'protoc --ts_out test.proto'
        Invoke-Npx protoc '--ts_out' 'ui/core/proto' '--proto_path' 'proto' 'proto/ui.proto'
        Assert-LastExit 'protoc --ts_out ui.proto'
    } finally {
        Pop-Location
    }
}

function New-CoreIndexTs {
    # Equivalent of the makefile's ui/core/index.ts rule: import every .ts file.
    Write-Step 'Generating ui/core/index.ts...'
    $coreDir = Join-Path $RepoRoot 'ui\core'
    $imports = Get-ChildItem $coreDir -Recurse -File |
        Where-Object { $_.Extension -eq '.ts' } |
        ForEach-Object {
            $rel = $_.FullName.Substring($coreDir.Length + 1) -replace '\\', '/'
            $rel = $rel -replace '\.ts$', ''
            if ($rel -ne 'index') { "import `"./$rel`";" }
        } | Sort-Object
    [System.IO.File]::WriteAllLines((Join-Path $coreDir 'index.ts'), $imports, $Utf8NoBom)
}

function New-HtmlIndices {
    Write-Step 'Generating per-spec index.html files...'
    $template = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'ui\index_template.html'))
    $textInfo = (Get-Culture).TextInfo
    foreach ($spec in $Specs) {
        $title = $textInfo.ToTitleCase(($spec -replace '_', ' '))
        $html = $template -replace '@@TITLE@@', "WOTLK $title Simulator" -replace '@@SPEC@@', $spec
        $specDir = Join-Path $RepoRoot "ui\$spec"
        if (Test-Path $specDir) {
            [System.IO.File]::WriteAllText((Join-Path $specDir 'index.html'), $html, $Utf8NoBom)
        }
    }
}

# ---------------------------------------------------------------------------
# Local mirror of external images (China-friendly builds)
# ---------------------------------------------------------------------------

function Get-CnAssetPaths {
    # Collect every wow.zamimg.com path the UI can reference:
    # 1) literal URLs in ui sources, 2) icon names in the item/spell databases
    # (used by ActionId.makeIconUrl as images/wow/icons/large/<icon>.jpg).
    $paths = New-Object 'System.Collections.Generic.HashSet[string]'

    $rx = [regex]'https://wow\.zamimg\.com/([A-Za-z0-9_\-./]+)'
    $srcFiles = Get-ChildItem (Join-Path $RepoRoot 'ui') -Recurse -File |
        Where-Object { $_.Extension -in '.ts', '.tsx', '.json', '.html' }
    foreach ($f in $srcFiles) {
        foreach ($m in $rx.Matches([System.IO.File]::ReadAllText($f.FullName))) {
            $rel = $m.Groups[1].Value
            # Skip bare directory prefixes captured from template literals like
            # `https://wow.zamimg.com/images/wow/icons/large/${iconLabel}.jpg`.
            if (-not $rel.EndsWith('/')) { [void]$paths.Add($rel) }
        }
    }

    $extractJs = @'
const fs = require('fs');
const s = new Set();
const add = v => { if (typeof v === 'string' && v) s.add(v); };
for (const p of ['assets/database/db.json', 'assets/database/leftover_db.json']) {
    let db;
    try { db = JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { continue; }
    for (const k of ['items', 'gems', 'enchants', 'itemIcons', 'spellIcons']) {
        (db[k] || []).forEach(i => i && add(i.icon));
    }
}
console.log([...s].join('\n'));
'@
    $tmpJs = Join-Path ([System.IO.Path]::GetTempPath()) "wotlk_extract_icons_$PID.js"
    [System.IO.File]::WriteAllText($tmpJs, $extractJs, $Utf8NoBom)
    try {
        Push-Location $RepoRoot
        $icons = & node.exe $tmpJs
        Assert-LastExit 'extract icon names from database'
        Pop-Location
    } finally {
        Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue
    }
    foreach ($icon in $icons) {
        if ($icon) { [void]$paths.Add("images/wow/icons/large/$icon.jpg") }
    }
    return $paths
}

function Get-CnAssets {
    Write-Step 'Checking local mirror of external images (assets\zamimg)...'
    $paths = Get-CnAssetPaths
    $missing = @()
    foreach ($rel in $paths) {
        if (-not (Test-Path (Join-Path $CnAssetsDir ($rel -replace '/', '\')))) { $missing += $rel }
    }
    Write-Host "   $($paths.Count) referenced files, $($missing.Count) to download"
    if ($missing.Count -gt 0) {
        Add-Type -AssemblyName System.Net.Http
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $ok = 0
        $failed = @()
        try {
            $batchSize = 16
            for ($i = 0; $i -lt $missing.Count; $i += $batchSize) {
                $end = [Math]::Min($i + $batchSize, $missing.Count) - 1
                # Use a typed list; a foreach-collected array of pairs would get
                # flattened by PowerShell when the batch has exactly one entry.
                $tasks = New-Object 'System.Collections.Generic.List[object]'
                foreach ($rel in $missing[$i..$end]) {
                    $tasks.Add(@($rel, $client.GetByteArrayAsync("$ZamimgUrlPrefix$rel")))
                }
                foreach ($t in $tasks) {
                    try {
                        $bytes = $t[1].GetAwaiter().GetResult()
                        $dest = Join-Path $CnAssetsDir ($t[0] -replace '/', '\')
                        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
                        [System.IO.File]::WriteAllBytes($dest, $bytes)
                        $ok++
                    } catch {
                        $failed += $t[0]
                    }
                }
                if ((($i + $batchSize) % 320) -eq 0) { Write-Host "   downloaded $ok / $($missing.Count)..." }
            }
        } finally {
            $client.Dispose()
        }
        Write-Host "   downloaded $ok files"
        if ($failed.Count -gt 0) {
            Write-Host "   WARNING: $($failed.Count) downloads failed (first few):" -ForegroundColor Yellow
            $failed | Select-Object -First 5 | ForEach-Object { Write-Host "     $_" -ForegroundColor Yellow }
        }
    }

    # tooltips.js itself builds zamimg image URLs at runtime; point those at the
    # local mirror too. (The data it fetches from nether.wowhead.com on hover is
    # left alone - tooltips just degrade gracefully if that host is unreachable.)
    $tt = Join-Path $CnAssetsDir 'js\tooltips.js'
    if (Test-Path $tt) {
        $c = [System.IO.File]::ReadAllText($tt)
        if ($c.Contains('wow.zamimg.com/')) {
            $c = $c.Replace($ZamimgUrlPrefix, $ZamimgLocalPrefix).Replace('//wow.zamimg.com/', $ZamimgLocalPrefix)
            [System.IO.File]::WriteAllText($tt, $c, $Utf8NoBom)
        }
    }
}

function Invoke-CnRewrite {
    # Rewrite all wow.zamimg.com references in the built client to the local
    # mirror. Done on the build output so the source stays in sync with upstream.
    Write-Step 'Redirecting external image URLs to the local mirror...'
    $targets = @()
    $bundleDir = Join-Path $OutDir 'bundle'
    if (Test-Path $bundleDir) {
        $targets += Get-ChildItem $bundleDir -File | Where-Object { $_.Name -match '\.js$' }
    }
    $targets += Get-ChildItem $OutDir -Recurse -File | Where-Object { $_.Name -eq 'index.html' }
    $n = 0
    foreach ($f in $targets) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        if ($text.Contains($ZamimgUrlPrefix)) {
            [System.IO.File]::WriteAllText($f.FullName, $text.Replace($ZamimgUrlPrefix, $ZamimgLocalPrefix), $Utf8NoBom)
            $n++
        }
    }
    Write-Host "   rewrote $n files"
}

# ---------------------------------------------------------------------------
# Client build (equivalent of make dist/wotlk)
# ---------------------------------------------------------------------------

function Build-Wasm {
    Ensure-Go
    Write-Step 'Compiling WebAssembly sim (this can take a minute)...'
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Push-Location $RepoRoot
    $env:GOOS = 'js'
    $env:GOARCH = 'wasm'
    try {
        & go build -o "$OutDir\lib.wasm" ./sim/wasm/
        Assert-LastExit 'wasm compile'
    } finally {
        Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue
        Pop-Location
    }
    Write-Ok 'WASM compile successful.'
}

function Copy-Assets {
    Write-Step 'Copying assets...'
    # /E copy subdirs, /XD skip the large db_inputs dir (parity with makefile).
    & robocopy (Join-Path $RepoRoot 'assets') (Join-Path $OutDir 'assets') /E /XD db_inputs /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Write-Host "FAILED: asset copy (robocopy exit $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
    $global:LASTEXITCODE = 0
}

function Build-Workers {
    Ensure-Go
    Write-Step 'Building web workers...'
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $goroot = (& go env GOROOT).Trim()
    # wasm_exec.js moved from misc/wasm to lib/wasm in Go 1.24.
    $wasmExec = Join-Path $goroot 'misc\wasm\wasm_exec.js'
    if (-not (Test-Path $wasmExec)) { $wasmExec = Join-Path $goroot 'lib\wasm\wasm_exec.js' }
    if (-not (Test-Path $wasmExec)) {
        Write-Host "Could not find wasm_exec.js under $goroot" -ForegroundColor Red
        exit 1
    }
    $simWorker = [System.IO.File]::ReadAllText($wasmExec) + "`n" +
        [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'ui\worker\sim_worker.js'))
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'sim_worker.js'), $simWorker, $Utf8NoBom)
    Copy-Item (Join-Path $RepoRoot 'ui\worker\net_worker.js') $OutDir -Force
}

function Invoke-Dist {
    Ensure-NodeModules
    Invoke-Proto
    New-CoreIndexTs
    New-HtmlIndices
    if (-not $NoCnRedirect) { Get-CnAssets }
    Build-Wasm
    Copy-Assets
    Build-Workers
    Push-Location $RepoRoot
    try {
        Write-Step 'Type-checking TypeScript (tsc --noEmit)...'
        Invoke-Npx tsc --noEmit
        Assert-LastExit 'tsc'
        Write-Step 'Bundling UI (vite build, this is the slow part)...'
        Invoke-Npx vite build
        Assert-LastExit 'vite build'
    } finally {
        Pop-Location
    }
    if (-not $NoCnRedirect) { Invoke-CnRewrite }
    Write-Ok "Client built into $OutDir"
}

# ---------------------------------------------------------------------------
# Server binary (equivalent of make wowsimwotlk / wowsimwotlk-windows.exe)
# ---------------------------------------------------------------------------

function New-BinaryDistStub {
    # Minimal binary_dist so the go:embed in sim/web compiles (used by tests
    # and the devserver, which serve files from .\dist instead).
    $bd = Join-Path $RepoRoot 'binary_dist'
    New-Item -ItemType Directory -Force -Path (Join-Path $bd 'wotlk') | Out-Null
    $embedded = Join-Path $bd 'wotlk\embedded'
    if (-not (Test-Path $embedded)) { New-Item -ItemType File -Path $embedded | Out-Null }
    Copy-Item (Join-Path $RepoRoot 'sim\web\dist.go.tmpl') (Join-Path $bd 'dist.go') -Force
}

function New-BinaryDist {
    # Full copy of the built client for embedding into the exe.
    Write-Step 'Preparing binary_dist for embedding...'
    $bd = Join-Path $RepoRoot 'binary_dist'
    if (Test-Path $bd) { Remove-Item $bd -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $bd | Out-Null
    Copy-Item $OutDir (Join-Path $bd 'wotlk') -Recurse
    # The embedded server runs sims natively, so the wasm + raw db files are not needed.
    Remove-Item (Join-Path $bd 'wotlk\lib.wasm') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bd 'wotlk\assets\db_inputs') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bd 'wotlk\assets\database\db.bin') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bd 'wotlk\assets\database\leftover_db.bin') -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $RepoRoot 'sim\web\dist.go.tmpl') (Join-Path $bd 'dist.go') -Force
}

function Build-Exe {
    Ensure-Go
    Write-Step 'Compiling bin\wowsimwotlk-windows.exe...'
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    # go build only picks up the .syso icon when invoked without naming .go
    # files, so build from inside sim/web (same trick as the makefile).
    $syso = Join-Path $RepoRoot 'sim\web\icon-windows_amd64.syso'
    Copy-Item (Join-Path $RepoRoot 'assets\favicon_io\icon-windows_amd64.syso') $syso -Force
    Push-Location (Join-Path $RepoRoot 'sim\web')
    $env:GOAMD64 = 'v2'
    try {
        & go build -o $ExePath -ldflags "-X 'main.Version=$Version' -s -w"
        Assert-LastExit 'server compile'
    } finally {
        Remove-Item Env:GOAMD64 -ErrorAction SilentlyContinue
        Pop-Location
        Remove-Item $syso -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "Built $ExePath"
}

function Write-BinReadme {
    $readme = @'
WoW WOTLK Classic Simulator - Windows 本地版
=============================================

使用方法：双击 wowsimwotlk-windows.exe 即可启动，浏览器会自动打开
http://localhost:3333/wotlk/ ，选择职业/专精开始模拟。

- 本程序为单文件自包含版本，界面、数据与全部技能/物品图标已内嵌，
  无需安装任何依赖、无需代理即可正常显示，整个文件夹拷贝到任意
  Windows 电脑都能直接运行。
- 退出：关闭弹出的控制台窗口，或在窗口内按 Ctrl+C。
- 更换端口：命令行运行  wowsimwotlk-windows.exe --host=":8080"
- 不自动打开浏览器：加参数  --launch=false

How to use: double-click wowsimwotlk-windows.exe; your browser opens
http://localhost:3333/wotlk/ automatically. The exe is fully
self-contained (UI and data embedded) - no dependencies required.
'@
    [System.IO.File]::WriteAllText((Join-Path $BinDir 'README.txt'), $readme, $Utf8NoBom)
}

function Invoke-Exe {
    Invoke-Dist
    New-BinaryDist
    Build-Exe
    Write-BinReadme
    Write-Ok "The bin\ folder is self-contained - copy it to any Windows machine to run the sim."
}

function Invoke-DevServer {
    Ensure-Go
    if (-not (Test-Path (Join-Path $OutDir 'bundle'))) {
        Write-Step 'No built client found; building it first...'
        Invoke-Dist
    }
    New-BinaryDistStub
    Build-Exe
    Write-Step 'Starting dev server on http://localhost:3333/wotlk (serving .\dist, Ctrl+C to stop)...'
    Push-Location $RepoRoot
    try {
        & $ExePath --usefs=true --launch=false --host=":3333"
    } finally {
        Pop-Location
    }
}

function Invoke-Run {
    Invoke-Exe
    Write-Step 'Launching the simulator (Ctrl+C to stop)...'
    Push-Location $RepoRoot
    try {
        & $ExePath
    } finally {
        Pop-Location
    }
}

function Invoke-Host2 {
    Ensure-NodeModules
    Invoke-Dist
    Write-Step "Hosting http://localhost:$Port/wotlk/ (Ctrl+C to stop)..."
    Push-Location $RepoRoot
    try {
        # Serve dist/ (one level above dist/wotlk) so URLs match github pages.
        Invoke-Npx http-server (Join-Path $RepoRoot 'dist') -p $Port
    } finally {
        Pop-Location
    }
}

function Invoke-Test {
    Ensure-Go
    Invoke-Proto
    New-BinaryDistStub
    Write-Step 'Running Go tests...'
    Push-Location $RepoRoot
    try {
        & go test --tags=with_db ./sim/...
        Assert-LastExit 'go test'
    } finally {
        Pop-Location
    }
    Write-Ok 'All tests passed.'
}

function Invoke-Clean {
    Write-Step 'Cleaning generated files...'
    Push-Location $RepoRoot
    try {
        Remove-Item 'ui\core\proto\*.ts' -Force -ErrorAction SilentlyContinue
        Remove-Item 'sim\core\proto\*.pb.go' -Force -ErrorAction SilentlyContinue
        Remove-Item 'wowsimwotlk', 'wowsimwotlk-windows.exe', 'wowsimcli-windows.exe' -Force -ErrorAction SilentlyContinue
        Remove-Item 'dist', 'binary_dist', 'bin' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item 'ui\core\index.ts' -Force -ErrorAction SilentlyContinue
        foreach ($spec in $Specs) {
            Remove-Item "ui\$spec\index.html" -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem -Recurse -Filter '*.results.tmp' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    } finally {
        Pop-Location
    }
    Write-Ok 'Clean complete. (node_modules and .tools were kept; delete them manually if needed.)'
}

# ---------------------------------------------------------------------------

switch ($Command) {
    'setup' { Invoke-Setup }
    'proto' { Invoke-Proto; Write-Ok 'Protobuf code generated.' }
    'dist' { Invoke-Dist }
    'host' { Invoke-Host2 }
    'devserver' { Invoke-DevServer }
    'exe' { Invoke-Exe }
    'run' { Invoke-Run }
    'cnassets' { Get-CnAssets; Write-Ok 'Local image mirror is up to date.' }
    'test' { Invoke-Test }
    'clean' { Invoke-Clean }
    default {
        Get-Help $PSCommandPath -Detailed
    }
}
