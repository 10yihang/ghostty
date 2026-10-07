# Ghostty AI 界面方案研究

调研日期：2026-10-06。范围：官方 Pi UI、RPC 与 TUI 接入边界，以及图形聊天和原生 Markdown 组件。只读检查和研究笔记；本轮没有安装依赖或改动业务实现。

## 当前结论

继续使用 Pi 作为 Agent 和现有配置来源是合理的。需要重做的是对话、运行状态与终端上下文呈现。**不建议把旧 `@earendil-works/pi-web-ui` 作为“当前官方维护、可直接嵌入”的成熟方案。** 它仍在 npm，但官方已移除源码；原来的组件也需要本地 Pi RPC 适配。

**图形面板的优先候选是 assistant-ui，通过 `ExternalStoreRuntime` 将本地 WKWebView 和 Swift / Pi RPC 的有序消息状态连接，保留现有执行工具。** 先用很小的真实桥接验证选区提问、流式输出、工具调用、审批和停止；新 `react-pi` adapter 作为可对照验证的后续选择。这是调研建议，尚未通过 Ghostty 内实际运行验证。

Pi 官方 TUI 是现成、维护中的完整 Agent 交互，可作为可靠基线和备用路径。下面区分已核验事实和方案判断。

## 本地实现与三个问题的证据

| 用户观察 | 当前源码证据 | 影响与核验边界 |
|---|---|---|
| 打开终端即出现 `Investigate with AI` | [Ghostty.App.swift:1647](/Users/huangyihang1/code/ghostty/macos/Sources/Ghostty/Ghostty.App.swift:1647) 对 command-finished 事件的 `exit_code > 0` 发失败通知；[TerminalView.swift:163](/Users/huangyihang1/code/ghostty/macos/Sources/Features/Terminal/TerminalView.swift:163) 保存退出码、目录和可视输出，没有命令身份，后续成功也没有通知来清除此状态 | 已确认失败入口的判定和生命周期过粗；**打开时那个 exit 1 的具体来源尚未确认**，不能断言一定是 shell 初始化或 prompt hook。可视快照也不能保证只包含该失败命令的输出 |
| Markdown 原样显示 | [TerminalAIView.swift:131](/Users/huangyihang1/code/ghostty/macos/Sources/Features/AI/TerminalAIView.swift:131) 用 `Text(model.response)` 展示动态 String | 没有真正 Markdown 块结构渲染，截图中的 `##`、`**`、反引号原样出现符合实现 |
| 运行时反馈和执行过程不清楚 | [TerminalAIModel.swift:167](/Users/huangyihang1/code/ghostty/macos/Sources/Features/AI/TerminalAIModel.swift:167) 把问题和回复拼进单一 String；[TerminalAIView.swift:136](/Users/huangyihang1/code/ghostty/macos/Sources/Features/AI/TerminalAIView.swift:136) 在所有文本后再列工具；[TerminalAIModel.swift:445](/Users/huangyihang1/code/ghostty/macos/Sources/Features/AI/TerminalAIModel.swift:445) 只重建 text 事件，其余分析更新忽略；接收 switch 没有 retry/compaction 状态 | 界面已有局部运行控件，问题在于提示弱、工具顺序与真实过程脱节、运行阶段不完整。应按事件顺序呈现消息与工具内容块，并持续显示当前状态 |

选区解释的默认问题也固定为“解释并调查问题”，见 [TerminalView.swift:160](/Users/huangyihang1/code/ghostty/macos/Sources/Features/Terminal/TerminalView.swift:160)。这会把正常 `cat Makefile` 内容带入问题调查语境；应根据入口区分解释选区与调查确实失败的命令。

## 1. 旧 Pi Web UI 的维护状态

| 核验项 | 2026-10-06 的结果 | 第一方证据 |
|---|---|---|
| npm latest | `0.75.3`，发布于 2026-05-18 09:59:23 UTC | [npm registry metadata](https://registry.npmjs.org/@earendil-works/pi-web-ui) |
| 许可 | MIT | [v0.75.3 package.json](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/package.json) |
| npm deprecated | latest metadata 没有 `deprecated` 字段；这只说明没有标记弃用 | [npm latest metadata](https://registry.npmjs.org/@earendil-works/pi-web-ui/latest) |
| 官方移除 | 2026-05-20 00:26:09 UTC，`b141e1fa2460868686ffd19c5d4ced743eee6c24` 删除 `packages/web-ui` 工作区；GitHub commit API 中 87 个 web-ui 文件均为 removed | [移除提交](https://github.com/earendil-works/pi/commit/b141e1fa2460868686ffd19c5d4ced743eee6c24) |
| 当前 main | `packages` 清单没有 web-ui，README 包列表也没有它 | [官方包目录 API](https://api.github.com/repos/earendil-works/pi/contents/packages)、[官方 README](https://github.com/earendil-works/pi) |
| 独立官方接续 | 本次公开 org 仓库清单未发现单独的官方 pi-web-ui 仓库；不能据此断言不存在任何私有或未来接续 | [Earendil org 仓库 API](https://api.github.com/orgs/earendil-works/repos?per_page=100) |

检索确实发现多个名称相似的社区项目；它们不是此旧官方包的官方迁移证明。本笔记没有把社区 README 当成官方维护证据。

## 2. 它曾经提供哪些组件

旧包是 **Lit / mini-lit Web Components + Tailwind CSS v4**，不是 React，也不是 SwiftUI。`ChatPanel` 组合 `AgentInterface` 与 artifacts 面板；README 的示例直接构造 `pi-agent-core.Agent`。[v0.75.3 README](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/README.md)、[package.json](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/package.json)

- Markdown 消息、thinking 区块、工具调用和结果依照内容顺序展示；工具结果按 `toolCallId` 配对；错误与取消有单独显示。[Messages.ts](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/src/components/Messages.ts)、[MessageList.ts](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/src/components/MessageList.ts)
- 流式消息独立于已完成列表，按 animation frame 合并更新；没有首个消息时有脉冲指示。[StreamingMessageContainer.ts](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/src/components/StreamingMessageContainer.ts)
- Bash 工具卡呈现等待、运行、完成或错误，显示命令与输出；工具渲染器可按工具名注册。[BashRenderer.ts](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/src/tools/renderers/BashRenderer.ts)、[renderer-registry.ts](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/src/tools/renderer-registry.ts)

这些交互结构可以参考或在 MIT 许可下按明确版本复用。选用它意味着自行承担版本兼容和维护，不能把 npm 仍然能下载等同于正在官方维护。

## 3. 与当前 Ghostty Pi RPC 的兼容边界

本机安装的 `@earendil-works/pi-coding-agent` 是 **0.87.1**，根据 `/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/package.json` 只读取版本、仓库、Node engines 核验；没有读取凭证。以下协议建议使用对应 v0.87.1 文档。

旧 `AgentInterface` 直接要求 `Agent` 对象的 `state`、`subscribe`、`prompt`、`abort`，会配置浏览器 API key 存储和 provider stream/proxy。它不是一个接收 coding-agent stdin/stdout RPC 的远程 view。[AgentInterface.ts](https://github.com/earendil-works/pi/blob/v0.75.3/packages/web-ui/src/components/AgentInterface.ts)

因此，即使嵌到 `WKWebView`，Ghostty 也仍需实现：

1. RPC 事件到稳定消息、流式消息和工具结果的转换。
2. 提交、停止、队列和模型状态的桥接。
3. Extension UI dialog 请求和回应，以及本应用执行权限闭环。
4. 当前终端、目录、选区、失败命令的上下文绑定。

这些是架构判断，不是旧包已经提供的能力。尤其不能用 Web UI 自带的浏览器模型/凭证设置替换用户已有 Pi 配置。

Pi 官方将 RPC 定义为适合不同语言、本地子进程和自定义 UI 的接口，Swift 应用继续选这条边界符合官方用途。`prompt` 的成功响应仅表示已接受；工作是否完成需要后续事件，v0.87.1 用 `agent_settled` 表示没有待自动继续的任务。stdout 必须持续读取 JSONL，stderr 只作为诊断。[v0.87.1 RPC 文档](https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/rpc.md)

消息按 `contentIndex` 重建 text/thinking/toolCall；完成内容和最终 `message_end.message` 是权威替换来源。工具按 `toolCallId` 关联 start/update/end，还要覆盖 retry、compaction 和 queue 事件，才能让“仍在运行”准确。[v0.87.1 JSON event 文档](https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/docs/json.md)

RPC 扩展支持 select/confirm/input/editor，请求后等待客户端回应；notify/status/widget 是单向事件。TUI 专用的 working indicator、footer/header、自定义组件等在 RPC 中可能是 no-op，不能期待运行状态会自动出现在 Ghostty。Ghostty UI 需要主动呈现。[官方 RPC Extension UI](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-extension-ui.md)

当前 main 的 `pi-client` / `pi-server` 标为 experimental，提供服务和会话路由，没有聊天组件；它们不是旧 web-ui 的现成替代品。[pi-client README](https://github.com/earendil-works/pi/blob/main/packages/client/README.md)、[pi-server README](https://github.com/earendil-works/pi/blob/main/packages/server/README.md)

## 4. 官方 TUI 作为成熟基线

官方终端模式已有 prompts / responses / tool calls / results / errors、底部目录/模型/会话/context/usage，工具输出和 thinking 的展开折叠，以及运行期间 steering/follow-up 和 Escape 停止。[官方 Usage](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/usage.md)

源码确认其 assistant 使用 `pi-tui.Markdown`，thinking 也有可切换显示；工具组件单独保存参数完整度、开始执行、部分结果、错误、展开状态。[v0.87.1 assistant-message.ts](https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/src/modes/interactive/components/assistant-message.ts)、[v0.87.1 tool-execution.ts](https://github.com/earendil-works/pi/blob/v0.87.1/packages/coding-agent/src/modes/interactive/components/tool-execution.ts)

方案判断：在独立 Ghostty 分屏运行用户已有 Pi，是最快获得完整维护中 Agent UI 的路线；但自动附带选区、失败命令和回填当前终端仍需 Ghostty 的上下文入口。它适合成为备用路径或早期验证基线。是否把它作为主交互，要结合图形命令卡、审批及终端联动的产品目标选择。

## 5. 图形界面的候选与接入代价

### assistant-ui：聊天组件和 Pi adapter 要分开评估

assistant-ui 是 MIT 的 TypeScript / React 聊天组件库，提供 streaming、scroll、Markdown、代码、工具 UI、输入与取消等组合部件；云服务是可选项。它可以复用到本地打包的前端中。[官方仓库](https://github.com/assistant-ui/assistant-ui)、[LICENSE](https://github.com/assistant-ui/assistant-ui/blob/main/LICENSE)

其 MarkdownText 支持标题、列表、链接、表格、代码卡和复制；默认代码文本没有高亮，需接 Shiki/Prism。流式文本通过消息 part 的运行状态显示，parser 更新经过 defer；不能把“有 Markdown 组件”误写成默认已经具备所有高亮和工具行为。[官方 MarkdownText 文档](https://www.assistant-ui.com/elements/markdown-text)

也有 `react-streamdown` 适配：支持流式未完成 Markdown 的修补，并可按需加入 code/CJK 插件。math/Mermaid 对本次终端排查不是必需，可以不引入。其控件和 streaming caret 需要正确配置 CSS 扫描，否则会看起来缺少样式或指示。[官方 Streamdown 指南](https://www.assistant-ui.com/docs/guides/streamdown)

`@assistant-ui/react-pi` 的 npm latest 已核验为 **0.0.28**，2026-10-06 12:36:59（Asia/Shanghai）发布；该包最早创建于 2026-06-13。MIT，Pi coding-agent 可选 peer 范围 `>=0.80.8`，覆盖本机 0.87.1。**兼容版本范围不是集成测试成功证明。** [npm registry](https://registry.npmjs.org/@assistant-ui/react-pi)

这个较新的 adapter 用 `PiClient` 合约驱动 streaming/reasoning/tools、队列、模型与 blocking extension UI；browser 入口不导入 Pi，Node 入口直接使用长驻 Pi SDK。README 明确列为 MVP：**没有 RPC 子进程 transport**，也没有 durable replay / backpressure / version negotiation；部分会话和资源能力尚未呈现。因此“assistant-ui 有成熟聊天 UI”和“react-pi 对 Ghostty 即插即用”是不同判断。[react-pi README](https://github.com/assistant-ui/assistant-ui/blob/main/packages/react-pi/README.md)

本项目可以实现满足 `PiClient` 的 native transport，但若它要求的多会话状态太宽，优先用 `ExternalStoreRuntime`：我们拥有 messages / isRunning / callbacks，组件按提供的能力启用发送、取消、工具回应和队列。它不会替 Ghostty 提供 RPC、上下文、审批策略或生命周期正确性。[官方 ExternalStoreRuntime 文档](https://www.assistant-ui.com/docs/runtimes/custom/external-store)

Apple 的 `WKScriptMessageHandler` 提供网页到 native 的消息入口。将固定版本本地前端和这个桥接用于面板，无需为了渲染层重新迁移 Pi 后端。仍需真实验证焦点、复制、键盘、流式长输出与 bridge 的运行一致性。[Apple WebKit 文档](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler)

### 原生路线：MarkdownUI / Textual

MarkdownUI 可在 SwiftUI 展示 GFM 标题、列表、引用、代码、表格、链接；最低 macOS 12，表格和多图段落需要 macOS 13。**目前处于 maintenance mode**，作者将新开发转向 Textual；MIT。因此它适合最小原生修复候选，但不应称为仍在持续演进的完整 Agent UI。[官方 README](https://github.com/gonzalezreal/swift-markdown-ui)、[LICENSE](https://github.com/gonzalezreal/swift-markdown-ui/blob/main/LICENSE)

Textual 是作者的后继 SwiftUI 文本引擎，当前 manifest 要求 Swift tools 6.0、macOS 15+；MIT。若要保持 Ghostty 更低 macOS 兼容范围，不能直接全量换成它。它也只是文本渲染器，运行状态、工具、审批和消息列表仍需自写。[Package.swift](https://github.com/gonzalezreal/textual/blob/main/Package.swift)、[LICENSE](https://github.com/gonzalezreal/textual/blob/main/LICENSE)

| 方案 | 可直接复用 | Ghostty 仍需负责 | 当前判断 |
|---|---|---|---|
| assistant-ui + 本地 WKWebView + Swift RPC | 聊天、Markdown、滚动、工具与输入部件 | Native bridge、Pi 事件状态、终端上下文、执行权限 | 图形面板优先验证候选 |
| react-pi + 自定义 Native PiClient | Pi 消息投影和更多运行元数据 | 尚无现成 RPC transport，需要实现兼容 client | 新 adapter，先验证再承诺 |
| SwiftUI + MarkdownUI | 原生 Markdown 块结构 | 完整 Agent UX 和状态仍需自写 | 小改动修复路线；维护模式 |
| SwiftUI + Textual | 新原生文本引擎 | 系统要求以及全部 Agent UX | macOS 15+ 方可考虑 |
| 官方 Pi TUI 在独立分屏 | 维护中的整套 Agent UI | 从当前终端传上下文与回填的集成 | 成熟备用及基线 |
| 旧 pi-web-ui 0.75.3 | 历史 Lit 组件 | RPC 适配、版本兼容与后续维护 | 不建议作为默认依赖 |

## 6. 面板重做时应冻结的行为

以下为调研阶段冻结的设计建议；后续实现进展见第 8 节：

- 固定且持续可见的状态：连接中、正在分析、正在执行某工具、等待确认、重试中、已完成、已停止、失败。停止按钮和耗时伴随活动状态展示；收起面板也保留运行徽标。
- 消息和工具用独立内容块，按真实事件顺序交错展示。文字用真正 Markdown 块结构和代码卡；工具卡显示名称、参数摘要、状态、部分输出和最终结果，不依赖 Agent 恰好先输出一句解释。
- 选区、当前目录、失败命令、退出码作为可核验的上下文附卡；“解释输出”和“调查失败”用不同任务入口与提示。普通选区不默认断言发生故障。
- 自动失败入口依赖 shell integration 识别的用户命令边界与结果，避免初始化命令、prompt hook 或无命令输出造成假报错。换任何聊天 UI 组件都不会自动修复该上下文来源问题。
- UI renderer 与 Pi RPC adapter 分离，使 Markdown 组件或完整聊天组件可以替换，而保留用户现有 Pi 配置和本应用已建立的执行边界。

## 7. 验收范围

方案选定后至少用真实运行验证：打开新终端没有无故失败 banner；选区提问不错误带上调查失败意图；首 token 到达前可见等待状态；多工具连续排查时状态不停；审批/停止/模型失败可理解；Markdown 标题、列表、代码、链接和复制正确；长输出滚动与选中文本不被流式更新打断；复用现有 Pi provider/model 配置不需再填凭证。

以上记录调研阶段的验收范围，具体已验证内容见下节。


## 8. 本地实现与验证进展

已采用 assistant-ui ExternalStoreRuntime + 本地 WKWebView。Swift 继续管理 Pi RPC、终端绑定、配置、消息状态和逐条命令确认。前端资源已随应用打包，不需要运行额外服务。

这次扩展保留 Ghostty 的原生面板外框、系统字体、紧凑间距和浅／深色呈现；网页只承担对话渲染，执行与审批边界仍由 Swift / Pi RPC 管理。

- 独立 user/assistant 消息和 text/tool-call 内容块按顺序呈现；工具结果回填原位置，message_end 覆盖流式临时内容。
- 可见状态覆盖连接、思考、回复、工具执行、待批准、重试、上下文整理、停止、完成和失败。收起面板保留任务及状态条。
- Markdown 标题、列表、表格、代码块、链接与代码复制使用组件渲染；流式更新保留用户滚动和选区。
- 对话改为利用面板全宽、文字靠左，角色标签保留紧凑侧栏；状态、上下文和运行时输入方式合并在输入框上方。输入框默认一行，随草稿增长至 100px 后内部滚动。
- 原生标题栏设置旁的位置按钮提供 Bottom／Right／Floating。底部／右侧可拖分隔线调整尺寸；浮动面板可拖标题栏移动、拖右下角把手缩放，把手与输入控件分开。位置及停靠尺寸保存为偏好，浮动坐标和尺寸仅随当前窗口保留；切换位置保留会话和草稿。
- 运行时支持 follow-up/steer 和排队反馈。send/draft 携带递增 revision，原生 snapshot 用 draftRevision 确认；迟到回显和首次启动期间的提交处理保留后续草稿，IME 组合期间延后同步。
- 取消任意非零退出都弹出的全局失败横条；选区入口改为中性解释。AI 面板内保留当前终端最近非零退出的显式入口，成功退出清除同终端记录。
- 退出上下文仍为当时冻结的可见屏幕、目录和退出码，尚无精确命令身份与输出分块。界面和提示明确这一质量边界。

此前验证包括前端类型检查与 mounted DOM 回归、原生模型/JSONL 生命周期测试、真正的 WKWebView 资源加载与 Markdown/工具顺序/原生确认及复制测试。此前使用已有 Pi 配置的真实请求选中 dms-adapter/kimi-k3，完成两次只读检查、命令建议和一个仅打印一行的确认执行；settings.json、models.json、auth.json 的内容哈希未变。

本轮布局调整通过前端类型检查、mounted DOM 回归、SwiftLint 和应用构建。在应用的隔离副本中验证三种位置切换及草稿保留、浮动面板移动和缩放、右侧分隔线缩放及对应终端列数变化。独立 WKWebView 在 1512×308、440×720、560×346、320×500 四种尺寸下检查含审批的内容，未出现页面横向溢出，状态、Stop 与审批控件可用。本轮未修改 Pi 执行边界，也未重跑完整原生单测或真实模型请求；此前结果不代表本轮重跑。

当前交付为本地 macOS Debug 构建。Safari 16 为前端编译目标，尚未在 macOS 13 的实体环境进行独立验收。前端维护与静态资源重建方法见 macos/AIChat/README.md。


## 9. 当前终端操作与右侧默认布局

2026-10-06 的后续实现将首次打开位置改为 Right，仍保留已保存的位置及 Bottom／Floating 切换。Pi 新增 `ghostty_terminal` 工具：read 回读当前可视画面；run 在会话绑定的真实终端 shell 中执行完整单行命令，保留该 shell 的别名、变量及环境。已有 `ghostty_diagnose`／`ghostty_run_command` 继续明确属于本机独立会话，不混用终端主机身份。

输入区的 Terminal control 开关提供本次任务内授权；未开启时逐条确认当前终端命令。任务结束／新会话会撤销授权，手动输入、粘贴、只读切换或终端重置会交还控制，关闭关联窗口会停止 agent。执行前验证 shell integration、主屏空提示符、无活动命令／用户草稿／IME；不会清空用户现有输入后执行。

新增同步 OSC 133 C／D 序号和输出读取 API，避免异步完成通知把旧命令当成新命令。执行结果等待匹配的命令结束及新空提示符；输出仅来自对应语义块，无输出不复用上一条输出。停止／超时只对可识别、仍属于 agent 的活动命令请求 Ctrl+C；无法确认结束时返回未知，不宣称已经杀掉进程或回滚更改。运行时限从审批后实际执行开始。多行 zsh PS1 与 ZLE 擦除草稿后残留空格已纳入就绪判定，PS2／实际未发送文本仍拒绝执行。

能力仍依赖终端呈现的 shell integration；未接管全屏 TUI、密码输入或任意缺少标记的 SSH 会话。read 的屏幕快照明确告知可能包含历史或远程输出，目录仅称终端上报值。

验证结果：核心定向测试（22 个输入场景及命令身份／输出回归）、现有 semantic prompt 回归、12 项 Node/Pi RPC 测试、前端类型检查和 DOM 回归、SwiftLint 均通过。`macos/build.nu --action test` 最终整套原生测试通过；独立 C app／隐藏窗口／PTY 使用应用自带 zsh integration，实测多行 PS1、连续命令、变量／环境／别名保留、非零退出、无输出不复用历史、用户草稿完整保留，以及 Stop 中断 sleep 后退出码 130。Pi 传输在这项 PTY 测试中为替身；另有真实 Pi RPC 加模型响应 fixture 的协议验证，本轮未发送真实供应商模型请求，也未操作用户原终端。


## 10. 快捷键与 Powerlevel10k 提示符兼容修复

新增 macOS 配置动作 `toggle_ai_panel`，默认 Command+Shift+A。View → AI Panel 菜单显示有效配置的快捷键，改绑时取消旧绑定再添加新绑定；打开时原生 WKWebView 获得输入焦点，隐藏时返回关联终端。C action 枚举追加新项，不改变已有动作编号。

用户确认报错发生在本地空提示符。实际安装的 Powerlevel10k（9253fb1）在主题重建时覆盖 Ghostty 注入的 PS1 标记，右侧提示也可能被标成输入。隔离原生 PTY 复现初始空提示符不可执行。修复采用 P10k 公开的 TERM_SHELL_INTEGRATION 选项，由主题单独提供 A/B/C/D，保留 Ghostty 的目录／标题／光标功能；只有该选项未显式设置时才在当前 shell 中启用，不修改用户启动配置。RPROMPT 在普通 zsh 下补独立标记；P10k 异步生成路径通过小型、存在性保护的生成器包装补标记，保留返回值及用户 hook，不修改主题文件或编译后的 prompt 变量。该私有生成器边界仅针对已验证的安装版本；未来缺失标记时继续拒绝执行，不能将未识别文字直接当成安全装饰。

同时修复 right prompt 把续行改成新主 prompt 的语义问题：保留原行边界，使多行提示符带 RPROMPT 时仍读取上一条真实命令的输出。新增 promptStatus 桥接，将缺少集成、主题文字无标记、实际待发送输入、PS2、活动命令、readonly 与 IME 状态分开提示，不再用一条空输入错误覆盖所有原因。

回归证据包括先失败的多行 RPROMPT 输出边界用例、随后通过的核心定向及已有语义回归、快捷键默认／改绑／解绑与菜单同步回归、整套原生测试及带非空 RPROMPT 的真实终端集成测试。实际 P10k 单行／多行、首次提示符、命令序号、输出捕获、真实生成器异步重建与未发送输入保护均已验证。当前产物为本地 Debug 应用，新的 shell integration 需要重新打开 shell。独立副本的 CUA 界面连接超时，本轮没有据此确认实际按键／焦点交互；配置、原生菜单路由与源代码处理链已经核验。


## 11. 执行统一走当前终端

用户的 CPU 查询截图实际调用了旧 `ghostty_diagnose` 的独立进程枚举，随后使用 `ghostty_run_command` 在独立本机 shell 排序；左侧没有命令，是该路线的预期表现。此前终端工具只是新增选择，旧工具描述与 LOCAL-host-first 提示仍让模型选用后台路径。Completed 后 Terminal control 已自动撤销，按钮未点亮不能证明执行时是否授权，也不能据此归因。

现已删除独立诊断、后台 shell 及其进程管理代码。Ghostty Pi 会话仅启用 `ghostty_terminal` 和非执行的 `ghostty_propose_command`；内置工具、用户扩展与 user_bash 路线保持禁用。提示词、设置说明与连接签名统一到绑定终端：所有需执行的检查／命令都经过真实终端，拒绝或失效直接报告，不回退其他主机或 shell。Pi working directory 仅负责本机连接进程启动，不决定命令目标。

Terminal control 只管理本次任务是否免去逐条审批。关闭时批准一条命令仍进入同一绑定终端；开启时可以连续执行。已验证 Node/Pi RPC 10 项回归，模型请求仅暴露两工具、旧工具不可调用，实际 RPC 读取→CPU 命令请求→结果消费及拒绝／失败传播正确。原生整套回归通过；在独立真实 PTY 中，授权关闭、逐条批准后 CPU 查询命令出现在可视画面，回读含 %CPU／%MEM，同时保留别名、环境、输入保护与 Stop 检查。现有和自定义 Pi 配置模式都断言仅启用两工具；本轮没有真实供应商模型请求或用户原终端操作。

## 12. AI 历史会话

此前原生消息仅存内存，并通过 `--no-session` 禁用 Pi 保存。现增加原生顶栏历史入口，按时间显示标题、来源目录和模型，支持搜索、打开及继续对话。Ghostty 在自己的 `ai/pi/conversations/<UUID>/` 中保存原生消息与工具快照，以及 Pi 自管的 `session.jsonl`。查看历史不启动 Pi；发送新问题时才加载同一 Pi 上下文。停止或变更连接配置只重连，明确 New 才开启空会话；已有 Pi 模型／登录配置继续复用。

继续历史使用当前关联终端，历史目录只描述来源；审批、任务授权、排队输入和活动工具不会恢复。中断内容静态显示。上下文缺失、损坏或原连接目录不可用时保留可读历史，并提示另起会话。每个会话用系统文件锁限制单个写入者；只读窗口不能保存共用快照，继续前取得锁并刷新其他窗口可能更新的内容。旧 Pi 子进程实际退出前仍持有锁，重连等待其退出。

消息流限频保存，提交／停止／结束／关闭窗口和正常退出时即时保存；原子文件写入失败会阻止清空或切换当前会话。目录权限为 0700，文件为 0600；原生记录只保存消息、工具结果及显示所需元数据，不保存连接凭据与终端授权。新增前已经丢失的内存对话无法追溯恢复，也不导入用户 Pi 的独立终端历史。

隔离真实 Pi 0.87.1 RPC 已验证精确会话路径创建、重新加载无模型／工具请求、后续模型请求携带旧上下文、首次用户输入落盘、abort 和硬终止行为，以及未完成历史工具调用不会重放。模型供应商与终端工具均由本地 fixture 代替；未发真实供应商请求，也未操作用户原终端。原生存储、会话生命周期、真实 PTY 回归与历史弹层渲染另由 macOS 测试覆盖。

最终 `macos/build.nu --action test` 通过，包含 5 项存储、6 项历史模型、原生历史弹层渲染，以及子进程退出后释放锁的检查；原有 WKWebView 和真实 PTY 终端回归仍通过。已查看隐藏窗口生成的 400×440 原生历史列表截图，标题、目录截断、模型及时间显示正常。切换会话同时重新创建 WebView，并隔离旧 renderer 的延迟消息，避免把旧草稿或输入动作应用到新会话。当前产物仍为本地 Debug 应用，需要重新启动该构建才能使用新增入口。
