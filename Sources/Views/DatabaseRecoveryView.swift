import SwiftUI

struct DatabaseRecoveryView: View {
    let errorMessage: String
    let onRetry: () -> Void
    let onRecover: () -> Void
    let canRecoverFromLegacy: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.secondary)

            Text("数据库暂时无法打开")
                .font(.title2.weight(.semibold))

            Text("itchPocket 没有删除或重建原始数据库。你可以先重试；如果问题持续存在，请保留应用数据并联系开发者，不要卸载应用。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("错误详情")
                    .font(.headline)
                Text(errorMessage)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))

            Button(action: onRetry) {
                Label("重新尝试打开数据库", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if canRecoverFromLegacy {
                Text("如果 V2 数据库损坏，可以将它完整隔离保留，再从原始数据库重新迁移。此操作不会删除原始数据库。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(role: .destructive, action: onRecover) {
                    Label("保留问题数据库并从旧库恢复", systemImage: "externaldrive.badge.arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
