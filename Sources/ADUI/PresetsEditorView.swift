import ADModel
import SwiftUI

/// The presets window's content: the list on the left, the selected preset's fields on the right, and
/// Revert and Save at the bottom. Everything it shows and does is `PresetsEditorModel`'s. The app hosts
/// it in a window of its own.
public struct PresetsEditorView: View {
    @Bindable private var model: PresetsEditorModel

    public init(model: PresetsEditorModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.notices, id: \.self) { notice in
                Label(notice, systemImage: "exclamationmark.triangle")
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                Divider()
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    list
                    Divider()
                    listButtons
                }
                .frame(width: 230)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, minHeight: 360)
        .alert(
            model.question?.title ?? "",
            isPresented: Binding(get: { model.question != nil }, set: { if !$0 { model.cancelDelete() } }),
            presenting: model.question
        ) { question in
            Button("Delete", role: .destructive) { model.confirmDelete(question) }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: { question in
            Text(question.message)
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.rows) { row in
                HStack {
                    Text(row.name.isEmpty ? "No name" : row.name)
                        .lineLimit(1)
                    Spacer()
                    if model.problem(of: row.id) != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Needs fixing")
                    }
                }
                .tag(row.id)
            }
        }
    }

    private var listButtons: some View {
        HStack(spacing: 4) {
            Button("Add", systemImage: "plus") { model.add() }
                .help("Add a preset after the selected one")
            Button("Delete", systemImage: "minus") { model.deleteSelected() }
                .disabled(!model.canDelete)
                .help("Delete the selected preset")
            Button("Move Up", systemImage: "chevron.up") { model.moveSelectedUp() }
                .disabled(!model.canMoveUp)
                .help("Move the selected preset up")
            Button("Move Down", systemImage: "chevron.down") { model.moveSelectedDown() }
                .disabled(!model.canMoveDown)
                .help("Move the selected preset down")
            Spacer()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(8)
    }

    @ViewBuilder private var detail: some View {
        if let id = model.selection, model.rows.contains(where: { $0.id == id }) {
            Form {
                TextField("Name", text: field(id, \.name, ""))
                TextField("Looks like", text: field(id, \.lookslike, ""), prompt: Text("1728x1080"))
                Toggle("HiDPI", isOn: field(id, \.hidpi, false))
                TextField("Refresh rate (Hz)", text: field(id, \.hz, ""), prompt: Text("60"))
                LabeledContent("Pixels", value: model.pixels(of: id) ?? "Not a size")
                let users = model.clientNames(of: id)
                if !users.isEmpty {
                    LabeledContent("Used by", value: users.joined(separator: ", "))
                }
                if let problem = model.problem(of: id) {
                    Text(problem)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
        } else {
            Text(model.rows.isEmpty ? "No presets. Click + to add one." : "Select a preset.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if let footnote = model.footnote {
                Text(footnote)
                    .foregroundStyle(model.footnoteNeedsAttention ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Revert") { model.revert() }
                .disabled(!model.hasChanges)
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .disabled(!model.canSave)
        }
        .padding(12)
    }

    /// A field of one preset, found by its id each time, so a field that's still being edited when its
    /// preset is deleted reads the fallback instead of a row that's gone.
    private func field<Value>(
        _ id: PresetsEditorModel.Row.ID,
        _ path: WritableKeyPath<PresetsEditorModel.Row, Value> & Sendable,
        _ fallback: Value
    ) -> Binding<Value> where Value: Sendable {
        Binding(
            get: { model.rows.first { $0.id == id }?[keyPath: path] ?? fallback },
            set: { value in model.update(id) { $0[keyPath: path] = value } }
        )
    }
}
