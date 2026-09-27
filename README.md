# Deploy to A.D.S. Games

Deploy action for releasing a game to A.D.S. Games.

## Inputs

project-id

> Name or game to deploy (i.e. brickbreaker)

version

> (optional) Version of the game to deploy (i.e. v1.0.0). Defaults to the pushed
> tag, else `git describe --tags --always`.

platform

> Platform of release (one of WINDOWS, LINUX, MAC or WEB)

build-dir

> Directory to deploy (i.e. ./dist)

api-key

> A.D.S. Games API key, usually `${{ secrets.ADSGAMES_API_KEY }}`

entry

> Index file to serve (web builds only) (i.e. index.html)

workload-identity-provider

> (optional) GitHub OIDC workload identity provider resource name. Defaults to the AdsGames provider.

service-account

> (optional) Service account to impersonate for bucket uploads. Defaults to the AdsGames games-deploy SA.

## Output

Web builds are uploaded to `games/<project-id>/<version>/` and served from
`entry`. Other platforms are zipped to
`games/<project-id>/<project-id>-<version>-<platform>.zip`, so each platform of a
release gets its own download.

## Release workflow

Games built with asw and CMake presets can use the reusable workflow instead of
writing their own jobs. It builds each platform on its own OS and deploys every
build from Linux:

```yaml
name: Release

on:
  push:
    tags:
      - v*

jobs:
  release:
    uses: adsgames/deploy-to-adsgames/.github/workflows/release-game.yml@v1
    permissions:
      id-token: write
      contents: read
    with:
      project-id: mygame
    secrets:
      ADSGAMES_API_KEY: ${{ secrets.ADSGAMES_API_KEY }}
```

| Input                | Default                                 | Use                                        |
| -------------------- | --------------------------------------- | ------------------------------------------ |
| `project-id`         | required                                | A.D.S. Games game slug                     |
| `platforms`          | `["WEB", "LINUX", "WINDOWS", "MAC"]`    | JSON list of platforms to build            |
| `deploy`             | `true`                                  | `false` only checks that the game builds   |
| `version`            | the pushed tag                          | Version to release                         |
| `preset`             | `release`                               | CMake configure and build preset           |
| `output-dir`         | `build/release/target`                  | Folder with the game and its assets        |
| `entry`              | `index.html`                            | Page to serve for web builds               |
| `emscripten-version` | `4.0.6`                                 | Emscripten SDK for web builds              |
| `repository`, `ref`  | the calling repository                  | Build another repository, used for testing |

Windows builds use MSYS2 UCRT64 and link statically, so no runtime DLLs need
shipping. Mac builds are not signed or bundled as an `.app`.

## Runners

The action runs on **Linux runners only**: it needs `zip`, `jq` and `gcloud`,
which are not on every Windows and macOS runner. Build each platform on its own
OS, pass the build to an `ubuntu` job as an artifact, and deploy from there:

```yaml
jobs:
  build:
    strategy:
      matrix:
        include:
          - platform: WINDOWS
            os: windows-latest
          - platform: MAC
            os: macos-latest
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v7
      # ... build into build/release/target ...
      - uses: actions/upload-artifact@v7
        with:
          name: build-${{ matrix.platform }}
          path: build/release/target/

  deploy:
    needs: build
    strategy:
      matrix:
        platform: [WINDOWS, MAC]
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/download-artifact@v8
        with:
          name: build-${{ matrix.platform }}
          path: build
      - uses: adsgames/deploy-to-adsgames@v1
        with:
          project-id: mygame
          platform: ${{ matrix.platform }}
          build-dir: build
          api-key: ${{ secrets.ADSGAMES_API_KEY }}
```

`actions/upload-artifact` drops file permissions. Pack the build with `tar`
before uploading if executables must keep their executable bit.

## Authentication

Uploads authenticate to Google Cloud Storage using GitHub OIDC (Workload
Identity Federation) — no long-lived keys. Calling workflows must grant the
`id-token` permission:

```yaml
permissions:
  id-token: write
  contents: read
```

Any repository owned by the `AdsGames` GitHub org is authorized to impersonate
the deploy service account.
