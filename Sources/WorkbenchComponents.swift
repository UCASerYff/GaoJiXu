import SwiftUI

struct WorkbenchPageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: () -> Accessory

    init(title: String, subtitle: String = "", @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 27, weight: .bold, design: .rounded))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.top, 4)
    }
}

extension WorkbenchPageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String = "") {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct WorkbenchCard<Content: View>: View {
    let title: String?
    let symbol: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, symbol: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(SavingsTheme.accent) }
                    Text(title).font(.headline)
                    Spacer()
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .savingsPanel(cornerRadius: 17)
    }
}

struct WorkbenchStatusPill: View {
    let text: String
    var color: Color = SavingsTheme.accent
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
    }
}

struct WorkbenchEditorScaffold<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    init(title: String, subtitle: String = "", @ViewBuilder content: @escaping () -> Content, @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchPageHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(22)
            }
            Divider().opacity(0.6)
            HStack(spacing: 12) {
                Spacer()
                actions()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.bar)
        }
        .background(SavingsTheme.editorCanvas)
    }
}

struct WorkbenchFormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.headline)
            content()
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SavingsTheme.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.primary.opacity(0.065)))
    }
}
