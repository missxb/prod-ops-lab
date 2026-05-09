# 贡献指南

感谢您对本项目的关注！以下是参与贡献的指南。

## 如何贡献

1. Fork 本仓库
2. 创建功能分支：`git checkout -b feature/your-feature`
3. 提交更改
4. 推送到远程：`git push origin feature/your-feature`
5. 创建 Pull Request

## 开发环境

```bash
make dev-setup    # 安装开发依赖
make lint         # 代码检查
make test         # 运行测试
make build        # 构建项目
```

## 代码规范

### Go 代码
- 遵循 `gofmt` / `goimports` 格式
- 使用 `golangci-lint` 进行静态检查
- 公共函数必须有注释

### 前端代码
- 遵循 ESLint + Prettier 规范
- 使用 Composition API（Vue 3）
- 组件使用 PascalCase 命名

### Helm Charts
- 遵循 Helm 最佳实践
- values.yaml 必须包含注释说明
- 模板文件使用 4 空格缩进

### YAML / 配置文件
- 使用 2 空格缩进
- 行尾无多余空格

## 提交规范

使用 [Conventional Commits](https://www.conventionalcommits.org/) 格式：

```
<type>(<scope>): <description>

[可选正文]

[可选脚注]
```

### 类型说明

| 类型     | 说明         |
| -------- | ------------ |
| feat     | 新功能       |
| fix      | 修复缺陷     |
| docs     | 文档更新     |
| style    | 代码格式调整 |
| refactor | 重构         |
| test     | 测试相关     |
| chore    | 构建/工具    |
| ci       | CI/CD 配置   |
| perf     | 性能优化     |

### 示例

```
feat(monitoring): 新增自定义指标采集器
fix(security): 修复镜像扫描超时问题
docs: 更新快速开始指南
```

## 分支管理

- `main` - 生产分支，受保护
- `develop` - 开发分支
- `feature/*` - 功能分支
- `fix/*` - 修复分支
- `release/*` - 发布分支

## 问题反馈

- 使用 GitHub Issues 提交 Bug 报告
- 使用 GitHub Discussions 进行技术讨论
- 提交 Bug 时请附上环境信息和复现步骤

## 代码审查

所有 PR 需要至少一位维护者审查通过后才能合并。审查关注点：

- 代码质量和可读性
- 测试覆盖率
- 文档更新
- 兼容性影响
