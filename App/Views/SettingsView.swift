import QapiaCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Templates de resumo",
                subtitle: "Personalize como o QAP.ia organiza cada tipo de reunião."
            ) {
                StatusIndicator(
                    title: "\(viewModel.templates.count) templates",
                    color: QapiaColors.accent
                )
            }

            calendarCard

            SurfaceCard {
                HStack(alignment: .top, spacing: 24) {
                    templateList
                        .frame(width: 210)

                    Divider()

                    templateEditor
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 470)
            }

            PrivacyNote(text: "Templates e preferências permanecem somente neste Mac")
        }
    }

    private var calendarCard: some View {
        SurfaceCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(QapiaColors.accent.opacity(0.11))
                        .frame(width: 46, height: 46)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(QapiaColors.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Google Calendar")
                        .font(.system(size: 14, weight: .semibold))
                    Text(calendarSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let message = viewModel.calendarStatusMessage {
                        Text(message)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(viewModel.googleAccount == nil ? QapiaColors.paused : QapiaColors.success)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 12)

                if viewModel.isCalendarLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if viewModel.googleAccount != nil {
                    QapiaActionButton(
                        title: "Atualizar",
                        kind: .secondary,
                        systemImage: "arrow.clockwise",
                        action: viewModel.refreshGoogleCalendar
                    )
                    Button("Desconectar", action: viewModel.disconnectGoogleCalendar)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    QapiaActionButton(
                        title: "Conectar Google",
                        kind: .primary,
                        systemImage: "person.crop.circle.badge.plus",
                        action: viewModel.connectGoogleCalendar
                    )
                    .disabled(!viewModel.isGoogleCalendarConfigured)
                }
            }
        }
    }

    private var calendarSubtitle: String {
        if let account = viewModel.googleAccount {
            return "\(account.email) · acesso somente leitura · lembretes 10 min antes"
        }
        if viewModel.isGoogleCalendarConfigured {
            return "Conecte sua conta para sugerir gravações e usar título e participantes da agenda."
        }
        return "Configure o Client ID do Google no pacote para habilitar a conexão."
    }

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SEUS TEMPLATES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                Spacer()
                Button(action: viewModel.beginCreatingTemplate) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(QapiaColors.surfaceHover)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Criar template")
                .accessibilityLabel("Criar template")
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.templates) { template in
                        TemplateManagerRow(
                            template: template,
                            isSelected: viewModel.editingTemplateID == template.id
                        ) {
                            viewModel.selectTemplateForEditing(template.id)
                        }
                    }
                }
            }

            QapiaActionButton(
                title: "Novo template",
                kind: .secondary,
                systemImage: "plus",
                action: viewModel.beginCreatingTemplate
            )
        }
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.editingTemplate == nil ? "Novo template" : "Editar template")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.25)
                    Text(editorSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.editingTemplate?.isBuiltIn == true {
                    Label("Padrão", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(QapiaColors.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(QapiaColors.accent.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            TemplateEditorField(title: "Nome", help: "Até 60 caracteres") {
                TextField("Ex.: Retrospectiva", text: $viewModel.templateNameDraft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(QapiaColors.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(QapiaColors.divider, lineWidth: 1)
                    }
            }

            TemplateEditorField(
                title: "Instruções",
                help: "Oriente o foco e o nível de detalhe do resumo"
            ) {
                TextEditor(text: $viewModel.templateInstructionsDraft)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 92)
                    .background(QapiaColors.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(QapiaColors.divider, lineWidth: 1)
                    }
            }

            TemplateEditorField(
                title: "Estrutura",
                help: "Uma seção por linha, na ordem em que deve aparecer"
            ) {
                TextEditor(text: $viewModel.templateSectionsDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 126)
                    .background(QapiaColors.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(QapiaColors.divider, lineWidth: 1)
                    }
            }

            if let message = viewModel.templateEditorMessage {
                Label(
                    message,
                    systemImage: viewModel.templateEditorSaved ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(viewModel.templateEditorSaved ? QapiaColors.success : QapiaColors.recording)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if viewModel.canDeleteEditingTemplate {
                    Button(role: .destructive, action: viewModel.deleteEditingTemplate) {
                        Label("Excluir", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(QapiaColors.recording)
                }

                Spacer()

                if viewModel.editingTemplate != nil {
                    QapiaActionButton(
                        title: "Duplicar",
                        kind: .secondary,
                        systemImage: "doc.on.doc",
                        action: viewModel.duplicateEditingTemplate
                    )
                }
                QapiaActionButton(
                    title: "Salvar",
                    kind: .primary,
                    systemImage: "checkmark",
                    action: viewModel.saveTemplateDraft
                )
            }
        }
    }

    private var editorSubtitle: String {
        if let template = viewModel.editingTemplate {
            return template.isBuiltIn
                ? "Você pode personalizar este modelo padrão; ele não pode ser excluído."
                : "Este template foi criado por você e pode ser editado ou excluído."
        }
        return "Defina um nome, as instruções e a estrutura do resumo."
    }
}

private struct TemplateManagerRow: View {
    let template: SummaryTemplate
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: template.isBuiltIn ? "doc.text.fill" : "doc.badge.gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? QapiaColors.accent : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(template.sections.count) seções")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                if template.isBuiltIn {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(isSelected || isHovering ? QapiaColors.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

private struct TemplateEditorField<Content: View>: View {
    let title: String
    let help: String
    private let content: Content

    init(title: String, help: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(help)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            content
        }
    }
}
