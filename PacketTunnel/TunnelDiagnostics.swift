import Foundation

/// 隧道侧诊断日志输出；由 PacketTunnelProvider 注入到各组件，
/// 仅记录会话级事件，实现见 SharedCore 的 TunnelDiagnosticsStore。
typealias TunnelDiagnosticsLogging = @Sendable (String) -> Void
