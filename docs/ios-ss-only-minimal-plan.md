# iOS SS Only Minimal Plan

**目标**

做一个全新的 iOS 客户端，只支持：
- 导入并解析 `ss://`
- 保存一个或多个节点
- 选择节点并发起连接
- 展示最小连接状态

明确不做：
- PAC
- HTTP Proxy / Privoxy
- 二维码分享与扫码
- 菜单栏/桌面 helper
- LaunchAgent / shell 脚本
- 热键
- 高级诊断
- 除 `ss://` 之外的其它协议

额外技术约束：
- 使用纯 Swift 实现业务代码
- 不依赖当前 macOS 工程里的 Objective-C / shell / helper 链路
- 连接层优先使用 Apple 原生框架与 Swift 标准能力

---

**结论**

这个最小方案可行，而且比“迁移整个 macOS 项目”轻很多。

当前仓库里真正能复用的只有两类内容：
- `ss://` 解析逻辑
- 节点模型字段定义

参考文件：
- `ShadowsocksX-NG/ServerProfile.swift`
- `ShadowsocksX-NG/ServerProfileManager.swift`

不能复用的内容：
- `ShadowsocksX-NG/AppDelegate.swift`
- `ShadowsocksX-NG/LaunchAgentUtils.swift`
- `ShadowsocksX-NG/ProxyConfHelper.m`
- `proxy_conf_helper/main.m`

原因很简单：这些代码依赖 macOS 的 AppKit、LaunchAgent、脚本进程和系统代理配置，iOS 上都不是同一套运行模型。

---

**推荐架构**

只保留 3 层：

1. `Shared Core`
   - `SSURLParser`
   - `ServerProfile`
   - `ConnectionConfig`

2. `iOS App`
   - 导入 `ss://`
   - 节点列表
   - 连接/断开
   - 状态展示

3. `Connection Layer`
   - 把解析后的节点配置转换成 iOS 侧实际可用的连接配置
   - 负责启动、停止、上报状态

注意：
这里的难点不是 `ss://` 解析，而是“iOS 上怎么把连接真正跑起来”。因此项目成败点在连接层，不在 UI。

在“纯 Swift”前提下，推荐技术栈收敛为：
- `Swift`
- `Foundation`
- `CryptoKit`
- `Network`
- `NetworkExtension`

不引入：
- Objective-C 桥接代码
- CocoaPods 依赖
- 外部二进制进程拉起方案

---

**最小模块**

建议只做下面 5 个模块：

1. `ServerProfile`
   - 纯 Swift `struct`
   - 字段：
     - `id`
     - `host`
     - `port`
     - `method`
     - `password`
     - `remark`
     - `plugin`
     - `pluginOptions`

2. `SSURLParser`
   - 输入：`String`
   - 输出：`ServerProfile`
   - 职责：
     - 校验 scheme 是否为 `ss`
     - 解析标准格式
     - 兼容已有 legacy 逻辑
     - 解析 fragment 和 `plugin`

3. `ProfileStore`
   - 本地保存节点
   - 先用最简单的 JSON / `UserDefaults`
   - 不做迁移工具

4. `ConnectionConfigBuilder`
   - 把 `ServerProfile` 转成连接层需要的配置对象
   - 不把 UI 和连接参数耦合在一起

5. `ConnectionManager`
   - `connect(profile)`
   - `disconnect()`
   - `status`
   - 最小状态：
     - `idle`
     - `connecting`
     - `connected`
     - `failed`

6. `CipherSupport`
   - 只实现 MVP 必需的 Shadowsocks AEAD 算法
   - 推荐第一版仅支持：
     - `aes-128-gcm`
     - `aes-256-gcm`
     - `chacha20-ietf-poly1305`

不建议第一版支持：
- `cfb`
- `ctr`
- `rc4-md5`
- 其它历史兼容算法

---

**MVP 页面范围**

只需要 3 个页面/区域：

1. 导入页
   - 粘贴 `ss://`
   - 点击解析
   - 预览解析结果
   - 保存

2. 节点列表页
   - 展示节点名、地址、端口
   - 选择当前节点

3. 连接页
   - 一个连接按钮
   - 一个断开按钮
   - 一个状态文案
   - 一块简化日志区域

这版先不要做复杂视觉和交互，UI 只要够干净、够稳定。

---

**最小实现顺序**

推荐按这个顺序推进：

1. 抽 `ss://` 解析
   - 从 `ServerProfile.swift` 提炼纯 `Foundation` 版本
   - 去掉 `Cocoa`、`NSObject`、`@objc`

2. 跑通解析测试
   - 标准 `ss://`
   - 带 fragment
   - 带 `plugin`
   - 非法链接

3. 做本地节点存储
   - 保存
   - 删除
   - 选择当前节点

4. 定义连接配置对象
   - 把解析结果和连接实现隔开

5. 实现纯 Swift 加密与协议封装
   - 优先只覆盖 AEAD
   - 不做 legacy cipher 兼容

6. 接入 iOS 连接层
   - 先验证单节点是否能稳定连通
   - 暂时不要同时做多协议、多插件

7. 最后再接 UI
   - UI 只消费 `ProfileStore` 和 `ConnectionManager`

---

**最小验收标准**

只要满足下面 4 条，就算 MVP 成功：

1. 输入一个合法 `ss://`，可以正确解析出节点字段
2. 节点能保存并在重启后恢复
3. 选择节点后可以触发一次成功连接
4. 用户能看到明确状态：连接中、成功、失败

---

**建议先砍掉的风险点**

为了让第一版尽快落地，建议先限制：

- 只支持标准 Shadowsocks
- 只支持 AEAD
- `plugin` 字段先解析并保存，不承诺第一版全部可连接
- 不做 PAC
- 不做系统级复杂代理切换能力
- 不做导入历史兼容
- 不做桌面端行为对齐

这样可以把第一阶段的目标压缩成：
**“标准 `ss://` 可解析，可保存，可连接，且仅支持纯 Swift 可控范围内的 AEAD 算法。”**

---

**粗略工作量**

如果连接层路线已明确：
- 解析 + 存储：`1~2 天`
- 最小 UI：`1~2 天`
- 连接层接通与稳定：`3~7 天`

如果连接层路线还没验证：
- 先做连接 PoC：`3~7 天`
- PoC 通了再做完整 MVP

所以最稳的推进方式是：
**先验证连接，再补 UI。**

---

**一句话方案**

不要迁移这个 macOS 工程。  
直接新建一个 iOS 项目，只复用 `ss://` 解析思路和节点字段定义，先做“标准 `ss://` 可解析、可保存、可连接”的最小闭环。
