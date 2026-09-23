import SwiftUI
import AppKit

struct InstallerView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false
    private let orange = Color(red: 0.87, green: 0.35, blue: 0.17)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(orange.gradient, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("DropInstall").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("选好 DMG，剩下的交给它。").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("打开 → 安装 → 弹出")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(9)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }

            VStack(spacing: 10) {
                Image(systemName: targeted ? "arrow.down.circle.fill" : "square.and.arrow.down")
                    .font(.system(size: 29, weight: .light)).foregroundStyle(orange)
                Text(targeted ? "松开，加入安装队列" : "把 DMG 或 ISO 拖到这里")
                    .font(.system(size: 17, weight: .semibold))
                Text("支持批量添加 · ISO 自动改名为 DMG · Finder 服务可直接安装")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("选择映像…", action: model.chooseFiles).controlSize(.large)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22)
            .background(orange.opacity(targeted ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(orange.opacity(targeted ? 0.8 : 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return urls.contains(where: ImageInput.accepts)
            } isTargeted: { targeted = $0 }

            HStack {
                Label("安装位置", systemImage: "folder").font(.system(size: 12, weight: .medium))
                Picker("安装位置", selection: $model.userOnly) {
                    Text("所有用户 /Applications").tag(false)
                    Text("仅我使用 ~/Applications").tag(true)
                }
                .labelsHidden().frame(width: 240).disabled(model.busy || !model.conflicts.isEmpty)
                Spacer()
                Button("查找规则…") { model.showRules = true }
                    .disabled(model.busy)
                Button { NSWorkspace.shared.open(model.destination) } label: {
                    Image(systemName: "arrow.up.forward.square")
                }.help("在 Finder 中打开安装位置")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("安装队列").font(.system(size: 14, weight: .semibold))
                    Text("\(model.jobs.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if !model.jobs.isEmpty {
                        Button("清空列表") { model.jobs.removeAll() }
                            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.busy || !model.conflicts.isEmpty)
                    }
                }
                if model.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 25)).foregroundStyle(.tertiary)
                        Text("不用一个个打开，也不用再拖进应用程序。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.jobs) { job in jobRow(job) }
                        }
                    }
                }
            }.frame(maxHeight: .infinity)

            if let message = model.inputMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(orange)
            }

            Divider()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.busy ? "已处理 \(model.finishedCount) / \(model.jobs.count) 个 DMG" : "批量安装，少点几下。")
                        .font(.system(size: 12, weight: .semibold))
                    Text("重名先待定 · 成功后 DMG 移入废纸篓")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy {
                    Button(model.stopRequested ? "当前完成后停止" : "停止队列") { model.stopRequested = true }
                        .disabled(model.stopRequested).controlSize(.large)
                } else {
                    if !model.conflicts.isEmpty {
                        Button("处理 \(model.conflicts.count) 个重名", action: model.requestDecision)
                            .controlSize(.large)
                    }
                    Button(model.pendingCount > 0 ? "安装 \(model.pendingCount) 个 DMG" : "开始安装", action: model.start)
                        .buttonStyle(.borderedProminent).tint(orange).controlSize(.large)
                        .disabled(model.pendingCount == 0)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 700, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showConflictSheet) { conflictSheet }
        .sheet(isPresented: $model.showRules) {
            RulesEditor(rules: model.searchRules, onSave: model.saveRules) { model.showRules = false }
        }
    }

    private var conflictSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("是否批量覆盖 \(model.conflicts.count) 个重名应用？", systemImage: "square.on.square")
                .font(.system(size: 20, weight: .semibold))
            Text("以下应用重名，原应用尚未更改。确认后才会复制新版并覆盖，旧版移入废纸篓；正在运行的应用会继续待定。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.conflicts) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.conflict.name).font(.system(size: 14, weight: .medium))
                            Text("来自 \(item.imageName)").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("覆盖 \(item.conflict.target.path)").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }.frame(minHeight: 100, maxHeight: 280)
            HStack {
                Button("稍后决定") { model.showConflictSheet = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("全部保留现有版本", action: model.keepExisting)
                Button("批量覆盖", action: model.replaceAll)
                    .buttonStyle(.borderedProminent).tint(orange)
            }.controlSize(.large)
        }.padding(26).frame(width: 590)
    }

    private func jobRow(_ job: InstallJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.fill").font(.system(size: 24)).foregroundStyle(.secondary).padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).help(job.url.path)
                if let original = job.originalURL {
                    Text("已自动改名：\(original.lastPathComponent) → \(job.url.lastPathComponent)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if job.state == .running { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                    if job.state == .installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    if job.state == .attention { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(orange) }
                    if job.state == .pending { Image(systemName: "pause.circle.fill").foregroundStyle(orange) }
                    Text(job.status)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if let report = job.report {
                    Text(report.detail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !model.busy {
                if job.state == .attention {
                    Button("重试") { model.retry(job.id) }.controlSize(.small)
                }
                Button { model.jobs.removeAll { $0.id == job.id } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("移出列表")
                    .disabled(job.report?.pending.isEmpty == false)
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
