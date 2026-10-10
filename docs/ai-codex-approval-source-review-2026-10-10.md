# Codex 自动审批源码复核与 Ghostty 改进方案

日期：2026-10-10，Asia/Shanghai。

## 结论

当前 Ghostty 与 Codex 的差距主要在执行和审核流程，继续增加超时时间无法解决频繁打断。优先修正三个具体问题：

1. **太多普通诊断动作进入 Guardian。** Ghostty 的确定性查询规则只接受少数单条命令，SSH/root 不进入该路径；Codex 常规动作先由执行策略和真实沙箱处理，需要额外授权的动作才进入审核，另有强制审核特例。
2. **审核缺少连续的可信任务上下文。** Ghostty 每次启动新一轮 Pi 都把审核用户消息重置为当前问题；“请继续”“可以”可能失去之前的授权和提问语境。Codex 独立保存用户历史、验证回答与近期工具证据，并支持完整和增量审核上下文。
3. **审核基础设施故障直接变成人工审批。** Ghostty 把超时、provider 和格式错误都归入 `.ask`；Codex 区分审核失败与风险拒绝，把未执行动作的失败交还主 agent，保留有上限的恢复机会。

这些是源码可确认的流程差异。它们解释了更容易进入审核、丢失授权语境和被人工审批打断的机制，**不等于已经证明某一次线上超时的模型服务原因**。相关证据分别见下面的执行链、上下文和错误处理章节。

## 核验范围与证据边界

- Codex：官方 `openai/codex`，本地 `/Users/huangyihang1/code/codex`，固定提交 [`806d9732c974bc8a51b8317c1bd8985544fe627c`](https://github.com/openai/codex/tree/806d9732c974bc8a51b8317c1bd8985544fe627c)。下文官方链接均固定到该提交。
- Ghostty：`10yihang/ghostty`，本地 `/Users/huangyihang1/code/ghostty`，固定基线 [`46494e84d32fb500cdad51caeb4dd77764a5846f`](https://github.com/10yihang/ghostty/tree/46494e84d32fb500cdad51caeb4dd77764a5846f)。该基线插件审核总预算为 90 秒，原生客户端等待为 105 秒。
- 本轮为源码研究和方案文档，不修改生产实现，不构建、执行模型或用户插件，不发布版本，也不操作当前终端或 SSH。
- 公开源码覆盖 core、extension、TUI、app-server 协议与测试，不能确认私有 Codex Desktop 的界面、线上 feature flags、审核服务的模型实现、服务可用性或延迟。

## 当前真实调用链

```text
Codex
  ToolRouter → ToolRegistry → ExecCommandHandler → ProcessManager
    → ExecPolicy：规则、危险动作、目标权限及实际沙箱
      ├─ Forbidden → 拒绝
      ├─ Skip → 在对应执行约束下执行；strict review 特例仍需审核
      └─ NeedsApproval → Session.request_approval
          → PermissionRequest hooks / reviewer contributor 路由
          → 同步 Guardian 或有效的异步评分
          → 原动作与授权重新验证 → 执行或返回拒绝/故障
          → 部分明确 AskUser / 无 reviewer / 可选预算不足情形才进入人工审批

Ghostty 当前 terminal run
  原生请求校验 → 当前 terminal target → literal query policy
    ├─ query 开关开启 + 少量只读命令 + 已验证本地非 root shell → 查询执行
    └─ 其他动作 → 原生固定 action/context/digest/nonce
        → Pi 私有 Guardian command → 当前对话模型 completeSimple
        → 单请求、无检查工具、JSON verdict
        → approve / deny / ask
        → ask（包含接口和格式故障）立即进入人工审批
```

Codex 链路见 [router.rs:359–392][c-router]、[exec_command.rs:178–199][c-exec-handler]、[process_manager.rs:1461–1531][c-process]、[orchestrator.rs:169–225][c-orchestrator]。Ghostty 链路见 [TerminalAIModel.swift:2228–2246][g-dispatch]、[guardian.mjs:123–163][g-completion]、[TerminalAIModel.swift:2307–2329][g-complete-native]。

## 差异表

| 维度 | Codex 固定提交的实现 | Ghostty 当前实现 | 实际影响 |
| --- | --- | --- | --- |
| 审核前的执行策略 | 显式规则、危险动作检测、权限与真实执行器沙箱；常规 `Skip` 通常直接执行 | 极小字面查询规则，SSH/root 所有 run 进入逐次审核 | Guardian 调用数量偏高 |
| 会话授权 | 仅明确 `ApprovedForSession` 才缓存；命令、环境、cwd、权限及策略均参与约束 | 普通命令批准后清除 query grant；尚无同等精确会话授权流程 | 一次通过不能减少下一次打断 |
| 审核模型 | provider 首选、模型 override、catalog 解析；优先低 reasoning effort | 直接使用当前 Pi 对话模型 | 慢的主模型也被用来做短审核 |
| 审核上下文 | 用户、验证回答、assistant 语境、近期工具证据、目标权限；完整/增量 | 新一轮重置为当前用户问题，运行中追加后续输入 | 短回复可能缺少先前授权语境 |
| 审核执行 | 可复用的独立 reviewer agent，受限只读检查工具 | 独立的无工具单次 completion | 本地状态缺失时只能保守判断 |
| 重试与预算 | 最多 3 次审核尝试共享 90 秒；request/stream 各最多 1 次底层重试；按故障分类 | 90 秒共享 AbortSignal，SDK `maxRetries: 1`；没有同等 parse/stream 分类审核重试 | 可恢复故障更容易转人工 |
| 输出格式 | API JSON schema 指导，Guardian API `strict=false`；解析允许外层文字；低风险允许最小 JSON | 插件 prompt 要求四字段纯 JSON，严格本地验证；未传同等 API 输出 schema | 格式漂移成为基础设施失败 |
| 输入预算 | 对模型窗口、固定 policy、历史、工具 schema、完整请求一起计量；精确 action 不截断 | 主要是字符、消息条数和 1 MiB 形状上限 | 大小校验不能替代模型窗口预算 |
| 审核故障 | timeout/reviewer failure 交还 agent；与真实 Deny 分开 | `.ask` 直接人工审批 | 审核服务异常也阻塞用户 |
| 状态与审计 | 绑定 review/turn/item，审核状态、耗时、TTFT、token 与原因分类；批准通常不污染历史 | activity、对话文本、人工审批框与总审核耗时 | 难以定位等待发生在何处 |

上表对应证据在下面各节逐项展开。它比较实现机制，没有对两者线上延迟、通过率作未经测量的排序。

## 1. 首先减少不必要的 Guardian 调用

### Codex 的普通命令不是每条都由 LLM 判安全

`exec_policy` 在 `OnRequest` / `Granular` 且有受限沙箱时，对未要求 sandbox override、未命中明确危险模式的常规动作可以确定性允许。该允许通常仍在沙箱中执行；只有所有解析片段都由显式规则允许时，才可能产生 `bypass_sandbox=true`。`UnlessTrusted`、危险模式、额外权限、strict review 等路径另有约束，不能概括成“Codex 所有命令免审核”。见 [exec_policy.rs:770–854][c-policy]、[exec_policy.rs:440–459][c-bypass]、[orchestrator.rs:169–225][c-orchestrator]。

Ghostty 当前查询规则仅包含 `ps/uname/id/whoami/uptime/ls/df`，并排除 pipeline、重定向、展开和引号里的特殊字符。即使 `ps | head` 这种常见诊断组合也会进入逐次审核。查询执行还要求开关开启、集成 prompt、已验证的直接本地非 root shell。见 [TerminalAICommandPolicy.swift:13–16,59–75][g-query-policy]、[TerminalAIModel.swift:2230–2245][g-dispatch]。

**可移植方向：** 对适用目标补充范围明确的诊断查询和字面 pipeline，并在真正 dispatch 时验证目标与 executable。不能直接复制 Codex 的“普通命令在沙箱里运行”默认，因为现有 SSH/root 交互 shell 没有对应远端沙箱。

### 复合命令必须整体证明

Codex 用 tree-sitter 解析可证明为纯字面命令的 `&&/||/;/|`，逐片段评估。复杂 shell 的字面扫描用于发现危险命令，不能作为允许整个 shell 语句的安全证明；不可信 wrapper 的参数看起来像 `ls` 也不能让 wrapper 变安全。见 [bash.rs:22–98,121–135][c-bash]、[executable_identity.rs:20–49,87–92][c-executable]。

Ghostty 应采用真正语法解析或严格限定的字面 pipeline grammar，逐段校验 flags 与 executable。包含 `grep/head/awk` 不足以证明整句只读；写入重定向、命令替换、解释器求值和隐藏 wrapper 必须保留审核。

### 保留用户偏好，但重新验证实际授权

Ghostty 人工和 Guardian 批准后都会清除 `terminalControlAllowed`。源码说明，已批准命令可能改变 shell functions/hooks/state，因此旧查询授权不能直接延续。这是合理的安全目的，不能靠删除两行解决。见 [TerminalAIModel.swift:916–922][g-clear-manual]、[TerminalAIModel.swift:2324–2329][g-complete-native]。

建议将“用户希望启用查询”的偏好与“当前目标的查询身份验证”拆开。每次执行重新验证 shell/host/权限与 executable；真正改变身份或执行约束时废弃授权并解释原因。偏好保留不等于授权永久有效。

## 2. 区分审核失败、风险拒绝与人工请求

Codex `Timeout` 返回 `TimedOut`，`Cancelled` 返回 `Abort`。session、parse、stale authorization 等失败会阻止执行，给出审核失败原因；它们不自动升级成人工弹窗。可选审核的 input-budget 耗尽会返回 `None`，显式 `AskUser` 路由也可能进入人工流程。见 [completion.rs:83–158][c-completion]、[routing.rs:130–142][c-ask-routing]。

`TimedOut/Denied` 在 approval 层成为 `ToolError::Rejected`，工具事件层再将它作为反馈交还主模型，默认超时指令允许重试一次或询问用户。对应测试确认被审核的命令未执行，随后主 agent 正常继续并结束当前 turn。见 [approvals.rs:425–432][c-timeout-approval]、[events.rs:444–467][c-tool-feedback]、[guardian.rs:17–20][c-timeout-prompt]、[guardian_review.rs:2343–2453][c-timeout-test]。

Ghostty 插件当前返回 `error` envelope，native verifier 将其全部转为 `.ask`，随后 `presentManualReview`。基础设施失败和需要人类授权共用同一个分支，是打断频繁的明确原因。见 [guardian.mjs:208–212][g-error-envelope]、[TerminalAIApprovalReview.swift:133–178][g-verifier]、[TerminalAIModel.swift:2318–2320][g-complete-native]。

建议建立明确结果：

```text
Allowed                → 重新验证绑定目标与授权，执行一次
Denied                 → 动作不执行，告诉主 agent 风险理由
TimedOut/ProviderError  → 动作不执行，返回可恢复的审核阻塞
InvalidAssessment      → 动作不执行，限定重试或交还主 agent
Cancelled/StaleTarget  → 丢弃旧结果，取消或要求新动作重新审核
ExplicitAsk            → 人工确认
```

用户仍可从失败动作入口选择人工继续，但不应把所有服务故障都自动挂进审批框。主 agent 的恢复必须有上限，同一 action 不能无限重审；也不能将超时视为允许，或在不知道动作是否执行过时自动重放。

Codex 的拒绝熔断只计入真实完成的 `Deny`，timeout/provider 等非结论故障不会被计为风险拒绝。Ghostty 后续也应区分这两类计数。见 [review.rs:178–204][c-denial-accounting]。

## 3. 补齐可信的连续审核上下文

Codex 审核上下文包含 root 用户历史、host 验证的回答、权限、精确 action、assistant 语境及近期工具参数/结果；依据 reviewer 进度发送完整或增量 transcript。授权评分保留原角色：assistant 和工具输出可以解释任务，但不能冒充用户授权；上下文缺失有明确 omission notice。见 [prompt.rs:116–127,184–238,272–305][c-context]、[authorization.rs:12–65,81–93][c-authorization]。

Ghostty 重启或恢复 Pi 主会话后，在 `submit` 中重置 `reviewUserMessages = [question]`，审核只读取这组消息。运行中 `sendInput` 才继续追加。因此主模型知道上一轮任务，并不意味着 Guardian 也知道上一轮任务。见 [TerminalAIModel.swift:505–544][g-reset-history]、[TerminalAIModel.swift:2266–2269][g-review-input]。

建议 native 保存原始用户对话，携带必要的 assistant 提问语境、最近已观察到的工具结果和 target 信息。对“请继续”“可以”这种输入，审核应看到它回应了什么以及之前的限制。原始用户记录与非授权证据必须分开编码，不将 Pi 摘要、插件输出或文本中的“用户已批准”提升为授权。

现有 Ghostty 已在用户新输入时取消旧 review，并在结果生效前重查 generation、terminal target 和 workspace；digest 绑定 context/action。**这部分应保留，不存在依据可据此声称“后续输入仍会接受旧授权”的漏洞。** 见 [TerminalAIModel.swift:658–661][g-steering]、[TerminalAIModel.swift:2312–2315][g-complete-native]、[TerminalAIApprovalReview.swift:76–87,123–128][g-request-binding]。

## 4. Reviewer 模型和运行时要与主对话分开考虑

### 模型选择

Codex 每次尝试根据模型 catalog 解析 reviewer，优先 provider 推荐或模型 metadata override，支持时使用低 reasoning effort；没有适用 catalog 项时保留 parent fallback。该提交 provider 默认名为 `codex-auto-review`，API-key 路径偏好 `gpt-5.6-luna`。这些是该提交的选择逻辑，**不是建议在任意 Pi provider 里硬编码这两个名字**。见 [reviewer_config.rs:85–125][c-review-model-config]、[model.rs:17–65][c-review-model]、[provider.rs:89–93][c-provider-model]、[provider.rs:432–442][c-provider-auth-model]。

Ghostty 直接使用 `ctx.model` 和现有 Pi registry 的认证配置，意味着主对话模型也处理每条短审核。见 [guardian.mjs:123–140][g-completion]。

建议提供单独的 reviewer provider/model 选择，复用用户已有 Pi 配置与认证，通过能力与可用模型校验。主模型切换时不必改变 reviewer；未配置时明确说明使用当前模型。判断延迟是否改善需要测量，不能将模型名或低 reasoning 参数当成快服务保证。

### 预算与重试

Codex 在准备上下文前确定一次 90 秒 deadline；最多 3 次审核尝试共享它。reviewer 的底层 request/stream 重试各限制为 1。审核重试只覆盖 parse、stale authorization 和可分类的 transient HTTP/stream 故障，使用 200 ms 起始指数退避、抖动及 provider retry-at；timeout、取消、认证或非暂态错误不进入该层重试。见 [lib.rs:40–41][c-limits]、[review.rs:97–117][c-review-budget]、[retry.rs:75–173][c-retry]、[reviewer_config.rs:12–17][c-locked-config]。

Ghostty 现在同样有 90 秒总 AbortSignal，SDK `maxRetries: 1`，native 留到 105 秒等待桥接结果。增加到 90 秒已接近 Codex 的总预算；剩余差距是故障分类、解析/流恢复和请求数。不能叠加多层重试后又给每次尝试完整 90 秒。见 [guardian.mjs:123–163][g-completion]、[TerminalAIModel.swift:2280–2285][g-native-deadline]。

Codex 在 timeout/cancel 后中断并最多用 5 秒 drain 对应 turn 的终结事件，匹配 event/turn identity；只有完成清理才允许复用 reviewer。见 [execution.rs:66–175,178–200][c-execution]。Ghostty 采用复用运行时后，应补充等价的单次结果消费、取消清理与晚到结果丢弃。

### 输出契约

Codex schema 只要求 `outcome`，允许低风险直接返回简短 allow JSON；parser 允许外层文字，并在缺省字段时提供风险、授权与 rationale 默认值。API 虽传 JSON schema，但 Guardian 构造的 `output_schema_strict` 是 `false`，不能描述为严格 constrained JSON enforcement。见 [assessment.rs:24–61,77–115][c-assessment]、[settings.rs:115–120][c-turn-schema]、[turn.rs:1586–1589][c-schema-strict]、[common.rs:392–407][c-schema-api]。

Ghostty 插件要求四字段纯 JSON 且拒绝 duplicate keys，native verifier 本身已支持部分字段默认值。区别主要发生在插件 completion/validation 层，而非 native 完全无法解析最小 verdict。见 [guardian.mjs:47–53,87–120][g-output-contract]、[TerminalAIApprovalReview.swift:157–181][g-verifier]。

优先为支持的 Pi provider 使用实际 API JSON schema，保留四字段与现有高风险、完整证据约束。只有完成能力检测和回归验证后，再评估最小输出或受限 wrapper 恢复；不能机械地把任意模型的 `{"outcome":"allow"}` 默认为低风险。解析失败可以限定重试，但应继续拒绝重复键、矛盾 verdict、tool-call 输出与无法绑定的结果。

## 5. 输入预算、复用与检查工具

### 模型窗口预算

Codex 依据模型 catalog 的窗口与配置 cap，计算固定 policy、历史、工具/schema 和完整 request 的成本，并留 256 token margin。超额时先删除 optional evidence，最后按明确 marker 缩短历史；**required action 不截断**。见 [request_budget.rs:26,65–113,148–163][c-request-budget]、[input_budget.rs:131–172,210–228][c-input-budget]、[budget.rs:59–78][c-window]、[enforcement.rs:111–245][c-enforcement]。

Ghostty 的 1 MiB、100 条用户消息与每条字符限制只解决输入形状和总大小，不等同于模型窗口预算。见 [guardian.mjs:58–84][g-request-size]。补齐历史后更需要分层预算，避免无限携带旧文本；精确 command/diff 和关键用户约束应先于可选工具输出保留，缺失必须明确标记。

### 复用不等于缓存批准

Codex 每个 parent thread 有一个 reviewer pool：后台预热；空闲时复用 trunk；忙时从最后已提交 checkpoint 建临时 fork；有效配置、history lifetime 改变时重建或废弃。见 [pool.rs:147–168,193–238,283–301][c-pool]、[sync_reviewer/mod.rs:160–213][c-prewarm]、[review.rs:168–181][c-session-design]。

这可保留稳定的 prompt-cache prefix 与审核上下文，但不是“一次 allow 后以后都 allow”。Ghostty 固定 policy 也可能得到 provider 的隐式 prompt cache；源码不能证明其每次都 cold，也不能仅凭 pool 存在证明 Codex 线上更快。建议先测量 input/cached-input/TTFT，再决定复用收益。

### 工具限制由真实执行边界保证

Codex reviewer 允许 `exec_command/write_stdin/view_image/exec/wait`，要求 managed sandbox 与 unified exec，不暴露额外权限；每个环境与 read-only 权限取交集，审批策略 `never`，清空外部 MCP，关闭 plugins、memory、collab 等非必要能力。可选的历史搜索工具另有 feature 条件。见 [settings.rs:43–65,84–119][c-review-tools]、[reviewer_config.rs:12–69][c-locked-config]、[sync_reviewer/mod.rs:108–136][c-history-tools]。

Ghostty 当前无工具，执行环境说明也明确 Pi extensions 不是操作系统沙箱。见 [guardian.mjs:33–40,134][g-completion]。第一步可由 native 提供只读的 target/文件/会话证据；后续若让 reviewer 主动检查，必须使用 host 强制限制的接口。不能给它任意 `bash` 或已加载插件，再通过 prompt 宣称只读。

## 6. 会话授权与审计/UI

Codex 仅缓存用户明确选定的 `ApprovedForSession`。命令授权 key 包含环境、command、cwd、tty、sandbox/additional permissions，查询还校验环境 execpolicy fingerprint。用户批准 prefix amendment 后才更新内存与磁盘规则；宽泛 interpreter、`sudo` 等 prefix 不适合自动建议。见 [sandboxing.rs:66–112][c-session-cache]、[approvals.rs:643–689][c-cache-key]、[session/mod.rs:2732–2749][c-rule-persist]、[exec_policy.rs:958–1018][c-prefix]。

Ghostty 可增加“本次 / 当前目标会话同类动作”的明确选择，但需要绑定 terminal surface、host、用户/权限、shell 会话身份、cwd 与策略版本。对一个 root 命令的一次批准，不是对整个 root 会话的无限授权；普通 Guardian allow 也不应自动产生永久 prefix 规则。

Codex TUI 审核状态临时接管 footer，支持并行审核汇总，结束后恢复 working；批准通常不占对话历史，timeout/拒绝可追踪。结构化记录绑定 reviewId/turnId/itemId，含 start/end/status/rationale；指标包括 review duration、TTFT、input/cache/reasoning/output tokens。见 [tool_requests.rs:29–35,98–202][c-ui]、[reporting.rs:61–76,94–122][c-reporting]、[metrics.rs:54–99][c-metrics]。

建议把审核状态绑定原 tool card，显示正在审核、重试次数、已等待时间及具体错误；成功收起，故障保留展开详情与人工继续入口。日志记录安全的 provider/model ID、error class、attempt、TTFT、生成耗时、bridge 耗时与 token 计量，默认不落 raw response、认证 headers、密钥或完整敏感 payload。这能区分首 token 前的等待、生成阶段和客户端桥接延迟；首 token 前的排队、网络传输和预填充仍需额外证据才能分开。

## 优先级与可移植阶段

### P0：先修打断和错误归因

1. 分离审批状态机：审核服务错误交回主 agent，保持原动作未执行；保留人工继续入口与最多一次外层恢复。
2. 增加独立 reviewer 模型配置，复用现有 Pi model registry/auth，检测是否可用；不硬编码 Codex backend alias。
3. 保存连续的原始用户审核上下文和必要问答语境，附近期非授权证据；模型窗口预算内保留精确动作与用户限制。
4. 对适用的已验证目标增加有限诊断规则，先覆盖实际高频查询；将 query 偏好与 target 授权分开。没有可靠身份或执行限制的 SSH/root 继续保守处理。

### P1：减少重复成本并让行为可解释

1. 增加 target-bound 精确会话授权，以及可审阅的规则生命周期；区分一次批准与当前会话批准。
2. 引入完整的复合命令证明，或范围明确的字面 pipeline grammar；未能证明的语法保留审核。
3. 为具备能力的 provider 传真实四字段 JSON schema；分类恢复 transient stream/parse 故障，共享原 deadline。
4. 在安全生命周期下复用 reviewer 上下文；补充结构化审核事件、TTFT、token、重试和工具卡 UI。

### P2：证据能力和异步评分

1. 在真实隔离与 host 限制下增加必要的只读检查工具；优先元数据快照和有界文件读取。
2. 评估异步观察、有效低风险评分与同步审核的协作，需要完整 observation、授权版本、lag 和 action 顺序校验。

Codex `guardianv2`、历史搜索等在该提交的 feature 默认仍是 under development / false；model metadata、requirements 和线上配置也会影响实际启用。不能把公开实现或源码默认等同于当前 Desktop 默认行为。见 [features/lib.rs:1815–1879][c-features]、[async_scorer/approval.rs:96–155,234–276][c-async]。建议先完成 P0/P1，再考虑移植这部分复杂状态。

## 验收标准

| 场景 | 必须验证的结果 |
| --- | --- |
| 模型超时或 503/429 | 动作未执行；有界重试共享总 deadline；失败交还 agent；不会自动弹出普通人工审批，也不会默认允许 |
| 401/取消/目标变化 | 不作为 transient 无限重试；晚到 verdict 不生效；取消清理后才能复用 reviewer |
| “请继续”“可以” | Guardian 看到原始任务与所回应的问题；assistant/tool 文本不能伪造用户授权 |
| `ps ... | head ...` 等允许组合 | 所有片段、flags、executable 和目标均被验证；不因包含只读命令词就允许整句 |
| 重定向、替换、未知 wrapper、写入 | 无法完整证明则送审核；不得用复杂语法扫描的部分结果证明安全 |
| 已有 SSH/root shell | 保持在当前终端执行；本地二进制身份/沙箱不能证明远端安全；身份变化使相关授权失效 |
| 当前会话批准 | 只覆盖明确目标与规则；cwd/用户/特权/会话/策略变化触发失效；一次批准不变永久授权 |
| schema 输出漂移 | 支持时有 API schema；duplicate/矛盾/tool verdict 仍拒绝；格式恢复不降低高风险与证据阈值 |
| 输入超过窗口 | 精确 action 不截断；可选证据先让位；缺失标记清楚；关键限制无法容纳时阻止自动批准 |
| 长会话与并发审核 | TTFT/token/cache 指标可比较；不复用未 drain 的 turn；成功不刷屏，失败对应原 tool card |
| 真实风险 Deny 与接口故障 | UI、工具反馈、审计与熔断分别分类；服务异常不当作真实风险结论 |

这些是后续实现的验收要求，本轮未声称已通过相关运行验证。延迟与人工打断改善应以同一批本地/SSH 操作的 Guardian 调用次数、人工打断次数、review P50/P95、TTFT 和失败原因占比评估，先建立基线再比较。

## 首轮实现范围

后续实现按用户要求继续使用现有 Pi 模型，先修恢复流程与授权上下文：审核服务故障返回未执行的工具反馈；连续故障只允许一次外层恢复；格式、截断及已识别的流中断共用 90 秒期限；保存原生人类输入并补充最多四条非授权 assistant 摘录；Guardian 和确定性查询开关同时显示。

原始人类限制不因超过 100 条消息而被丢弃，仍受完整请求总大小和单条消息限制。无法完整提供证据时说明原因并保留单独审批。针对模型窗口的精确 token 预算、增量 reviewer 会话、更多命令语法证明与用户明确的会话授权仍属于后续工作。本次没有强制切换模型，也没有扩大 SSH/root 的执行权限。当前使用方式见 [ai-guardian-approval.md](ai-guardian-approval.md)。上文对比和引用仍以开头固定提交为准。

## 不能照搬的边界

- **远端执行器边界：** Codex 通过远端 executor 自身的 permission profile/capabilities 验证授权，不用 Guardian 所在本地文件系统推断远端限制。缺少安全 escalation capability 会被拒绝。Ghostty 当前向已存在 SSH/root shell 发送文本，没有同等远端 OS 沙箱。见 [guardian/permissions.rs:67–96][c-remote-permissions]、[orchestrator.rs:264–279][c-remote-capability]。
- **Backend 服务：** 客户端有 `x-codex-guardian: reviewer`、parent response metadata、credits request 和特殊 routing/service-tier 处理。它证明官方客户端协议，不证明任意 Pi 账号能使用 `codex-auto-review`，也不公开服务端训练、队列、SLA 或资格判断。复制 alias/header 无法获得等价服务。见 [sync_reviewer/mod.rs:92–104][c-backend-header]、[client.rs:1202–1243][c-backend-metadata]、[client.rs:1804–1805][c-backend-tier]、[client.rs:1974–1975][c-backend-ws-tier]。
- **模型输出契约：** Codex 的宽容 parser 和最小低风险输出配合其模型及运行时。不能未经验证地迁移默认风险语义到任意 generic Pi 模型。
- **缓存边界：** reviewer 会话复用、用户会话授权、异步评分是三种不同机制；上下文复用不产生动作授权，先前 allow 不覆盖新目标或新增权限，沙箱内批准不覆盖沙箱外重试。见 [routing.rs:109–127][c-fresh-routing]、[orchestrator.rs:484–514][c-escalation]。

建议下一次实现以 P0 为范围：先让审核服务故障可恢复、上下文连续、模型可单独选择，再降低适用目标的审核频率。这样可以得到具体可测的减少打断结果，同时保持当前执行目标和高风险约束。

[c-router]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/router.rs#L359-L392
[c-exec-handler]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/handlers/unified_exec/exec_command.rs#L178-L199
[c-process]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/unified_exec/process_manager.rs#L1461-L1531
[c-orchestrator]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/orchestrator.rs#L169-L225
[c-policy]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/exec_policy.rs#L770-L854
[c-bypass]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/exec_policy.rs#L440-L459
[c-bash]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/shell-command/src/bash.rs#L22-L135
[c-executable]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/exec_policy/executable_identity.rs#L20-L92
[c-completion]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/completion.rs#L83-L158
[c-ask-routing]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/routing.rs#L130-L142
[c-timeout-approval]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/approvals.rs#L425-L432
[c-tool-feedback]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/events.rs#L444-L467
[c-timeout-prompt]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/prompts/src/model_messages/guardian.rs#L17-L20
[c-timeout-test]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/tests/suite/guardian_review.rs#L2343-L2453
[c-denial-accounting]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/review.rs#L178-L204
[c-context]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/guardian/prompt.rs#L116-L305
[c-authorization]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/guardian-context/src/authorization.rs#L12-L93
[c-review-model-config]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/guardian/reviewer_config.rs#L85-L125
[c-review-model]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/model.rs#L17-L65
[c-provider-model]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/model-provider/src/provider.rs#L89-L93
[c-provider-auth-model]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/model-provider/src/provider.rs#L432-L442
[c-limits]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/lib.rs#L40-L41
[c-review-budget]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/review.rs#L97-L117
[c-retry]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/retry.rs#L75-L173
[c-locked-config]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-v2/src/sync_reviewer/reviewer_config.rs#L12-L69
[c-execution]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/execution.rs#L66-L200
[c-assessment]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/assessment.rs#L24-L115
[c-turn-schema]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/settings.rs#L115-L120
[c-schema-strict]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/session/turn.rs#L1586-L1589
[c-schema-api]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/codex-api/src/common.rs#L392-L407
[c-request-budget]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/guardian/request_budget.rs#L26-L163
[c-input-budget]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/guardian/input_budget.rs#L131-L228
[c-window]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/guardian-context/src/budget.rs#L59-L78
[c-enforcement]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/guardian-context/src/enforcement.rs#L111-L245
[c-pool]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/pool.rs#L147-L301
[c-prewarm]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-v2/src/sync_reviewer/mod.rs#L160-L213
[c-session-design]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/guardian/review.rs#L168-L181
[c-review-tools]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/settings.rs#L43-L119
[c-history-tools]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-v2/src/sync_reviewer/mod.rs#L108-L136
[c-session-cache]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/sandboxing.rs#L66-L112
[c-cache-key]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/approvals.rs#L643-L689
[c-rule-persist]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/session/mod.rs#L2732-L2749
[c-prefix]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/exec_policy.rs#L958-L1018
[c-ui]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/tui/src/chatwidget/tool_requests.rs#L29-L202
[c-reporting]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/reporting.rs#L61-L122
[c-metrics]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/metrics.rs#L54-L99
[c-features]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/features/src/lib.rs#L1815-L1879
[c-async]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-v2/src/async_scorer/approval.rs#L96-L276
[c-remote-permissions]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/guardian/permissions.rs#L67-L96
[c-remote-capability]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/orchestrator.rs#L264-L279
[c-backend-header]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-v2/src/sync_reviewer/mod.rs#L92-L104
[c-backend-metadata]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/client.rs#L1202-L1243
[c-backend-tier]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/client.rs#L1804-L1805
[c-backend-ws-tier]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/client.rs#L1974-L1975
[c-fresh-routing]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/ext/guardian-reviewer/src/routing.rs#L109-L127
[c-escalation]: https://github.com/openai/codex/blob/806d9732c974bc8a51b8317c1bd8985544fe627c/codex-rs/core/src/tools/orchestrator.rs#L484-L514
[g-dispatch]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIModel.swift#L2228-L2246
[g-completion]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/PiPlugins/codex-guardian/guardian.mjs#L123-L163
[g-complete-native]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIModel.swift#L2307-L2329
[g-query-policy]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAICommandPolicy.swift#L13-L75
[g-clear-manual]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIModel.swift#L916-L922
[g-error-envelope]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/PiPlugins/codex-guardian/guardian.mjs#L208-L212
[g-verifier]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIApprovalReview.swift#L133-L181
[g-reset-history]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIModel.swift#L505-L544
[g-review-input]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIModel.swift#L2266-L2269
[g-steering]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIModel.swift#L658-L661
[g-request-binding]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIApprovalReview.swift#L76-L128
[g-native-deadline]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/Sources/Features/AI/TerminalAIModel.swift#L2280-L2285
[g-output-contract]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/PiPlugins/codex-guardian/guardian.mjs#L47-L120
[g-request-size]: https://github.com/10yihang/ghostty/blob/46494e84d32fb500cdad51caeb4dd77764a5846f/macos/PiPlugins/codex-guardian/guardian.mjs#L58-L84
