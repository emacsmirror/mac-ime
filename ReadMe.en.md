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
- Emacs 27.1 or higher (with dynamic module support enabled)
- Clang (for building)

## Installation

`mac-ime` uses a dynamic module (`mac-ime-module.so`).

Since a pre-built fat binary of the module is included in the repository, you do not need to build it yourself if you clone the repository.
Furthermore, even if the module file is missing or outdated, `mac-ime` will automatically download and place the appropriate module from GitHub Releases using `curl` when `mac-ime-enable` is executed.

If you wish to download/update the module manually, run `M-x mac-ime-download-module`.

On Emacs 29 or later, you can install it using the `:vc` keyword of `use-package`.

### Cloning the Repository

1. Clone the repository:

```bash
git clone https://github.com/ma0001/mac-ime.git
```

2. Add the following configuration to your `init.el` or equivalent:

```elisp
;; Add to load-path (adjust the path to match your local setup)
(add-to-list 'load-path "/path/to/mac-ime")
(require 'mac-ime)
;; Set the default input method to "mac-ime"
(setq default-input-method "mac-ime")
;; Enable the module (starts event monitoring)
(mac-ime-enable)
```

3. Updating:

To update, pull the latest changes from the repository:

```bash
cd /path/to/mac-ime
git pull
```

### Using use-package :vc (Emacs 29+)

On Emacs 29 and later, you can install the package using the `:vc` keyword. Add the following to your `init.el` or equivalent:

```elisp
(use-package mac-ime
  :vc (:url "https://github.com/ma0001/mac-ime")
  :config
  ;; Set the default input method to "mac-ime"
  (setq default-input-method "mac-ime")
  ;; Enable the module
  (mac-ime-enable))
```

To update, use `M-x package-vc-upgrade` or `M-x package-upgrade-all`.
(Note: It will not show up with a 'U' indicator in `list-packages`.)

> [!IMPORTANT]
> `mac-ime` relies on a dynamic module (`.so`). Although you can update files via `package-upgrade-all`, the already loaded module (`module-load`) cannot be completely replaced in-place within the same Emacs process. Please restart Emacs after upgrading.
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

> [!NOTE]
> The manual keycode settings via `mac-ime-prefix-keys` and `mac-ime-modifier-action-table` that existed in older versions have been deprecated and removed.

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

## Provided Functions

### Basic Operations

- `(mac-ime-enable)`: Starts the event monitor, enabling key event monitoring and various hooks. At startup, it checks module existence and version consistency. If there is a missing module or a version mismatch, it prompts for automatic download.
- `(mac-ime-disable)`: Stops and removes the event monitor, timers, and hooks.
- `(mac-ime-download-module &optional tag)`: Downloads and places the dynamic module for the specified tag (defaults to `v<version>` corresponding to the current package version) from GitHub.

### IME Operations

- `(mac-ime-get-input-source)`: Retrieves the current input source ID (e.g., `"com.apple.keylayout.US"`).
- `(mac-ime-set-input-source SOURCE-ID)`: Switches to the input source with the specified ID.
- `(mac-ime-get-input-source-list)`: Retrieves a list of available input source IDs.
- `(mac-ime-activate-ime)`: Switches the system IME to the ON state (e.g., Japanese input).
- `(mac-ime-deactivate-ime)`: Switches the system IME to the OFF state (Roman/English).

### Auto-Switching Settings

- `(mac-ime-auto-deactivate FUNC)`: Configures the specified function `FUNC` to automatically turn off the IME during execution and restore it afterwards.
- `(mac-ime-temporary-deactivate FUNC)`: Configures the specified function `FUNC` to temporarily turn off the IME before execution. The IME state is restored right before the next new command is executed.

## Customization

- `mac-ime-auto-deactivate-functions`: List of functions that automatically disable IME when executed. By default, it turns off IME during minibuffer input, etc.
- `mac-ime-temporary-deactivate-functions`: List of functions that temporarily disable IME before execution and restore the original state right before the next command starts. Default includes `universal-argument`, etc.
- `mac-ime-no-ime-input-source-regexp`: Regular expression to determine which input sources are "IME off (Roman/English)".
- `mac-ime-ime-on-input-source` / `mac-ime-ime-off-input-source`: Explicitly specifies the input source ID to turn IME on/off (usually automatically detected).
- `mac-ime-title-rules`: Rules to determine the indicator (e.g., `[あ]`) displayed in the mode line based on the input source ID.
- `mac-ime-debug-level`: Output level for debug messages (0: none, 1: input keys, 2: detailed).
- `mac-ime-functions`: List of hook functions called when a key event occurs. Registered hook functions must accept 5 arguments: `(keycode modifiers characters characters-ignoring converting-p)`.
