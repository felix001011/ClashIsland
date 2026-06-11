# ClashIsland 🏝️

> A floating "dynamic island" desktop widget for Clash Verge Rev on Windows — real-time speed, node switching, and disconnection alerts. Zero dependencies, pure PowerShell + WPF.

一个为 [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) 设计的 Windows 桌面悬浮岛，实时显示代理状态，类似 iPhone 的"灵动岛"：

```
● 英国 03  |  ↓ 1.2 MB/s  ↑ 56 KB/s  44连
```

**零依赖、零安装**——纯 PowerShell + WPF 实现，Windows 10/11 自带运行环境，下载即用。

## ✨ 功能

- **实时状态**：当前节点、下载/上传速度、活动连接数，每秒刷新
- **灵动岛效果**：平时缩进屏幕顶部只露一条小边，鼠标碰到平滑弹出，离开立即缩回，不挡内容
- **悬停切换线路**：鼠标停留 2 秒弹出节点菜单，显示各节点**实时延迟**（绿/黄/红三色），滚动选择、点击切换
- **一键测速**：打开菜单自动触发全节点并发测速（约 3 秒），也可手动点"测速"刷新
- **断网警告**：每 10 秒通过当前节点做真实连通性测试，断网时强制弹出，整岛暗红弥散呼吸 + 红色光晕扩散，恢复自动消退
- **贴心细节**：拖动换位置（自动记住）、双击打开 Clash Verge 主界面、右键菜单、单实例保护

## 📋 环境要求

- Windows 10 / 11
- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) v2.x（通过其命名管道 API `\\.\pipe\verge-mihomo` 通信）
- 无需安装 Python / Node / .NET SDK，系统自带的 PowerShell 5.1 即可

## 🚀 使用

1. 下载本仓库（Code → Download ZIP，或 `git clone`），解压到任意文件夹
2. 双击 **`start.vbs`** 启动（不会弹黑窗口）
3. 悬浮岛出现在屏幕顶部正中，几秒后自动缩进边缘

| 操作 | 效果 |
|------|------|
| 鼠标碰到顶部小边 | 弹出悬浮岛 |
| 悬停 2 秒 | 弹出线路菜单（含实时延迟），左键点击切换 |
| 按住拖动 | 移动位置（自动记住；拖离顶部则不再自动躲藏） |
| 双击 | 打开 Clash Verge 主界面 |
| 右键 | 菜单：打开主界面 / 切换线路 / 重置位置 / 退出 |

### 开机自启

- 启用：双击 `autostart-on.vbs`
- 取消：双击 `autostart-off.vbs`

### 延迟颜色

| 颜色 | 含义 |
|------|------|
| 🟢 绿 | < 200ms |
| 🟡 黄 | 200 ~ 500ms |
| 🔴 红 | > 500ms / 超时 |
| `--` | 尚未测速 |

## 🔧 工作原理

Clash Verge Rev 的内核 (mihomo) 在本机暴露一个命名管道 RESTful API。ClashIsland 每秒通过它读取流量统计与节点信息，菜单切换调用 `PUT /proxies/GLOBAL`，断网检测调用真实连通性测试接口。**不修改任何 Clash 配置，不影响代理本身。**

管道名和 API 密钥从 Clash Verge 的运行时配置 (`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml`) 自动读取，无需手动配置。

界面为 WPF 无边框置顶窗口，数据采集在两个后台 runspace 线程中进行，不阻塞 UI。

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `ClashIsland.ps1` | 主程序（单文件，含全部逻辑） |
| `start.vbs` | 无窗口启动器 |
| `autostart-on.vbs` / `autostart-off.vbs` | 开机自启开关 |
| `state.json` | 窗口位置记忆（运行时生成） |
| `ClashIsland.log` | 运行日志（运行时生成，排查问题看这里） |

## ❓ 常见问题

**悬浮岛显示"Clash 未运行"？**
确认 Clash Verge Rev 正在运行。本工具依赖其命名管道 API。

**如何完全退出？**
右键悬浮岛 → 退出悬浮岛。

**支持原版 Clash Verge / 其他 Clash 客户端吗？**
目前只适配 Clash Verge Rev 的命名管道模式。如果你的客户端开启了 TCP 外部控制器 (external-controller)，欢迎提 Issue / PR。

**命令行诊断**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ClashIsland.ps1 -Diag
```

## 🔗 相关项目

- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) — 本工具适配的 Clash 桌面客户端（GUI）
- [mihomo](https://github.com/MetaCubeX/mihomo)（原 Clash.Meta）— Clash Verge Rev 内置的代理内核，本工具通过它的 RESTful API 读取状态、切换节点
- 原版 [Clash](https://github.com/Dreamacro/clash) 仓库已于 2023 年被作者移除，mihomo 是目前社区维护的主流内核

## 📄 License

[MIT](LICENSE)
