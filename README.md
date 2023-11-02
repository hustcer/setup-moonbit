# Setup MoonBit Action

[中文说明](README.zh-CN.md)

[![Setup-Moonbit@Dev](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml/badge.svg)](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml)

This GitHub Action will setup a [MoonBit](https://www.moonbitlang.com/) environment for you.

## Usage

### Basic

It's quite simple to use `hustcer/setup-moonbit`, just follow the example below:

```yaml
steps:
  - name: Checkout
    uses: actions/checkout@v4.1.0

  - name: Setup Moonbit
    uses: hustcer/setup-moonbit@v1.0

  - name: Check Moonbit Version
    run: |
        moon version
        moonc -v
        moonrun --version
        moon new hello && cd hello
        moon run main
```

Or, check the [test.yaml](https://github.com/hustcer/setup-moonbit/blob/main/.github/workflows/test.yml) example.

In rare circumstances you might get rate limiting errors, if this happens you can set the `GITHUB_TOKEN` environment variable.

```yaml
- uses: hustcer/setup-moonbit@v1.0
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Inputs

Currently no input required

## License

Licensed under:

- MIT license ([LICENSE](LICENSE) or http://opensource.org/licenses/MIT)
