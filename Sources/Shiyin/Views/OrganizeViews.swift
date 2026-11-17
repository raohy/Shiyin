import SwiftUI

// MARK: - 文件夹自动归类（R98、design §72）

/// 文件夹右键「自动加入的条件…」
struct FolderRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: String
    @State private var keywords = ""
    @State private var people: Set<Int64> = []
    @State private var templateId: String?
    @State private var applyNow = false
    @State private var existing = false

    private var rule: FolderRule {
        FolderRule(folder: folder, keywords: GlossaryInput.split(keywords), people: people.sorted(), templateId: templateId)
    }

    var body: some View {
        let matching = (try? model.db.meetingsMatching(rule).count) ?? 0
        VStack(alignment: .leading, spacing: 16) {
            // 同其他弹窗的样子（R106、design §80）
            SheetHeader(title: String(localized: "「\(folder)」自动加入的条件"),
                        subtitle: String(localized: "符合任一个条件的新会议，会自动放进这个文件夹。已经在别的文件夹的会议不会移动。"))
            VStack(alignment: .leading, spacing: 6) {
                SheetFieldLabel(String(localized: "标题包含"))
                SheetTextField(placeholder: String(localized: "例如：周会、sync（任一个词）"), text: $keywords)
            }
            if !model.peopleOverview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SheetFieldLabel(String(localized: "这些人都参加"))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.peopleOverview) { person in
                                Toggle(person.isMe ? String(localized: "\(person.name)（我）") : person.name, isOn: Binding(
                                    get: { people.contains(person.id) },
                                    set: { if $0 { people.insert(person.id) } else { people.remove(person.id) } }))
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
                    .sheetFieldBox()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SheetFieldLabel(String(localized: "用这个模板"))
                SheetMenuField(options: [(String?.none, String(localized: "不限"))] + model.templates.map { (Optional($0.id), $0.displayName) },
                               selection: $templateId)
            }
            Toggle(String(localized: "现在不在文件夹里的会议也套用（\(matching) 场）"), isOn: $applyNow)
                .toggleStyle(.checkbox)
                .disabled(matching == 0 || rule.isEmpty)
            HStack(spacing: 10) {
                if existing {
                    Button("移除条件") {
                        model.saveFolderRule(FolderRule(folder: folder), applyNow: false)
                        dismiss()
                    }
                    .buttonStyle(SheetPillButtonStyle(.secondary))
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(SheetPillButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    model.saveFolderRule(rule, applyNow: applyNow && matching > 0)
                    dismiss()
                }
                .buttonStyle(SheetPillButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheetChrome(width: 480)
        .onAppear {
            guard let rule = model.folderRule(folder) else { return }
            existing = true
            keywords = rule.keywords.joined(separator: MeetingLanguage.ui(zh: "、", en: ", "))
            people = Set(rule.people)
            templateId = rule.templateId
        }
    }
}

/// 记录标签页顶端：这场很像某个文件夹里的会议（R98.3）
struct FolderSuggestionBanner: View {
    @Environment(AppModel.self) private var model
    let meetingId: Int64
    let suggestion: FolderSuggestion

    var body: some View {
        HStack(spacing: 10) {
            Label(model.folderSuggestionText(suggestion), systemImage: "folder.badge.plus")
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("不用") { model.dismissFolderSuggestion(meetingId) }
            Button("放进去") { model.acceptFolderSuggestion(meetingId, folder: suggestion.folder) }
                .buttonStyle(.borderedProminent)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.celadon.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
