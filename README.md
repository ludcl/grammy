# Grammy

A personal, native macOS writing assistant for selected text. Built with SwiftUI and AppKit, for Apple Silicon and macOS 26 (Tahoe) or later.

Select a draft in Slack Desktop → **Services → Improve Slack message** → review the suggestion → **Replace**, **Regenerate**, or **Cancel**. A global **Control–Option–Command–G** shortcut opens the same preview. A menu-bar action also lets you paste a message manually and copy its suggestion.

## Build and run

From this directory:

```sh
bash scripts/build.sh
open dist/Grammy.app
```

The script uses the installed Swift toolchain and creates an ad-hoc-signed development app. No external packages or backend are needed. You can open `Package.swift` in Xcode to work on the code; use the bundled build script to assemble the `.app` with its Services registration.

For the most predictable Services discovery, place the built app in `~/Applications` or `/Applications`, launch it once, and restart Slack. In **System Settings → Keyboard → Keyboard Shortcuts → Services → Text**, enable **Improve Slack message** if needed. Right-click placement depends on the source editor. Also check **Slack → Services** in the macOS menu bar.

For the shortcut, enable **Grammy** under **System Settings → Privacy & Security → Accessibility**. A consistent Developer ID signature and installation path help avoid permission resets between builds. The development shortcut is fixed to Control–Option–Command–G.

## Connect ChatGPT

Choose **Continue with ChatGPT** in Grammy Settings. Select your account/workspace and authorize plan usage in the system browser. Grammy discovers the models available to that account; you can change the selected model in Settings.

This uses the documented preview for ChatGPT plan usage in local/open-source apps, not an API key or credentials copied from Codex. Enterprise workspaces may restrict this integration. A successful build does not establish your account's eligibility. The allowance described as “1,000 monthly tokens” must be checked in your account: credits and tokens are different units, and Grammy does not estimate a currency cost from that number.

There is **no paid OpenAI API fallback**. If enabled, the Google AI Studio fallback described below can handle ChatGPT availability errors. A failed request always leaves the draft unchanged until you accept a completed suggestion.

Authentication uses OAuth authorization code + PKCE, state and nonce validation, verified RS256 ID-token signatures from OpenAI's published JWKS, and serialized refreshes. Credentials are kept in macOS Keychain. The browser callback listens only on `127.0.0.1` for at most three minutes. A future signing-algorithm change fails closed and will need an update.

## Google AI Studio fallback

Grammy 0.2 adds **gemini-3.5-flash-lite** as an optional fallback. In Settings, paste your Google AI Studio API key into the secure field and choose **Save key & enable fallback**. The key is stored in a separate, device-only Keychain entry; it is never bundled in the app or written to preferences. Saving clears the input field. You can replace or remove the key at any time.

ChatGPT remains first. If it is disconnected, its account/model is unavailable, it returns an authentication/quota/server error, or a network connection fails, Grammy tries Gemini once when fallback is enabled. Any partial ChatGPT output is discarded. The preview identifies Gemini when it is used. Cancelling a rewrite never starts a fallback request. Content refusals and failed emoji validation do not trigger fallback.

The exact model is fixed to `gemini-3.5-flash-lite`; a missing-model error is shown rather than silently using a different model. Google receives the selected draft, correction instructions, and the latest alternative during regeneration. Google AI Studio quotas, billing, and data-handling terms apply separately from your ChatGPT subscription. There is still no paid OpenAI API fallback.

**Test connection** sends one short synthetic English message to Gemini and checks that the response completed and preserved its emoji. Saving a key alone does not make a network request. Disable **Use Gemini when ChatGPT is unavailable** to retain the saved key without automatic fallback.

## Behavior and limits

- No keystroke collection, background draft scanning, Slack token, bot, or workspace-history access.
- Opening a menu does not send text. Choosing the rewrite command or Regenerate does.
- Only the selected passage is sent to the active provider; regeneration also sends the latest alternative and correction instructions.
- Emoji graphemes and `:shortcodes:` must match the original before Replace or Copy is enabled.
- Suggestions can be edited in the preview. Rewrites are accepted only after the API signals completion (OpenAI `response.completed` or Gemini `STOP`).
- Services uses the native selected-text transaction. It cancels after four minutes to stay within its five-minute system timeout. Opening Settings ends that transaction without replacement.
- The shortcut checks the original editor, complete value, selected range, and selected text before replacement. It refuses a stale target.
- Shortcut replacement uses Accessibility when writable, otherwise a checked Cmd-V operation. It never presses Return. The clipboard is restored after one second only if it was not changed by another app. Clipboard-manager history is outside Grammy's control.
- **Plain-text replacement only.** Review rich mentions, linked labels, lists, formatting, and custom emoji objects in Slack after replacement. The app does not promise to preserve their internal representation.
- Services may work in other editors; universal app compatibility is not claimed.
- No draft history, analytics, or message logging. Drafts and suggestions exist in process memory. `store: false` disables Responses storage; it is not a claim about all provider-side retention. Workspace/provider data rules still apply.

## Validate

```sh
bash scripts/test.sh
open dist/Grammy.app --args --sample
```

Tests cover complex emoji preservation, failed/incomplete responses, request constraints, PKCE, OAuth callback validation, JWT signatures/claims, the exact Gemini model and header authentication, and fallback success/failure/cancellation. The sample preview is explicitly labeled and makes no model request.

Manual acceptance checklist (use a disposable draft, never a sent message):

1. Sign in with your own ChatGPT account. Confirm a model catalog loads.
2. In Slack, type `hey team, i wont be able to joins today 😅 :thumbsup:` and select it.
3. Invoke Services. Confirm the preview, emoji preservation, Regenerate, and Cancel.
4. Invoke again and Replace. Confirm only selected text changed and nothing was sent. Try Undo in Slack.
5. Repeat via the global shortcut. While the preview is open, change the source draft or selection. Replace must refuse the changed target.
6. Test multiline text, Unicode emoji, custom emojis, mentions, linked text, and code blocks separately. Rich content is a known limitation.
7. Check a second editor such as TextEdit. Compatibility is determined per editor.

## Signing and sharing

To use your Developer ID, provide the exact installed signing identity locally:

```sh
GRAMMY_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/build.sh
```

That enables hardened-runtime signing. Notarization is a separate distribution step; no app has been submitted to Apple by this project. Do not distribute the ad-hoc prototype as a notarized release. Everyone installs their own copy and signs in with their own account. No credentials are bundled. This repository has no publishing or open-source license decision yet.

## Sources

- [ChatGPT plan usage](https://developers.openai.com/siwc/token-sharing-open-source)
- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Account sessions and refresh](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and streaming](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Apple Services](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html)

- [Gemini 3.5 Flash-Lite](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite)
- [Gemini generateContent API](https://ai.google.dev/api/generate-content)
