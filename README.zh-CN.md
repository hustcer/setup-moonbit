# Setup MoonBit Action

[![Setup-Moonbit@Dev](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml/badge.svg)](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml)

本 GitHub Action 将为你配置一个 [MoonBit](https://www.moonbitlang.com/) 开发环境。

## 使用

### 基础使用

使用 `hustcer/setup-moonbit` 非常简单，只需要按照下面示例即可：

```yaml
steps:
  - name: Checkout
    uses: actions/checkout@v4.1.0

  - name: Setup Moonbit
    uses: hustcer/setup-moonbit@v1.2

  - name: Check Moonbit Version
    run: |
        moon version
        moonc -v
        moonrun --version
        moon new hello && cd hello
        moon run main
```

或者也可以参考下本仓库的 [test.yaml](https://github.com/hustcer/setup-moonbit/blob/main/.github/workflows/test.yml) 例子。

在极少数情况下，你可能会看到速率限制之类的错误。如果发生这种情况，你可以通过设置 `GITHUB_TOKEN` 环境变量来避免该问题：

```yaml
- uses: hustcer/setup-moonbit@v1.2
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### 输入

目前本 Action 不需要任何输入

## 许可

Licensed under:

- MIT license ([LICENSE](LICENSE) or http://opensource.org/licenses/MIT)
