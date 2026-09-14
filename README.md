欢迎使用魔兽世界巫妖王之怒（WOTLK）怀旧服模拟器！

本仓库是 [wowsims/wotlk](https://github.com/wowsims/wotlk) 的 Fork，在上游基础上增加了：

- **Windows 原生本地部署**：无需 WSL / Docker / make，一个 PowerShell 脚本完成全部构建；
- **国内网络优化**：所有技能/物品图标等外部图片资源在构建时下载并内嵌到程序里，客户端不再请求 wowhead 的 CDN（wow.zamimg.com），**不开代理也能正常显示**；浏览器语言为中文时，物品/技能链接自动跳转 wowhead 中文版（wowhead.com/…/cn/）；
- **模拟性能优化**：本地版点击 Simulate 后迭代自动分摊到全部 CPU 核心并行计算（上游为单线程），在 14 核机器上实测**提速约 7 倍**（1000 次迭代 2.74s → 0.37s），另含约 8% 的单线程热点优化；每次迭代的随机种子与串行版完全一致，模拟结果同源可比。

原项目的目标是提供一个易于为任意职业/专精构建 DPS 模拟的框架，具有精致的 UI 和准确的结果。各职业社区对自己部分的模拟负责，保证准确性。所有单体模拟运行在同一引擎上，因此还提供了合并的“团队模拟（Raid Sim）”用于测试团队配置。

本项目使用 MIT 协议。若在你自己的项目中使用本软件，请保留指向原项目的用户可见链接。

[上游在线版模拟器入口](https://wowsims.github.io/wotlk "https://wowsims.github.io/wotlk") ｜ [支持上游开发者（Patreon）](https://www.patreon.com/wowsims)

# 下载与使用（Release）

前往本仓库的 [Releases](https://github.com/joexi/wotlk/releases) 页面，下载最新的 Windows 版本（`wowsimwotlk-windows.exe`，或包含说明文件的压缩包）。

使用方法：

1. 下载后（若是压缩包先解压）**双击 `wowsimwotlk-windows.exe`** 即可启动；
2. 浏览器会自动打开 `http://localhost:3333/wotlk/`，选择职业/专精开始模拟；
3. 退出：关闭弹出的控制台窗口，或在窗口内按 `Ctrl+C`。

特性说明：

- 程序为**单文件自包含**版本：界面、数据与全部图标均已内嵌，无需安装任何依赖、无需代理，整个文件（夹）拷贝到任意 Windows 电脑都能直接运行；
- 更换端口：命令行运行 `wowsimwotlk-windows.exe --host=":8080"`；
- 不自动打开浏览器：加参数 `--launch=false`。

上游官方版本（图标走 wowhead CDN，国内网络可能加载缓慢）：[Windows](https://github.com/wowsims/wotlk/releases/latest/download/wowsimwotlk-windows.exe.zip) ｜ [MacOS](https://github.com/wowsims/wotlk/releases/latest/download/wowsimwotlk-amd64-darwin.zip) ｜ [Linux](https://github.com/wowsims/wotlk/releases/latest/download/wowsimwotlk-amd64-linux.zip)

# 本仓库相对上游的改动

| 改动 | 说明 |
| --- | --- |
| [winbuild.ps1](winbuild.ps1) | Windows 原生构建脚本，等价复刻了 makefile 的全部构建链（proto 生成、WASM 编译、UI 打包、服务器编译）。首次运行 `setup` 时若未安装 Go，会自动下载仓库本地版 Go 到 `.tools\go`（无需管理员权限，含国内镜像回退）。最终产物统一输出到 `bin\` 目录，可整体拷贝分发。 |
| 图片资源本地化 | 构建时扫描 UI 源码与物品/技能数据库，把所有引用的 `wow.zamimg.com` 图片（约 3500 个：图标、宝石插槽图、天赋树背景、tooltips.js）下载到 `assets\zamimg`，并在打包产物中把外链地址统一重写为本地路径。如需保留原始外链，构建时加 `-NoCnRedirect` 参数。 |
| wowhead 链接中文化 | 修复了浏览器语言检测（浏览器报告中文为 `zh`，而 wowhead 使用 `cn` 前缀），中文系统下物品/技能链接自动指向 wowhead 中文版。 |
| 模拟迭代多核并行 | 新增 [sim/core/run_concurrent.go](sim/core/run_concurrent.go)：本地服务器的 `/raidSim`、`/raidSimAsync` 接口把迭代按 CPU 核数分块并行执行，再按迭代数加权合并结果（avg/stdev 由各分块矩量精确重构，直方图/极值/施法次数直接合并）。各分块的随机种子接续排列、与串行逐迭代种子一致，因此每次迭代结果与串行版完全相同，仅浮点求和顺序有差异。测试、调试、血量结束型战斗及单核环境（浏览器 wasm）自动回退串行路径，stat weights / bulk sim 维持原有并行方式不受影响。14 核 i5-13600KF 实测：9 人团队、300 秒战斗、1000 次迭代从 2.74s 降至 0.37s（约 7.3 倍）。 |
| 模拟单线程热点优化 | 依据 pprof 剖析做的等价改写（全量职业测试期望 DPS 逐项校验通过，行为不变）：事件队列插入改为从队尾反向扫描；每迭代指标聚合缓存条目指针、跳过全零目标并消除结构体拷贝；`CanCast` 廉价检查前置；APL 比较节点在构造期解析为闭包。单线程迭代耗时降低约 8%，浏览器 wasm 版同样受益。配套修复了上游失效的 `BenchmarkSimulate`（玩家缺 APL rotation 导致空指针），并新增稳态基准、端到端串行/并行基准与并行等价性测试（[sim/concurrent_sim_test.go](sim/concurrent_sim_test.go)）。 |

# 本地开发环境搭建

本项目依赖 Go >= 1.21、protobuf-compiler 及对应 Go 插件、node >= 18.0。

## Windows

原生构建通过 `winbuild.ps1` 完成——无需 WSL、Docker 或 `make`。

前置条件：[Node.js >= 18](https://nodejs.org/) 和 Git。Go 可选——未安装时 setup 会自动下载仓库本地版到 `.tools\go`（无需管理员权限）。

```powershell
git clone https://github.com/joexi/wotlk.git
cd wotlk

# 一次性初始化：检查 Node、安装 Go（如缺失）、protoc-gen-go 和 npm 依赖。
.\winbuild.ps1 setup

# 构建全部内容并在 http://localhost:8080/wotlk/你的专精 托管 UI（等价 make host）。
.\winbuild.ps1 host

# 或构建内嵌 UI 的 bin\wowsimwotlk-windows.exe 并在浏览器中打开。
# bin\ 目录是自包含的——整体拷贝到任意 Windows 电脑即可运行。
.\winbuild.ps1 run
```

其余命令与 makefile 目标一一对应：`proto`、`dist`、`devserver`（等价 `make rundevserver`，在 http://localhost:3333/wotlk 托管 `.\dist`，Go 代码迭代最快）、`exe`、`cnassets`（下载/更新本地图片镜像）、`test`、`clean`。运行 `.\winbuild.ps1 help` 查看详情。

Windows 构建默认会把引用到的 wowhead/zamimg 图标下载到 `assets\zamimg` 并把打包产物中的外链重写为本地路径，使模拟器在无外网/无代理环境下完整渲染。加 `-NoCnRedirect` 参数可保留原始外链。

若 PowerShell 拒绝执行脚本，可改用 `powershell -ExecutionPolicy Bypass -File .\winbuild.ps1 <命令>`。

此外，也可以按 [该指南](https://docs.docker.com/desktop/windows/wsl/ "https://docs.docker.com/desktop/windows/wsl/") 配置 Ubuntu 虚拟机或 Docker，然后按下方 Ubuntu 或 Docker 的说明操作。

## Ubuntu

不要用 apt 安装依赖，其版本都太旧了。使用下面的脚本安装最新版本：

```sh
# 标准 Go 安装脚本
curl -O https://dl.google.com/go/go1.21.1.linux-amd64.tar.gz
sudo rm -rf /usr/local/go 
sudo tar -C /usr/local -xzf go1.21.1.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> $HOME/.bashrc
echo 'export GOPATH=$HOME/go' >> $HOME/.bashrc
echo 'export PATH=$PATH:$GOPATH/bin' >> $HOME/.bashrc
source $HOME/.bashrc

cd wotlk

# 安装 protobuf 编译器及 Go 插件
sudo apt update && sudo apt upgrade
sudo apt install protobuf-compiler
go get -u -v google.golang.org/protobuf
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest

# 安装 node
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash
nvm install 19.8.0

# 安装 npm 依赖
npm install
```

## Docker

也可以安装 Docker，工作流大致如下：

```sh
git clone https://github.com/joexi/wotlk.git
cd wotlk

# 构建 docker 镜像并安装 npm 依赖（只需运行一次）。
docker build --tag wowsims-wotlk .
docker run --rm -v $(pwd):/wotlk wowsims-wotlk npm install

# 之后即可运行“命令”一节中的各命令，前面加上 "docker run --rm -it -p 8080:8080 -v $(pwd):/wotlk wowsims-wotlk"。
# 为方便起见，可以设置环境变量：
WOTLK_CMD="docker run --rm -it -p 8080:8080 -v $(pwd):/wotlk wowsims-wotlk"

# ……修改模拟器代码……

# 运行测试
$(echo $WOTLK_CMD) make test

# ……修改 UI 代码……

# 托管本地站点
$(echo $WOTLK_CMD) make host
```

## Mac OS

* Docker 在 OS X 上同样可用，理论上按 Docker 方式操作即可；
* 也可以参照上面 Ubuntu 的步骤原生运行，注意以下差异：
  * 若 Go 安装包与你的系统架构不兼容，需要到 `https://go.dev/doc/install` 手动安装对应版本；
  * OS X 使用 Homebrew 而非 apt，安装 protobuf 编译器需运行 `brew install protobuf-c`（注意包名与 apt 略有不同），可能需要先更新/升级 brew；
  * Node 安装脚本没有为 OS X 提供预编译二进制，但它会自动编译。运行 `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash` 时请做好 CPU 起飞的准备。

# 命令（makefile）

Linux / macOS / Docker 环境使用 makefile 构建（Windows 请使用上文的 `winbuild.ps1`）。开发中常用的命令如下：

```sh
# 安装 pre-commit 钩子自动格式化 go 代码（如果你的 IDE 不支持的话）。手动格式化可运行 make fmt。
# 同时安装 `air` 用于开发服务器自动重载
make setup

# 运行所有测试。目前只有后端模拟器有测试。
make test

# 更新测试的预期结果。增删测试后需要运行；代码改动导致测试结果变化时也需要运行。
make update-tests

# 在 http://localhost:8080 托管本地版 UI。
# 浏览器访问 http://localhost:8080/wotlk/你的专精，“你的专精”是 ui/ 下你的代码目录名。
# 启动前会重新编译整个客户端（make dist/wotlk）
make host

# 带文件监听：Go 或 TS 变更时自动重启、重编译：
WATCH=1 make host

# 删除所有生成文件（.pb.go、proto 生成的 .ts、dist/）
make clean

# 只为指定专精重编译 ts（例如 make host_elemental_shaman）
make host_$spec

# 重新编译 `wowsimwotlk` 服务器二进制并运行，在 http://localhost:3333/wotlk 托管 /dist 目录。
# 这是迭代 Go 核心模拟代码最快的方式，不用等客户端重新构建。
# 要重建某个专精的客户端，运行 'make $spec' 后刷新浏览器即可。
make rundevserver

# 带文件监听：Go 或 TS 变更时自动重启、重编译：
WATCH=1 make rundevserver

# 生成 'wowsimwotlk' 二进制：可原生托管 UI 并运行模拟（不使用 wasm）。
# 先构建 UI 再将其编译进二进制，这样可以以服务器方式托管模拟器，而不是客户端 wasm。
# 实现方式：先 make dist/wotlk，把产物拷贝到 binary_dist/wotlk，编译时将该目录内容全部打进二进制。
make wowsimwotlk

# --usefs 参数：不使用二进制内嵌的客户端，改为托管 /dist 目录中的代码。
# --wasm 参数：客户端使用 wasm 模拟器。
# 服务器会禁用所有缓存，刷新即可看到 dist/ 中的文件变更。客户端仍会调用服务器运行模拟，方便快速迭代客户端改动。
# make dist/wotlk && ./wowsimwotlk --usefs 会重建整个客户端并托管（需要先运行过 `make devserver` 构建出 wowsimwotlk 二进制）。
./wowsimwotlk --usefs

# 生成物品代码。只有修改了物品生成器时才需要运行。
make items
```

# 添加新的职业/专精模拟

想为你的职业/专精做一个新模拟？基本步骤如下：
 - [创建模拟器与 UI 之间的 proto 接口](#创建模拟器与-ui-之间的-proto-接口)
 - [实现 UI](#实现-ui)
 - [实现模拟器](#实现模拟器)
 - [上线站点](#上线站点)

## 创建模拟器与 UI 之间的 proto 接口

本项目使用 [Google Protocol Buffers](https://developers.google.com/protocol-buffers/docs/gotutorial "https://developers.google.com/protocol-buffers/docs/gotutorial") 在模拟器与 UI 之间传递数据。简单说：在 .proto 文件中描述数据结构，工具可以生成任意语言的代码，避免在 Go 和 TypeScript 两个世界重复编写相同代码，同时保留类型安全。

新增一个模拟需要以下改动：
  - 在 proto/common.proto 的 `Spec` 枚举中添加新值。__注意：这个枚举值的名字不只是名字，它会被模板系统使用。本指南在其他地方用 `$SPEC` 指代它。__
  - 若 'proto/你的职业.proto' 不存在则新建，添加包含运行模拟所需的职业/专精特有信息的数据 message。
  - 更新 `proto/api.proto` 中的 `PlayerOptions.spec` 字段，把你的新 message 加进去。

完成后运行 `make`，会在 `sim/core/proto` 和 `ui/core/proto` 分别生成 .go 和 .ts 代码。如果不熟悉 proto，可以快速浏览生成的代码了解发生了什么。

## 实现 UI

UI 和模拟器实现顺序不限，但一般建议先做 UI，方便调试。UI 已高度泛化，借助模板系统不需要太多工作就能搭出完整的模拟界面。使用方法：
  - 修改 `ui/core/proto_utils/utils.ts`，为你的 `$SPEC` 添加样板代码（如果还没有）。
  - 创建目录 `ui/$SPEC`。例如 Spec 枚举值叫 `elemental_shaman`，就创建 `ui/elemental_shaman`。
  - 从其他专精的 UI 代码复制粘贴。
  - 修改所有文件适配你的专精；大部分设置一目了然，遇到复杂的尽管提问！
  - 最后在 `makefile` 中为新站点添加规则，照抄已有站点规则并改 `$SPEC` 名即可。

不需要写 .html，它会根据 `ui/index_template.html` 和 `$SPEC` 名自动生成。

准备好后运行 `make host`，访问 `http://localhost:8080/wotlk/$SPEC` 查看效果。

## 实现模拟器

大部分魔法发生在这一步。先了解一下模拟器代码的几个要点：
  - `sim/wasm/main.go` 真正的 main 函数所在，用于 UI 使用的 [.wasm 二进制](https://webassembly.org/ "https://webassembly.org/")。基本不需要动，知道有这个东西即可。
  - `sim/core/api.go` 一切从这里开始。实现了 `proto/api.proto` 中定义的请求/响应消息。
  - `sim/core/sim.go` 总调度。主事件循环在 `Simulation.RunOnce`。
  - `sim/core/agent.go` Agent 可以理解为“玩家”，即操控游戏的人，是你要实现的接口。
  - `sim/core/character.go` Character 持有所有 WoW 角色共有的属性/冷却/装备等。每个 Agent 控制一个 Character。

通读 core 代码和其他职业/专精的例子，感受一下需要做什么。希望 `sim/core` 已经包含你所需的，但多数职业至少有一个独特机制，可能也需要动 `core`。

最后把你的新模拟加进 `sim/register_all.go` 的 `RegisterAll()`。

别忘了写单元测试！同样参考现有测试。准备好后用 `make test` 运行。

# 上线站点

一切就绪准备发布时，修改 `ui/core/launched_sims.ts` 和 `ui/index.html` 加入新的 spec 值。这样新模拟会出现在下拉菜单中，所有人都能从现有模拟入口找到它，同时也会移除“开发中”的 UI 警告。快去告诉大家你的新模拟吧！

# 把你的专精加入团队模拟

单体模拟准备好上线之前不要碰团队模拟（Raid Sim）；团队模拟中的任何内容都是公开可见的。加入方法：
 - 在 `ui/raid/tsconfig.json` 中添加对单体模拟的引用。__千万别忘了这一步__，否则 TypeScript 会悄悄做出非常糟糕的事情。
 - 在 `ui/raid/index.scss` 中导入单体模拟的 css 文件。
 - 更新 `ui/raid/presets.ts`：在 `specSimFactories` 变量中加入构造工厂，在 `playerPresets` 变量中为新玩家添加配置。

# 部署

得益于 `.github/workflows/deploy.yml` 中定义的工作流，推送到 `master` 会自动构建并部署新站点，无需任何手动操作。坐和放宽，欣赏你的新模拟吧！
