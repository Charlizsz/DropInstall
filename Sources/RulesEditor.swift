import SwiftUI

struct RulesEditor: View {
    @State private var rules: [ImageSearchRule]
    let onSave: ([ImageSearchRule]) -> Void
    let onCancel: () -> Void

    init(rules: [ImageSearchRule], onSave: @escaping ([ImageSearchRule]) -> Void, onCancel: @escaping () -> Void) {
        _rules = State(initialValue: rules)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("内层 DMG 查找规则", systemImage: "line.3.horizontal.decrease.circle")
                .font(.system(size: 20, weight: .semibold))
            Text("打开 DMG 后，在匹配的文件夹里寻找内层 DMG，再继续安装。支持多条规则，不区分大小写；* 匹配任意字符，? 匹配单个字符。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("启用").frame(width: 36)
                Text("文件夹名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("DMG 文件名称").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 28, height: 1)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($rules) { $rule in
                        HStack(spacing: 10) {
                            Toggle("启用规则", isOn: $rule.enabled).labelsHidden().toggleStyle(.checkbox).frame(width: 36)
                            TextField("例如 Manual Install", text: $rule.folderPattern).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("文件夹名称规则")
                            TextField("例如 *.dmg", text: $rule.imagePattern).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("DMG 文件名称规则")
                            Button { rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).frame(width: 28).help("删除这条规则")
                        }
                    }
                    if rules.isEmpty {
                        Text("没有启用内层查找规则，仍会安装普通 DMG 内的应用。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }.frame(minHeight: 80, maxHeight: 260)
            HStack {
                Button("添加规则") { rules.append(ImageSearchRule(folderPattern: "", imagePattern: "*.dmg")) }
                Button("恢复默认") { rules = ImageSearchRule.defaults }
                Spacer()
            }
            Text(rules.allSatisfy(\.isValid) ? "例如：Manual Install → *.dmg。多条规则命中同一文件时只处理一次，最多打开 3 层、16 个映像。" : "请填写文件夹和 DMG 名称规则；使用名称而不是完整路径（不含 /，最多 128 个字符）。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { onSave(rules) }.buttonStyle(.borderedProminent)
                    .disabled(!rules.allSatisfy(\.isValid)).keyboardShortcut(.defaultAction)
            }.controlSize(.large)
        }.padding(26).frame(width: 600)
    }
}
