# Contributing to Zangetsu

First off, thanks for considering contributing to Zangetsu! Whether it's a bug fix, a new feature, a new provider, or just fixing a typo — it's appreciated.

## Before You Start

- Check [open issues](../../issues) to see if what you want to work on is already being tracked.
- For anything bigger than a small fix (new features, big refactors, new providers), open an issue first to discuss the approach before writing code — saves everyone time.
- By submitting a pull request, you agree to our [Contributor License Agreement](CLA.md). Please give it a quick read.
- Zangetsu is licensed under **GPLv3 with additional terms** (see [`LICENSE`](LICENSE)) — your contributions will be distributed under those same terms.
- Using AI tools to help write your Contribution? That's allowed — read [`AI_POLICY.md`](AI_POLICY.md) first for disclosure and quality expectations.
- Third-party code Zangetsu incorporates (and its licenses) is documented in [`NOTICE.md`](NOTICE.md) — worth a skim if you're touching provider/extractor code.

## Repo Structure

This repo is the main Zangetsu app (Flutter/Dart, with native `android/` and `ios/` platform folders). A few things worth knowing before you dive in:

- `lib/` — the main Dart application code
- `providers/` — provider integrations bundled with the app
- `extractors/` — logic for extracting playable streams from sources
- `js_harness/` — JavaScript module execution used by providers
- `assets/` — icons, splash screens, and other static assets
- `test/` — tests

**Note:** additional/community content sources live in a separate repo, [zangetsu-providers](https://github.com/Spyou/zangetsu-providers). If your contribution is a new content source rather than a core app change, check there first — it may be the better place for it.

## Setting Up Your Dev Environment

1. Fork the repo and clone your fork:
   ```bash
   git clone https://github.com/Spyou/Zangetsu.git
   cd Zangetsu
   ```
2. Make sure you have the **Flutter SDK** installed (check `pubspec.yaml` / `.metadata` for the version this project targets).
3. Get dependencies:
   ```bash
   flutter pub get
   ```
4. Run the app on a connected device/emulator:
   ```bash
   flutter run
   ```
5. Create a new branch for your change:
   ```bash
   git checkout -b fix/short-description
   ```

## Making Changes

- Keep pull requests focused — one fix or feature per PR is easier to review than a bundle of unrelated changes.
- Match the existing code style already in the file you're editing.
- Add or update tests under `test/` where it makes sense.
- Update relevant documentation/comments if your change affects behavior.
- **If your PR adds a new dependency, or incorporates code/assets derived from another project, update [`NOTICE.md`](NOTICE.md) in the same PR.** This isn't optional — PRs that introduce undocumented third-party code will be asked to add the attribution before merging.

## Code Analysis

This project uses `analysis_options.yaml` to enforce Dart/Flutter lint rules. Before opening a PR, run:

```bash
flutter analyze
```

and fix anything flagged. If you're touching platform-specific code (`android/`, `ios/`), also make sure the native build still compiles cleanly.

## Commit Messages

Write clear, descriptive commit messages. We loosely follow this format:

```
type: short summary

Optional longer description if needed.
```

Where `type` is one of: `fix`, `feat`, `docs`, `refactor`, `chore`, `test`.

Example: `fix: correct resume position not saving on episode change`

## Submitting a Pull Request

1. Push your branch and open a PR against `main`.
2. Fill out the PR template with what changed and why.
3. Link any related issues (e.g. `Closes #42`).
4. Make sure CI checks (build, analyze, tests) pass.
5. Be responsive to review feedback — most PRs go through a round or two of comments before merging.

## Reporting Bugs

Open an issue with:
- What you expected to happen vs. what actually happened
- Steps to reproduce
- Device/OS and app version
- Screenshots, logs, or a stack trace if relevant

## Adding or Fixing a Provider/Extractor

If you're contributing a provider or extractor:
- Only submit sources you have the right to interact with — see Section 5 of the [CLA](CLA.md).
- Keep provider logic isolated from core app logic where possible.
- Test that search, browsing, and playback all work end-to-end before submitting.
- Note any rate limits, region restrictions, or fragility (e.g. sources that change their site structure often) in your PR description.

## Code of Conduct

Be respectful. Disagreements about code are fine; personal attacks aren't. Maintainers reserve the right to close issues/PRs or block contributors who don't engage in good faith.

---

Questions? Open an issue or start a discussion — happy to help you get oriented.
