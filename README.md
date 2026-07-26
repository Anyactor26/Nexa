# Nexa

Nexa is an open-source Android automation agent built with Flutter. It utilizes an AI provider of your choice (DeepSeek, OpenRouter, NVIDIA NIM, etc.) and native Android Accessibility Services to interpret screen layouts and execute multi-step tasks across any installed application via natural language commands.

## Architecture

The system operates on a continuous feedback loop:
1. The user issues a command (via voice, text, wake word, Telegram, or Discord remote access).
2. Obvious, single-step commands (call, text, volume, alarm, open app, run command) are first matched locally with regex — no AI call needed — to save tokens and respond instantly.
3. For anything else, the agent captures the current screen hierarchy, calculating the exact spatial coordinates of all interactive elements.
4. The layout data is transmitted to the AI provider alongside the current task context and the result of the previous action.
5. The AI determines the next optimal action (e.g., clicking specific coordinates, inputting text, scrolling).
6. The native Android layer executes the action.
7. The loop repeats until the task is marked as complete.

## Capabilities

- **Screen Reading:** Parses the Android UI tree to map clickable, scrollable, and editable elements.
- **Coordinate-Based Interaction:** Simulates physical screen taps based on coordinate geometry, mitigating issues with missing text labels or inaccessible icons.
- **Local Command Routing:** Recognizes obvious commands (calls, texts, volume, alarms, opening apps, running shell commands) with regex and executes them instantly without hitting the AI API.
- **"Hey Nexa" Wake Word:** Optional, continuous on-device listening so you can trigger Nexa completely hands-free.
- **Remote Access:** Integrates with the Telegram Bot API and a polished Discord bot (live-updating embeds, password-gated commands) via background polling, allowing users to issue commands and monitor task execution progress remotely.
- **Voice Control:** Native speech-to-text integration for hands-free operation.
- **Adjustable Automation Speed:** A 1x–200x speed multiplier scales every wait in the automation loop, letting you trade a bit of safety margin for dramatically faster multi-step tasks.
- **Shizuku + Termux Fallback:** Runs privileged shell commands via Shizuku when available, and automatically falls back to dispatching them through Termux (including a PRoot-based root path) when it isn't.

## Installation

Download the latest APK directly from the [Releases Page](https://github.com/Anyactor26/Nexa/releases).

Choose `app-universal-release.apk` when it is available. It supports ARM64,
32-bit ARM, and x86_64 devices in one package. If a release only provides split
APKs, most modern Android phones—including Snapdragon devices—must use
`app-arm64-v8a-release.apk`.

Nexa supports Android 8.0 (API 26) and newer. Current release builds are
also checked for Android 15/16's 16 KB native-library alignment requirement.

## Setup Instructions (How to use for FREE)

This app requires an AI brain to operate. You can use it **100% for free** by using OpenRouter's free models.

1. Install the APK on your Android device (API 30+ recommended).
2. Go to [OpenRouter.ai](https://openrouter.ai/) and create a free account.
3. Generate a free API Key.
4. Launch Nexa and go to the **Settings** screen.
5. Tap the **"OpenRouter"** quick-select chip under Base URL.
6. Paste your API Key.
7. Type `openai/gpt-oss-120b:free` (or any other free model) into the Model field.
8. Enable the **"Nexa Screen Control"** service in your Android Accessibility Settings.

### “Restricted setting” when enabling Screen Control

Android may block accessibility access for apps installed from an APK. This is
an operating-system safety restriction:

1. Open **Settings → Apps → Nexa**.
2. Open the three-dot menu in the top-right corner.
3. Tap **Allow restricted settings** and confirm.
4. Return to Nexa and open **Accessibility Settings** again.
5. Enable **Nexa Screen Control**.

Nexa now shows these instructions and provides shortcuts to both App
Info and Accessibility Settings during onboarding.

## Telegram Integration

To enable remote access:
1. Acquire a bot token from BotFather on Telegram.
2. Input the token in the Nexa Settings screen and enable the integration toggle.
3. The application will maintain a background polling connection to the Telegram API to receive commands.

## Discord Integration

To enable a polished, real-time Discord control console:
1. Create a bot in the [Discord Developer Portal](https://discord.com/developers/applications) and copy its token.
2. Invite the bot to your server and copy the ID of the channel you want it to watch.
3. In Nexa's Settings → Discord Remote Control, paste the bot token and channel ID, and optionally set an auth password.
4. In Discord, authenticate once with `!nexa_password <token>`, then run anything with `!nexa <command>`. Nexa replies with a single, live-updating status embed per command instead of spamming the channel.

## Automation Speed

Settings → Tuning & Boundaries includes an **Automation Speed** slider (1x–200x, log-scaled for finer control at the low end). It scales every artificial delay in the multi-step automation loop — screen-transition waits, retry backoff, etc. — so tasks can complete far faster on snappy devices. A safety floor keeps a small delay even at 200x so the accessibility service always has time to register UI changes.

## License

This project is open-source and available for modification.
