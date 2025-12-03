# Setup MoonBit Action

[![Setup-Moonbit@Dev](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml/badge.svg)](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml)

本 GitHub Action 将为你配置一个 [MoonBit](https://www.moonbitlang.com/) 开发环境。适用于 Github `macOS`、`Ubuntu` 和 `Windows` 工作流运行时镑像。

## 使用

**NOTE**：推荐使用 `hustcer/setup-moonbit@v1.16` 或者 `hustcer/setup-moonbit@v1`，`v1` 始终指向最新的 `1.x` 版本。

### 基础使用

使用 `hustcer/setup-moonbit` 非常简单，只需要按照下面示例即可：

```yaml
steps:
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

| 参数名       | 类型     | 描述                                                                                                                  |
| ------------ | -------- | --------------------------------------------------------------------------------------------------------------------- |
| `version`    | `string` | 可选，合法的 Moonbit 工具链版本，比如：`0.6.33+b989ba000`、`latest`、`pre-release` 或者 `nightly`。默认为 `latest` 或环境变量 `MOONBIT_INSTALL_VERSION` 的值 |
| `setup-core` | `bool`   | 可选，设置为 `true` 则下载并打包 Moonbit Core，`false` 则跳过。默认为 `true`                                                |
| `core-version` | `string` | 可选，合法的 Moonbit Core 版本，比如：`0.6.33+b989ba000`、`latest`、`pre-release` 或者 `nightly`。默认为 `latest` |

## 许可

Licensed under:

- MIT license ([LICENSE](LICENSE) or http://opensource.org/licenses/MIT)
