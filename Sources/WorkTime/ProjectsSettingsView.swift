import AppKit
import SwiftUI

struct ProjectsSettingsView: View {
    @ObservedObject var projects: ActivityProjectsModel
    @State private var newProject = ""
    @State private var settingUp = false

    var body: some View {
        SettingsSection("Projects", footer: "A block takes the project of the first rule that matches its repository, website, app or "
                        + "ticket prefix. Click a block in the Activity view to choose a project by hand or add a rule.") {
            ForEach(projects.projects) { project in
                ProjectSettingsRow(project: project, rules: projects.rules.filter { $0.projectID == project.id }, model: projects)
                Divider().padding(.leading, 14)
            }
            HStack {
                TextField("New project", text: $newProject).textFieldStyle(.roundedBorder).onSubmit(addProject)
                Button("Add", action: addProject).disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if let store = projects.store {
                Divider().padding(.leading, 14)
                SettingsRow("Set up projects from your activity", detail: "Suggests projects and rules for the organisations, "
                            + "repositories, ticket prefixes and websites you spent time on.") {
                    Button("Set Up\u{2026}") { settingUp = true }
                }
                .sheet(isPresented: $settingUp, onDismiss: projects.refresh) { ProjectSetupView(store: store) { settingUp = false } }
            }
        }
    }

    private func addProject() {
        projects.add(newProject)
        newProject = ""
    }
}

private struct ProjectSettingsRow: View {
    let project: Project
    let rules: [ProjectRule]
    @ObservedObject var model: ActivityProjectsModel
    @State private var field = RuleField.repo
    @State private var pattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Project.colors, id: \.self) { color in
                        Button { model.setColor(color, of: project) } label: {
                            Label { Text(color) } icon: { Image(nsImage: swatch(color)) }
                        }
                    }
                } label: {
                    Circle().fill(Color(hex: project.color)).frame(width: 12, height: 12)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Colour")
                Text(project.name)
                Spacer()
                Button { model.delete(project) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Delete the project and its rules")
            }
            ForEach(rules) { rule in
                HStack(spacing: 6) {
                    Text("\(rule.field.label): \(rule.pattern)")
                    Spacer()
                    Button { model.deleteRule(rule) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                        .help("Remove this rule")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            }
            HStack(spacing: 6) {
                Picker("Field", selection: $field) {
                    ForEach(RuleField.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                TextField(placeholder, text: $pattern).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add rule", action: add).disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(.leading, 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var placeholder: String {
        switch field {
        case .branch: return "NI/QDLY-*"
        case .owner: return "quiddly-com"
        case .repo: return "finq.api"
        case .host: return "github.com"
        case .app: return "Xcode"
        case .ticket: return "QDLY"
        }
    }

    private func add() {
        model.addRule(field, pattern, to: project)
        pattern = ""
    }

    private func swatch(_ hex: String) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(Color(hex: hex)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
