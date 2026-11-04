import SwiftUI
import Core

struct ProjectSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: WorkbenchStore

    @State private var pendingDelete: Project?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.projects.isEmpty {
                emptyState
            } else {
                List(selection: $store.selectedProjectId) {
                    ForEach(store.projects) { project in
                        ProjectSidebarRow(
                            project: project,
                            laneCount: store.workstations(for: project.id).count
                        )
                        .tag(project.id)
                        .contextMenu {
                            Button("编辑项目") {
                                store.projectFormMode = .edit(project)
                            }
                            Button("工位设置") {
                                store.selectedProjectId = project.id
                                store.showingWorkstationSettings = true
                            }
                            Divider()
                            Button("删除项目…", role: .destructive) {
                                pendingDelete = project
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .confirmationDialog(
            "删除项目「\(pendingDelete?.displayName ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除项目记录", role: .destructive) {
                if let project = pendingDelete {
                    store.deleteProject(project, appState: appState)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只删除项目与工位记录；worktree 目录和已打开的 TRAE 窗口不会被删除。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("项目")
                    .font(.headline)
                Text(store.projects.isEmpty ? "还没有项目" : "\(store.projects.count) 个项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.projectFormMode = .create
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("新建项目")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("还没有项目")
                .font(.subheadline.weight(.medium))
            Text("点击右上角 + 新建")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProjectSidebarRow: View {
    let project: Project
    let laneCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(project.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(project.repoURL.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                TagChip(text: project.modeBadge, color: .secondary)
                Text("\(laneCount) 个工位")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .help(project.repoPath)
    }
}
