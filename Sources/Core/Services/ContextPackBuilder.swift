import Foundation

/// 生成开工上下文包：只包含项目元数据、工位信息和用户填写的项目记忆。
///
/// 不包含账号凭据、完整对话、积分估算或源码内容。
public struct ContextPackBuilder: Sendable {
    public init() {}

    public static func build(
        project: Project,
        workstation: Workstation,
        account: Account,
        worktreeURL: URL,
        task: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("# 工作台开工上下文")
        lines.append("")
        lines.append("你正在「\(project.displayName)」项目的工作台工位中工作。")
        lines.append("")
        lines.append("## 项目")
        lines.append("- 仓库：\(project.repoPath)")
        lines.append("- 基线分支：\(project.baselineBranch)")
        lines.append("- 编排模式：\(project.orchestrationMode.displayName)")
        lines.append("")
        lines.append("## 当前工位")
        lines.append("- 工位：\(workstation.displayName)")
        lines.append("- 角色：\(workstation.roleDisplay)")
        lines.append("- 账号：\(account.displayName)")
        lines.append("- 分支：\(workstation.branchName ?? "未生成")")
        lines.append("- worktree：\(worktreeURL.path)")
        lines.append("")

        if let build = project.buildCommand, !build.isEmpty {
            lines.append("- 构建命令：`\(build)`")
        }
        if let test = project.testCommand, !test.isEmpty {
            lines.append("- 测试命令：`\(test)`")
        }
        if let setup = project.setupHint, !setup.isEmpty {
            lines.append("- 初始化提示：`\(setup)`")
        }
        lines.append("")

        if let memory = project.projectMemory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !memory.isEmpty {
            lines.append("## 项目记忆")
            lines.append(memory)
            lines.append("")
        }

        if let task = task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            lines.append("## 当前任务")
            lines.append(task)
            lines.append("")
        }

        lines.append("## 工作约束")
        lines.append("- 只在当前 worktree 内修改文件，不要修改原始仓库目录或其他工位目录。")
        lines.append("- 不要切换到基线分支，也不要直接向基线分支提交。")
        lines.append("- 不要自动执行 commit、push、merge、rebase；由用户确认后再操作。")
        lines.append("- 不要读取或输出账号密码、Token、Cookie、手机号等敏感信息。")
        lines.append("- 完成阶段性工作后，列出修改文件、验证命令和未决问题。")

        return lines.joined(separator: "\n")
    }
}
