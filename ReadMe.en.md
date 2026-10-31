# mac-ime

[日本語版](./ReadMe.md)

This is an Emacs extension designed to use IME comfortably on Emacs without any IME patches.
By hooking macOS key input events, it automatically turns off the IME when a prefix key is pressed or during minibuffer input, and restores the IME state after the command execution is completed.
Since it controls the system IME using Emacs' dynamic module feature, you can input Japanese without stress even on an Emacs build that lacks IME patches.

## Features

- **Key Event Hooking**: Monitors `NSEvent` to detect specific key inputs and modifier key state changes from within Emacs.
- **IME Control**: Retrieves and changes the current input source (IME).
- **Fast Performance**: Low-latency event processing powered by a dynamic module written in Objective-C.

## Requirements

- macOS
  - Mainly targets GUI Emacs.  In terminal mode (`emacs -nw`, `emacsclient -t`), only some features work (see [Terminal Mode](#terminal-mode)).
- Emacs 27.1 or higher (with dynamic module support enabled)
- Clang (for building)

## Installation

`mac-ime` is available on MELPA. If you have MELPA configured, you can install it by running:

```
M-x package-install RET mac-ime RET
```

If you use `use-package`, add the following to your configuration:

```elisp
(use-package mac-ime
  :ensure t
  :config
  ;; Set the default input method to "mac-ime"
  (setq default-input-method "mac-ime")
  ;; Enable the module (starts event monitoring)
  (mac-ime-enable))
```

### Dynamic Module Download

`mac-ime` uses a dynamic module (`mac-ime-module.so`).

When the package is installed, or if the module file is missing or outdated, `mac-ime` will automatically download and place the appropriate pre-built module from GitHub Releases using `curl` when `mac-ime-enable` is executed.

If you wish to download/update the module manually, run `M-x mac-ime-download-module`.

The module is searched in the following order, and the first one matching the required version is used:

1. `mac-ime-module.so` in the same directory as `mac-ime.el` (e.g. when built with `make`)
2. `mac-ime-module.so` in the directory of `mac-ime.el` with symlinks resolved (with straight.el or elpaca, the module in the repository is used, so no download is needed)
3. `mac-ime-module-<module version>.so` in `mac-ime-module-directory` (defaults to `mac-ime/` under `user-emacs-directory`)

Downloaded modules are stored in location 3.  Because it is outside the package directory, upgrading the package from MELPA does not require downloading the module again unless the module version changes.

> [!IMPORTANT]
> `mac-ime` relies on a dynamic module (`.so`). Although you can update files via `package-upgrade` or `package-upgrade-all`, the already loaded module (`module-load`) cannot be completely replaced in-place within the same Emacs process. Please restart Emacs after upgrading.
> While `mac-ime-unload-function` cleans up timers, hooks, and advices, it does not unload the dynamic module itself from the running process.

## Troubleshooting

### "library load disallowed by system policy" or Module Cannot Be Loaded

Before loading the module, `mac-ime` automatically attempts to clear the `com.apple.quarantine` attribute. However, the load may still fail due to permission restrictions or other security policies.
To check and clear the attribute manually, run the following commands in your terminal:

```bash
# Check the attribute
xattr -l mac-ime-module.so

# Remove the attribute
xattr -d com.apple.quarantine mac-ime-module.so
```

### Module Version Mismatch Warning

If you see a warning or error such as "Loaded module version `X` is older than required `Y`" after an update, it means the running Emacs is still using the older version of the module.
Follow the on-screen instructions to download the latest module and then **restart Emacs**.

If you want to manually rebuild the module, run:

```bash
make clean
make
```

## Usage

This feature becomes active only when the input method is set to "mac-ime".
By turning on Japanese input using `C-\` (`toggle-input-method`) or `cmd-space`, the IME will automatically turn off and restore itself based on your actions.

### IME Deactivation on Prefix Key Input

When Japanese input is active and you enter a prefix key (a key sequence waiting for subsequent keys, such as `C-x`), the IME automatically switches temporarily to Roman (English) input, and restores the original IME state (e.g., Japanese input) after the command execution completes.
However, the IME will not be deactivated if a conversion is in progress (i.e., there is unconfirmed text in the input buffer). This prevents the IME from turning off accidentally and canceling your current conversion during typing.

This feature dynamically queries the active Emacs keymaps (`key-binding`) to determine if a key is a prefix key.
Thus, even if you customize keybindings or use third-party packages like Evil mode that modify keymaps, prefix keys are automatically recognized without any special manual configuration.

Modifier keys are converted into an Emacs key the same way the NS port of Emacs does, according to `mac-control-modifier`, `mac-command-modifier`, `mac-option-modifier`, `mac-function-modifier` and their `mac-right-*` variants.
- A modifier set to `none` or `nil` is ignored.  For example, with `mac-option-modifier` set to `none`, Option+x is treated as the character typed (such as `≈`).
- The `(:ordinary SYMBOL :function SYMBOL :mouse SYMBOL)` form is supported.  `:function` is used for function keys (arrow keys, Home/End, Page Up/Down, F1-F24, TAB, RET, ESC, backspace, etc.) and `:ordinary` for other keys.
- The fn modifier is ignored for function keys, because macOS sets it on the arrow keys and F keys even when fn is not pressed.
- When a key is pressed with both a modifier set to `none` and a modifier that is not, the character is approximated by the one typed without any modifiers.

> [!NOTE]
> The manual keycode settings via `mac-ime-prefix-keys` and `mac-ime-modifier-action-table` that existed in older versions have been deprecated and removed.

### Terminal Mode

In terminal mode (`emacs -nw`, `emacsclient -t`), key input is received by the terminal application such as Terminal.app, so the dynamic module cannot see key events.  Therefore, when the selected frame is on a text terminal, a timer runs the following every `mac-ime-poll-interval` seconds.

- **IME deactivation on prefix keys**: If the keys typed so far (`this-single-command-keys`) are bound to a keymap, the IME is turned off temporarily.  As on GUI Emacs, it is restored right before the next command is executed.
- **Synchronization with the input source**: When the IME is switched in the terminal application, the change of the input source is detected and `current-input-method` is synchronized.  It is not synchronized when the terminal reports focus events and the frame is known to be unfocused.

The differences from GUI Emacs are as follows.

- Since a timer is used, if you type the next key quickly after a prefix key, the key may be sent to the IME of the terminal application before the IME is turned off.
- Whether the IME is converting cannot be determined.  However, keys typed while converting are handled by the IME of the terminal application and do not reach Emacs, so the IME is never turned off while converting.
- When GUI frames and text terminal frames are mixed (e.g. with `emacsclient`), the behavior is switched according to the selected frame.

### IME Deactivation during Minibuffer Input

To switch to Roman input when entering the minibuffer and restore the previous state afterwards, `mac-ime` adds advice to the functions specified in `mac-ime-auto-deactivate-functions`. This advice ensures that Roman input is set before the function runs and the original state is restored afterwards.

By default, the following functions are configured:

- `read-string`
- `read-char`
- `read-event`
- `read-char-exclusive`
- `read-char-choice`
- `read-no-blanks-input`
- `read-from-minibuffer`
- `completing-read`
- `y-or-n-p`
- `yes-or-no-p`
- `map-y-or-n-p`

For functions that have an `inherit-input-method` argument (such as `read-string` and `read-from-minibuffer`), if that argument is non-nil, `mac-ime` checks if the buffer's input method is "mac-ime" and turns the macOS IME on only in that case.
To customize this setting, specify either the function symbol alone, or in the form `(function-symbol . index-of-inherit-input-method-argument)`.

Additionally, commands like `C-u` (which require Roman input for subsequent keys and must restore the original state before the next command runs) are specified in the variable `mac-ime-temporary-deactivate-functions`. (For `universal-argument`, only the first key input after `C-u` would be Roman, so `universal-argument--mode` is registered to handle subsequent numeric inputs).

### IME Input Mode Determination

Since this module needs to determine whether the macOS input source is Roman or non-Roman (such as Japanese), it matches the input source ID against a regular expression. If you use a custom IME and this detection does not work properly, configure `mac-ime-no-ime-input-source-regexp` so that it correctly identifies Roman input. You can retrieve the list of currently available input source IDs by running `(mac-ime-get-input-source-list)`.

## Configuration Examples

These are examples of turning the IME off for commands of external packages that `mac-ime` itself does not handle.

### Turning the IME off while a function runs (simple example)

`mac-ime-auto-deactivate` turns the IME off only while the specified function is running, and restores it after the function finishes. For example, to make input during `avy-goto-char-timer` Roman, use the following setting.

```elisp
(mac-ime-auto-deactivate 'avy-goto-char-timer)
```

### Packages that accept key input in subsequent commands (complex example: ace-jump-mode)

`ace-jump-mode` only displays the candidates and sets up an overriding keymap, then returns from the function. The head-char input is handled by a subsequent command (`ace-jump-move`). Therefore, with `mac-ime-auto-deactivate`, the IME is restored before the head-char is typed. Also, the head-char may consist of two or more characters.

`mac-ime-temporary-deactivate` turns the IME off before the function runs, and keeps it off after the function finishes, until just before the next command is executed. This property is required to accept the head-char, which is typed after the function has finished, in Roman, so `mac-ime-temporary-deactivate` is used.

However, the IME is restored just before the next command is executed, so when the head-char has two or more characters, the IME is restored before the command for the first character (`ace-jump-move`) runs. Therefore `ace-jump-move` is also targeted, so that the IME is turned off again each time it runs. In addition, to prevent the IME from staying off until the next key input after the jump completes, the IME is explicitly restored at the end.

```elisp
(with-eval-after-load 'ace-jump-mode
  (mac-ime-temporary-deactivate 'ace-jump-mode)
  (mac-ime-temporary-deactivate 'ace-jump-char-mode)
  (mac-ime-temporary-deactivate 'ace-jump-word-mode)
  (mac-ime-temporary-deactivate 'ace-jump-line-mode)
  (mac-ime-temporary-deactivate 'ace-jump-move)
  ;; When the jump completes (single candidate, or a leaf is selected)
  (add-hook 'ace-jump-mode-end-hook #'mac-ime--restore-input-source)
  ;; When the jump is canceled
  (advice-add 'ace-jump-done :after
              (lambda (&rest _) (mac-ime--restore-input-source))))
```

Note that `mac-ime-disable` only removes the advice of functions included in `mac-ime-temporary-deactivate-functions`. The settings above are not removed by `mac-ime-disable`. To remove them, use `mac-ime-remove-auto-deactivate` / `mac-ime-remove-temporary-deactivate`.

## Provided Functions

### Basic Operations

- `(mac-ime-enable)`: Starts the event monitor, enabling key event monitoring and various hooks. At startup, it checks module existence and version consistency. If there is a missing module or a version mismatch, it prompts for automatic download.
- `(mac-ime-disable)`: Stops and removes the event monitor, timers, and hooks.
- `(mac-ime-download-module &optional tag)`: Downloads the dynamic module for the specified tag (defaults to `v<version>` corresponding to the current package version) from GitHub and stores it in `mac-ime-module-directory`.

### IME Operations

- `(mac-ime-get-input-source)`: Retrieves the current input source ID (e.g., `"com.apple.keylayout.US"`).
- `(mac-ime-set-input-source SOURCE-ID)`: Switches to the input source with the specified ID.
- `(mac-ime-get-input-source-list)`: Retrieves a list of available input source IDs.
- `(mac-ime-activate-ime)`: Switches the system IME to the ON state (e.g., Japanese input).
- `(mac-ime-deactivate-ime)`: Switches the system IME to the OFF state (Roman/English).

### Auto-Switching Settings

- `(mac-ime-auto-deactivate FUNC)`: Configures the specified function `FUNC` to automatically turn off the IME during execution and restore it afterwards.
- `(mac-ime-temporary-deactivate FUNC)`: Configures the specified function `FUNC` to temporarily turn off the IME before execution. The IME state is restored right before the next new command is executed.
- `(mac-ime-remove-auto-deactivate FUNC)`: Removes the advice added to `FUNC` by `mac-ime-auto-deactivate`. `FUNC` may also be given in the `(FUNCTION . ARG-INDEX)` form.
- `(mac-ime-remove-temporary-deactivate FUNC)`: Removes the advice added to `FUNC` by `mac-ime-temporary-deactivate`.

## Customization

- `mac-ime-auto-deactivate-functions`: List of functions that automatically disable IME when executed. By default, it turns off IME during minibuffer input, etc.
- `mac-ime-temporary-deactivate-functions`: List of functions that temporarily disable IME before execution and restore the original state right before the next command starts. Default includes `universal-argument`, etc.
- `mac-ime-no-ime-input-source-regexp`: Regular expression to determine which input sources are "IME off (Roman/English)".
- `mac-ime-ime-on-input-source` / `mac-ime-ime-off-input-source`: Explicitly specifies the input source ID to turn IME on/off (usually automatically detected).
- `mac-ime-title-rules`: Rules to determine the indicator (e.g., `[あ]`) displayed in the mode line based on the input source ID.
- `mac-ime-module-directory`: Directory where the downloaded dynamic module is stored.  Defaults to `(locate-user-emacs-file "mac-ime/")`.
- `mac-ime-debug-level`: Output level for debug messages (0: none, 1: input keys, 2: detailed).
- `mac-ime-functions`: List of hook functions called when a key event occurs. Registered hook functions must accept 5 arguments: `(keycode modifiers characters characters-ignoring converting-p)`.
