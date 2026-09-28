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

| Input                   | Default                              | Use                                        |
| ----------------------- | ------------------------------------ | ------------------------------------------ |
| `project-id`            | required                             | A.D.S. Games game slug                     |
| `platforms`             | `["WEB", "LINUX", "WINDOWS", "MAC"]` | JSON list of platforms to build            |
| `deploy`                | `true`                               | `false` only checks that the game builds   |
| `version`               | the pushed tag                       | Version to release                         |
| `preset`                | `release`                            | CMake configure and build preset           |
| `output-dir`            | `build/release/target`               | Folder with the game and its assets        |
| `entry`                 | `index.html`                         | Page to serve for web builds               |
| `emscripten-version`    | `6.0.10`                             | Emscripten SDK for web builds              |
| `repository`, `ref`     | the calling repository               | Build another repository, used for testing |
| `manifest`              | `adsgames.json`                      | Leaderboards and achievements manifest     |
| `manifest-environments` | `dev prod`                           | Play environments the manifest syncs to    |

Windows builds use MSYS2 UCRT64 and link statically, so no runtime DLLs need
shipping. Mac builds are not signed or bundled as an `.app`.

## asw Pages workflow

`deploy-asw-pages.yml` builds the web version of an asw game with
Emscripten and deploys it to the game repository's own GitHub Pages. It is
separate from A.D.S. Games releases, useful as a preview of the main branch:

```yaml
name: Deploy GitHub Pages

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

jobs:
  pages:
    uses: adsgames/deploy-to-adsgames/.github/workflows/deploy-asw-pages.yml@v1
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      # Pull requests only check that the web build works
      deploy: ${{ github.event_name == 'push' }}
```

| Input                | Default                | Use                                         |
| -------------------- | ---------------------- | ------------------------------------------- |
| `deploy`             | `true`                 | `false` only checks that the game builds    |
| `preset`             | `release`              | CMake configure and build preset            |
| `output-dir`         | `build/release/target` | Folder with the game and its assets         |
| `emscripten-version` | `6.0.10`               | Emscripten SDK                              |
| `repository`, `ref`  | the calling repository | Build another repository, used for testing  |

The repository must have GitHub Pages set to deploy from GitHub Actions.

## itch.io workflow

`deploy-itch.yml` pushes a release to itch.io with
[butler](https://itch.io/docs/butler/). It does not build: it takes the
`build-<PLATFORM>` artifacts that `release-game.yml` uploads in the same run.
Add it as a job after the release, so releases go to A.D.S. Games first and
then to itch.io:

```yaml
jobs:
  release:
    uses: adsgames/deploy-to-adsgames/.github/workflows/release-game.yml@v1
    # ... as above

  itch:
    needs: release
    if: startsWith(github.ref, 'refs/tags/v')
    uses: adsgames/deploy-to-adsgames/.github/workflows/deploy-itch.yml@v1
    with:
      itch-project: ads-games/mygame
    secrets:
      BUTLER_API_KEY: ${{ secrets.BUTLER_API_KEY }}
```

| Input            | Default                                                                  | Use                                     |
| ---------------- | ------------------------------------------------------------------------ | --------------------------------------- |
| `itch-project`   | required                                                                 | itch.io `user/game`                     |
| `platforms`      | `["WEB", "LINUX", "WINDOWS", "MAC"]`                                     | Platforms to push, all must be built    |
| `channels`       | `{"WEB": "html5", "LINUX": "linux", "WINDOWS": "windows", "MAC": "mac"}` | itch.io channel for each platform       |
| `version`        | the pushed tag, else the commit                                          | Version shown on itch.io                |
| `butler-version` | `15.31.0`                                                                | butler release to push with             |

The `BUTLER_API_KEY` secret is an itch.io API key. On itch.io, mark the web
upload as "played in the browser" once after its first push.

## Leaderboards and achievements

A game defines its leaderboards and achievements in `adsgames.json` at the root
of its repository. The release workflow syncs it to the
[play](https://github.com/AdsGames/play) service before the builds deploy:

- **Release tags** sync to dev (`play.beta.adsgames.net`) and prod
  (`play.adsgames.net`). If play rejects the manifest, the release stops before
  any build ships.
- **Pull requests** (`deploy: false`) run a dry run. It checks the manifest
  against the live data and lists what a release would archive, without saving
  anything. It is skipped with a warning when the API key is not available,
  for example on pull requests from forks.
- Repositories without `adsgames.json` skip the step.

```json
{
  "$schema": "https://raw.githubusercontent.com/AdsGames/deploy-to-adsgames/v1/manifest/schema.json",
  "leaderboards": [
    {
      "key": "level-1",
      "title": "Level 1",
      "order": "asc",
      "format": "time_ms",
      "minValue": 1000
    }
  ],
  "achievements": [
    {
      "key": "no-deaths",
      "title": "Untouchable",
      "description": "Finish a level without dying",
      "icon": "assets/achievements/no-deaths.png",
      "points": 25
    }
  ]
}
```

The `$schema` line gives editors completion and checks, see
[manifest/schema.json](manifest/schema.json) for every field. Icons are paths
relative to the manifest. They are uploaded to the game bucket under a content
hash, so a changed icon gets a new URL.

The manifest is the full set of definitions. Anything left out is **archived**:
hidden, but its scores and unlocks are kept, and it is restored if you add it
back. The run lists archived keys as warnings.

Rules:

- Never rename or reuse a `key`. Scores and unlocks are stored against it.
  Change the `title` instead.
- A leaderboard's `order` can not change once it has scores. Use a new key.

To sync without a release, for example to try new achievements on dev, add a
workflow that calls `sync-manifest.yml`:

```yaml
name: Sync Manifest

on:
  workflow_dispatch:

jobs:
  manifest:
    uses: adsgames/deploy-to-adsgames/.github/workflows/sync-manifest.yml@v1
    permissions:
      id-token: write
      contents: read
    with:
      project-id: mygame
      environments: dev
    secrets:
      ADSGAMES_API_KEY: ${{ secrets.ADSGAMES_API_KEY }}
```

Other workflows can use the action directly:
`adsgames/deploy-to-adsgames/manifest@v1` with `project-id`, `api-key`, and
optionally `manifest`, `environments` and `dry-run`.

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
