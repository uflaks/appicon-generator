# App Icon Generator

A macOS app and command-line tool that generates app icon artwork with image models, lets you refine it, and exports it in the formats Xcode and macOS expect.

- **Generate** from a short subject description and a style preset.
- **Compare** the same prompt across several models at once.
- **Refine** a candidate with an image-editing model ("make the sky orange").
- **Export** an `AppIcon.appiconset` for iOS and macOS, and a `.icns` file.
- **Rank** the models by your own picks, alongside public scores, release dates and licence terms.

## Providers

| Provider | Models | What you need |
|---|---|---|
| Hugging Face | Krea 2 Turbo, Z-Image Turbo, Qwen-Image 2512, Ideogram 4, FLUX.1; FLUX.2 klein and FLUX.1 Kontext for editing | A Hugging Face token with the "Inference Providers" permission. Requests are routed to fal and billed to your Hugging Face account. |
| OpenAI | GPT Image 2.5 and 2 | An OpenAI API key. |
| Codex | GPT Image, chosen by Codex | The [Codex CLI](https://developers.openai.com/codex), signed in with a ChatGPT account. No API key; requests count against your Codex usage limits and take about a minute each. |

Only OpenAI's API models can produce transparent backgrounds.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6)

## The app

Open `AppIconGenerator.xcodeproj` and run the `AppIconGenerator` scheme.

Enter your keys under Settings (⌘,); they are stored in your login Keychain. If you have no Hugging Face token saved, the app uses the login of the `hf` command-line tool when there is one.

The window has three columns:

1. **Compose**: subject, style, background and model. Turn on *Compare models* to tick several models and run them together.
2. **Candidates**: everything generated, refined or imported, newest first. Drop image files here to import them. Drag a candidate out to save it as a PNG.
3. **Inspector**: preview the selected candidate as raw artwork, an iOS icon or a macOS icon, refine it, export it, and see the licence of the model that made it.

Mark candidates you like as favourites. In a comparison, a favourite counts as a win for its model; exporting an icon marks it as a favourite too. The trophy button in the toolbar opens the model ranking built from those picks.

Candidates and comparison results are kept in `~/Library/Application Support/AppIconGenerator`.

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); run `xcodegen` after changing it.

## The command-line tool

```sh
swift run appicon generate "a sun partly behind a soft white cloud" --count 2
swift run appicon generate "a paper plane" --best-open
swift run appicon generate "a paper plane" --best
swift run appicon edit out/icon.png "make the background a warm orange"
swift run appicon export out/icon.png --icns
swift run appicon models
```

- `--best-open` uses the highest-rated open model through Hugging Face.
- `--best` uses GPT Image: through the OpenAI API when `OPENAI_API_KEY` is set, otherwise through Codex.
- `--provider` (`hf`, `openai`, `codex`) and `--model` choose explicitly.
- `--style` is one of `flat`, `gradient`, `glossy`, `clay`, `glass`, `line`, `pixel`, `illustrated`.

Keys come from the environment: `HF_TOKEN` (or the `hf` login) and `OPENAI_API_KEY`. Images are written to `out/` unless `--out` says otherwise.

## Licences of the models

Each model's own licence decides whether its icons may ship in a commercial app, and they differ: some are Apache 2.0, one allows commercial use only below a revenue limit, and one forbids it. The app shows a short summary per model, and `appicon models` lists them. Those summaries were written by hand in November 2026 from the licence texts; check the linked licence, and the terms of the hosting provider, before relying on them. They are not legal advice.

## How it is put together

| Path | Contents |
|---|---|
| `Sources/AppIconCore` | Providers, prompt presets, icon export. No UI. |
| `Sources/appicon` | The command-line tool. |
| `Sources/AppIconUI` | The app's state and SwiftUI views. |
| `App` | The app target: entry point and asset catalogue. |
| `Tests` | Unit tests for the core and the app's state. |

Prompts never contain the words "app icon": image models respond to that by drawing a rounded tile inset on a backdrop, which is useless as source artwork. The prompt asks for full-bleed square artwork instead, and the corner shape is applied on export (macOS) or by the system (iOS).

```sh
swift test
```

The tests use stand-ins for the network and for Codex, so they need no keys and cost nothing.

## Things to know

- The app is not sandboxed and is signed to run locally only.
- Model lists, public scores and release dates are fixed in the code and will age.
- The OpenAI API provider is covered by tests but has not been run against the live API.
