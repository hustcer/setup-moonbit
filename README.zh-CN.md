# Setup MoonBit Action

[![Setup-Moonbit@Dev](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml/badge.svg)](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml)

本 GitHub Action 将为你配置一个 [MoonBit](https://www.moonbitlang.com/) 开发环境。适用于 Github `macOS` , `Ubuntu` 和 `Windows` 工作流运行时镜像。

## 使用

### 基础使用

使用 `hustcer/setup-moonbit` 非常简单，只需要按照下面示例即可：

```yaml
steps:
  - name: Checkout
    uses: actions/checkout@v4

  - name: Setup Moonbit
    uses: hustcer/setup-moonbit@v1

  - name: Check Moonbit Version
    run: |
        moon version --all
```

或者也可以参考下本仓库的 [test.yaml](https://github.com/hustcer/setup-moonbit/blob/main/.github/workflows/test.yml) 例子。

在极少数情况下，你可能会看到速率限制之类的错误。如果发生这种情况，你可以通过设置 `GITHUB_TOKEN` 环境变量来避免该问题：

```yaml
- uses: hustcer/setup-moonbit@v1
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### 输入

| 参数名  | 必填    | 描述    | 类型   | 默认值   |
| ---------------- | -------- | --- | ------ | --------- |
| `version` | 否    | 合法的 Moonbit 工具链版本，比如: `0.1.20250108+7a6b9ab0e`, `nightly`, `latest` 或者 `bleeding` |  string | `latest` |
| `setup-core` | 否 | 设置为 `true` 则下载并打包 Moonbit Core, `false` 则忽略 | bool | `true` |

## 许可

Licensed under:

* MIT license ([LICENSE](LICENSE) or http://opensource.org/licenses/MIT)
