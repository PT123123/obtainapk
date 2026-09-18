<!-- <div align="center"><a href="https://github.com/Safouene1/support-palestine-banner/blob/master/Markdown-pages/Support.md"><img src="https://raw.githubusercontent.com/Safouene1/support-palestine-banner/master/banner-support.svg" alt="Support Palestine" style="width: 100%;"></a></div> -->
<!-- Banner temporarily removed for reasons, will re-enable or replace shortly -->

# ![Obtainium Icon](./assets/graphics/icon_small.png) Obtainium

Get Android app updates straight from the source.

Obtainium allows you to install and update apps directly from their releases pages, and receive notifications when new releases are made available.

## ObtainAPK (this fork)

This is a customized fork of Obtainium published as **ObtainAPK** (package ID `com.pt123123.obtainapk`), tailored for users in regions where direct access to GitHub is unstable. Changes on top of upstream:

- **Mirror download fallback**: when the direct HTTPS download fails, the app automatically retries the same APK through configurable acceleration mirrors (`ghfast.top`, `gh-proxy.com`, `mirror.ghproxy.com` by default). Pick a strategy under *Settings → Download strategy*: `Direct first, fall back to mirrors` (default), `Mirrors first`, or `Direct only`. Note: GitHub Release assets cannot be downloaded over SSH (SSH only works for `git` operations), which is why mirrors are used instead.
- **Keep downloaded APKs**: enable *Settings → Keep downloaded APKs* to keep each APK after a successful install in the public `Download/Obtainium` folder instead of silently deleting it. Download notifications also show the exact file path.
- **Manually maintained app list**: the [`marketplace/apps.json`](./marketplace/apps.json) file holds the app configurations this marketplace offers.
- **Grouped app list (`list.json`)**: the [`list.json`](./list.json) file at the repo root is the source of truth for the bundled app groups. The app pulls it on every startup (remote URL with mirror fallback, then a bundled copy) and shows a clickable **group switcher** above the app list (`全部` / `mine` / `open`). See [Grouped app list](#grouped-app-list-listjson) below.

### Using the marketplace list

1. Download [`marketplace/apps.json`](https://github.com/PT123123/obtainapk/raw/main/marketplace/apps.json) to your device.
2. Open ObtainAPK → *Settings → Import/Export → Obtainium Import*, pick the file, and confirm the overwrite dialog.
3. Or add a single app by sharing its GitHub/other source URL into ObtainAPK (e.g. from a browser).

To add a new app to the marketplace, edit `marketplace/apps.json` following the entries already present (an `id` plus the source `url`, `author`, `name` and `additionalSettings` is enough) and push the change.

### Grouped app list (`list.json`)

[`list.json`](./list.json) at the repository root groups the pre-bundled apps so the app list can be filtered by group. Structure:

```json
{
  "schemaVersion": 1,
  "groups": [
    { "id": "mine", "name": "mine", "apps": [ /* your pre-configured apps */ ] },
    { "id": "open", "name": "open", "apps": [ /* suggested open-source apps */ ] }
  ]
}
```

Current groups:

- **`mine`** — your pre-configured apps (the apps previously shipped via `marketplace/apps.json`: NewPipe, Aegis, and the `PT123123/*` projects such as a-music, aw-android-native, a-quickstart, …).
- **`open`** — a curated set of other GitHub open-source Android apps: **ZipXtract**, **思源笔记 (SiYuan)**, **NekoBox**, **KOReader**, **F-Droid**, **disky**.

#### Behavior

- **Startup pull**: on every launch the app fetches `list.json` from
  `https://raw.githubusercontent.com/PT123123/obtainapk/main/list.json`
  (with a `ghproxy.com` mirror fallback), and falls back to the bundled
  `assets/list.json` if the network is unavailable. Each app is merged into your
  store and tagged with its group id in `App.categories`. Existing user apps are
  **never clobbered** — only the group tag is added; your pinned / renamed /
  reconfigured apps are preserved.
- **Group switcher**: a horizontal, clickable row of chips sits above the app
  list — `全部` (all), `mine`, `open`. Tapping a chip filters the list to that
  group. The selection persists across restarts.
- **Editing**: to change the bundled groups, edit `list.json` at the repo root
  **and** its copy `assets/list.json` (the bundled fallback), then push. The next
  app launch pulls the update.

### App list swipe gestures

On the app list, each tile supports two swipe directions (when swipe actions are enabled in Settings):

- **Swipe right** → **Install / Update** the app. If the install or download fails, a prompt now appears so you are not left with a silent failure.
- **Swipe left** → **Refresh this app**: re-fetch its latest release metadata from the source. A toast confirms success (`已刷新，最新：<version>`) or shows the error if the fetch fails.

More info:
- [Obtainium Wiki](https://wiki.obtainium.imranr.dev/) ([repository](https://github.com/ImranR98/Obtainium-Wiki))
- [Deep Links](https://wiki.obtainium.imranr.dev/deep_links/) - link straight to an import, or add a badge to your own project
- [Obtainium 101](https://www.youtube.com/watch?v=0MF_v2OBncw) - Tutorial video
- ["Verified Apps"](https://github.com/privacyguides/verified-apps-android) - App verification tool (recommended, integrates with Obtainium)
- [apps.obtainium.imranr.dev](https://apps.obtainium.imranr.dev/) - Crowdsourced app configurations ([repository](https://github.com/ImranR98/apps.obtainium.imranr.dev))
- [Side Of Burritos - You should use this instead of F-Droid | How to use app RSS feed](https://youtu.be/FFz57zNR_M0) - Original motivation for this app
- [Website](https://obtainium.imranr.dev) ([repository](https://github.com/ImranR98/obtainium.imranr.dev))

Currently supported App sources:
- Open Source - General:
  - [GitHub](https://github.com/)
  - [GitLab](https://gitlab.com/)
  - [Forgejo](https://forgejo.org/) ([Codeberg](https://codeberg.org/))
  - [F-Droid](https://f-droid.org/)
  - Third Party F-Droid Repos
  - [IzzyOnDroid](https://android.izzysoft.de/)
  - [SourceHut](https://git.sr.ht/)
- Other - General:
  - [APKPure](https://apkpure.net/)
  - [Aptoide](https://aptoide.com/)
  - [Uptodown](https://uptodown.com/)
  - [itch.io](https://itch.io/)
  - [Huawei AppGallery](https://appgallery.huawei.com/)
  - [Tencent App Store](https://sj.qq.com/)
  - [vivo App Store (CN)](https://h5.appstore.vivo.com.cn/)
  - [RuStore](https://rustore.ru/)
  - [Farsroid](https://www.farsroid.com)
  - [Samsung Galaxy Store](https://galaxystore.samsung.com/)
  - [LiteAPKs](https://liteapks.com/)
  - [APK4Free](https://apk4free.net/)
  - [CoolApk](https://coolapk.com/)
  - [SourceForge](https://sourceforge.net/)
  - Jenkins Jobs
  - [APKMirror](https://apkmirror.com/) *(Track-Only)*
  - [APKCombo](https://apkcombo.com/)
  - [RockMods](https://rockmods.net/) *(Track-Only)*
- Other - App-Specific:
  - [Telegram App](https://telegram.org/)
  - [Neutron Code](https://neutroncode.com/)
- Direct APK Link
- "HTML" (Fallback): Any other URL that returns an HTML page with links to APK files

## Finding App Configurations

You can find crowdsourced app configurations at [apps.obtainium.imranr.dev](https://apps.obtainium.imranr.dev).

If you can't find the configuration for an app you want, feel free to leave a request on the [issues page](https://github.com/ImranR98/apps.obtainium.imranr.dev/issues).

Or, contribute some configurations to the website by creating a PR at [this repo](https://github.com/ImranR98/apps.obtainium.imranr.dev).

## Installation

[<img src="https://github.com/machiav3lli/oandbackupx/blob/034b226cea5c1b30eb4f6a6f313e4dadcbb0ece4/badge_github.png"
    alt="Get it on GitHub"
    height="80">](https://github.com/PT123123/obtainapk/releases)
     
Verification info:

- Package ID: `com.pt123123.obtainapk`
- SHA-256 hash of signing certificate:
  ```text
  B3:53:60:1F:6A:1D:5F:D6:60:3A:E2:F5:0B:E8:0C:F3:01:36:7B:86:B6:AB:8B:1F:66:24:3D:A9:6C:D5:73:62
  ```
  - Note: The above signature is also valid for the F-Droid flavour of Obtainium, thanks to [reproducible builds](https://f-droid.org/docs/Reproducible_Builds/).
- [PGP Public Key](https://keyserver.ubuntu.com/pks/lookup?search=contact%40imranr.dev&fingerprint=on&op=index) (to verify APK hashes)

## Contributing / Developing

Please see the pertinent documentation, [on contributing](docs/CONTRIBUTING.md) and [the developer guide](docs/DEVELOPER_GUIDE.md) (architecture description).

## Limitations
- For some sources, data is gathered using Web scraping and can easily break due to changes in website design. In such cases, more reliable methods may be unavailable.

## Screenshots

| <img src="./assets/screenshots/1.apps.png" alt="Apps Page" /> | <img src="./assets/screenshots/2.dark_theme.png" alt="Dark Theme" />           | <img src="./assets/screenshots/3.material_you.png" alt="Material You" />    |
| ------------------------------------------------------ | ----------------------------------------------------------------------- | -------------------------------------------------------------------- |
| <img src="./assets/screenshots/4.app.png" alt="App Page" />   | <img src="./assets/screenshots/5.app_opts.png" alt="App Options" /> | <img src="./assets/screenshots/6.app_webview.png" alt="App Web View" /> |
