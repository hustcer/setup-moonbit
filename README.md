# Setup MoonBit Action

[中文说明](README.zh-CN.md)

[![Setup-Moonbit@Dev](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml/badge.svg)](https://github.com/hustcer/setup-moonbit/actions/workflows/basic.yml)
[![Daily Checking](https://github.com/hustcer/setup-moonbit/actions/workflows/daily.yml/badge.svg)](https://github.com/hustcer/setup-moonbit/actions/workflows/daily.yml)

This GitHub Action will setup a [MoonBit](https://www.moonbitlang.com/) environment for you. It should work on Github `macOS` , `Ubuntu` , and `Windows` runners.

## Usage

**NOTE**: It's recommended to use `hustcer/setup-moonbit@v1.12` or `hustcer/setup-moonbit@v1`. The `v1` tag will always point to the latest `1.x` version.

### Basic

It's quite simple to use `hustcer/setup-moonbit` , just follow the example below:

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

Or, check the [test.yaml](https://github.com/hustcer/setup-moonbit/blob/main/.github/workflows/test.yml) example.

In rare circumstances you might get rate limiting errors, if this happens you can set the `GITHUB_TOKEN` environment variable.

```yaml
- uses: hustcer/setup-moonbit@v1
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Inputs

| Name         | Type     | Description                                                                                                                                       |
| ------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `version`    | `string` | Optional, A valid moonbit tool chain version, such as `0.1.20250317+3e0c28331`, `nightly`, `latest`, etc. or even `bleeding`, default to `latest` |
| `setup-core` | `bool`   | Optional, Set to `true` to download and bundle Moonbit Core, `false` to ignore it, default to `true`                                              |
| `core-version` | `string` | Optional, A valid moonbit core version, such as `0.1.20250317+3e0c28331`, `nightly`, `latest`, `bleeding` etc. Default to `latest` |

## License

Licensed under:

- MIT license ([LICENSE](LICENSE) or http://opensource.org/licenses/MIT)
