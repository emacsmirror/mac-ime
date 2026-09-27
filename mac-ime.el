;;; mac-ime.el --- Seamless macOS IME integration without any IME patches -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026 Masami
;; Author: Masami Iwata
;; Assisted-by: Gemini:3.1pro
;; Version: 0.2.2
;; Keywords: i18n, convenience
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/ma0001/mac-ime

;; This file is not part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides seamless integration with macOS native input methods
;; without applying any custom patches to Emacs.
;;
;; It uses a dynamic module to hook into macOS key events, synchronizing
;; the system IME state with Emacs.  It also automatically deactivates the
;; IME when you press prefix keys (like C-x) or when Emacs prompts for input
;; (like `y-or-n-p' or `read-string'), ensuring a smooth editing experience.
;;
;; Note that this package requires a dynamic module (`mac-ime-module.so`).
;; On the first activation, it will prompt you and download the module
;; from GitHub using `curl` into `mac-ime-module-directory', where it is
;; kept across package upgrades.  Please ensure you are online for this
;; step.
;;
;; To use this package, add the following to your init file:
;;
;;   (setq default-input-method "mac-ime")
;;   (mac-ime-enable)

;;; Code:

(require 'cl-lib)
(require 'nadvice)

(declare-function mac-ime-internal-get-input-source-list nil ())
(declare-function mac-ime-internal-get-input-source nil ())
(declare-function mac-ime-internal-set-input-source nil (source-id))
(declare-function mac-ime-internal-poll nil (hook-func))
(declare-function mac-ime-internal-start nil ())
(declare-function mac-ime-internal-stop nil ())
(declare-function mac-ime-internal-version nil ())

(defvar mac-control-modifier)
(defvar mac-right-control-modifier)
(defvar mac-command-modifier)
(defvar mac-right-command-modifier)
(defvar mac-option-modifier)
(defvar mac-right-option-modifier)
(defvar mac-function-modifier)

(defconst mac-ime-version "0.2.2"
  "Version of the mac-ime package.")

(defconst mac-ime-required-module-version "0.1.0"
  "Required exact version of the mac-ime-module.so.")

(defcustom mac-ime-module-github-repo "ma0001/mac-ime"
  "GitHub repository owner and name for downloading the module."
  :type 'string
  :group 'mac-ime)

(defconst mac-ime-input-method "mac-ime"
  "Name of the mac-ime input method.")

(defvar mac-ime-module-file "mac-ime-module.so"
  "Name of the dynamic module file.")

(defconst mac-ime--package-file (or load-file-name buffer-file-name)
  "File from which mac-ime was loaded.")

(defcustom mac-ime-module-directory (locate-user-emacs-file "mac-ime/")
  "Directory where the downloaded dynamic module is stored.
The module is saved there as mac-ime-module-VERSION.so, so it is kept
across package upgrades as long as the required module version does
not change."
  :type 'directory
  :group 'mac-ime)

(defvar mac-ime-module-path nil
  "Full path to the dynamic module to try first.
If nil, the module is searched in the locations returned by
`mac-ime--module-candidates'.")

(defun mac-ime--module-download-path ()
  "Return the path where the downloaded module is stored."
  (expand-file-name (format "mac-ime-module-%s.so"
                            mac-ime-required-module-version)
                    mac-ime-module-directory))

(defun mac-ime--module-candidates ()
  "Return the list of paths where the dynamic module is searched.
The list consists of `mac-ime-module-path' if non-nil, the directory
of mac-ime.el, the directory of the true name of mac-ime.el (the
repository when installed via straight.el or elpaca), and
`mac-ime--module-download-path'."
  (let* ((dir (file-name-directory mac-ime--package-file))
         (el-file (expand-file-name
                   (concat (file-name-base mac-ime--package-file) ".el")
                   dir)))
    (delete-dups
     (delq nil
           (list (and mac-ime-module-path
                      (expand-file-name mac-ime-module-path))
                 (expand-file-name mac-ime-module-file dir)
                 (expand-file-name mac-ime-module-file
                                   (file-name-directory
                                    (file-truename el-file)))
                 (mac-ime--module-download-path))))))

(defun mac-ime--get-module-version (path)
  "Extract the embedded version signature from the module at PATH."
  (when (file-readable-p path)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (goto-char (point-min))
      (when (re-search-forward "mac-ime-module-version:\\([0-9.]+\\)" nil t)
        (decode-coding-string (match-string 1) 'utf-8)))))


(defun mac-ime--report-error (msg)
  "Log MSG to `*Messages*`, display it as a warning, and signal an error."
  (message "%s" msg)
  (display-warning 'mac-ime msg :error)
  (error "%s" msg))

(defun mac-ime--delete-old-modules (keep)
  "Delete downloaded modules in `mac-ime-module-directory' except KEEP."
  (dolist (file (directory-files mac-ime-module-directory t
                                 "\\`mac-ime-module-[0-9.]+\\.so\\'"))
    (unless (file-equal-p file keep)
      (ignore-errors (delete-file file)))))

(defun mac-ime-download-module (&optional tag)
  "Download `mac-ime-module.so` from GitHub for TAG using curl.
If TAG is nil, it defaults to \"v<mac-ime-version>\".  The module is
saved in `mac-ime-module-directory' and older downloaded modules there
are deleted."
  (interactive (list (read-string "Tag/Branch: " (concat "v" mac-ime-version))))
  (let* ((tag (if (or (null tag) (string= tag ""))
                  (concat "v" mac-ime-version)
                tag))
         (url (format "https://raw.githubusercontent.com/%s/%s/mac-ime-module.so"
                       mac-ime-module-github-repo tag))
         (dest-path (mac-ime--module-download-path))
         (temp-path (concat dest-path ".tmp")))
    (unless (executable-find "curl")
      (mac-ime--report-error "mac-ime: `curl` command not found.  Please install curl or download the module manually"))
    (make-directory mac-ime-module-directory t)
    (message "mac-ime: Downloading mac-ime-module.so (%s) from GitHub..." tag)
    (with-temp-buffer
      (let ((exit-code (call-process "curl" nil '(t t) nil "-s" "-S" "-L" "-f" "-o" temp-path url)))
        (if (= exit-code 0)
            (let ((downloaded-ver (mac-ime--get-module-version temp-path)))
              (cond
               ((null downloaded-ver)
                (when (file-exists-p temp-path)
                  (delete-file temp-path))
                (mac-ime--report-error "mac-ime: Downloaded module does not contain a version signature"))
               ((not (string= mac-ime-required-module-version downloaded-ver))
                (when (file-exists-p temp-path)
                  (delete-file temp-path))
                (mac-ime--report-error (format "mac-ime: Downloaded module version `%s' does not match required `%s'"
                                               downloaded-ver mac-ime-required-module-version)))
               (t
                (rename-file temp-path dest-path t)
                (when (executable-find "xattr")
                  (ignore-errors
                    (call-process "xattr" nil nil nil "-d" "com.apple.quarantine" dest-path)))
                (mac-ime--delete-old-modules dest-path)
                (message "mac-ime: Successfully downloaded mac-ime-module.so for tag %s to %s"
                         tag dest-path)
                t)))
          (when (file-exists-p temp-path)
            (delete-file temp-path))
          (let ((err-msg (string-trim (buffer-string))))
            (mac-ime--report-error
             (if (> (length err-msg) 0)
                 (format "mac-ime: Failed to download mac-ime-module.so: %s" err-msg)
               (format "mac-ime: Failed to download mac-ime-module.so: curl exited with code %d" exit-code)))))))))

(defvar mac-ime-timer nil
  "Timer object for polling events.")

(defcustom mac-ime-functions nil
  "List of functions to call when a key event occurs.
Each function is called with five arguments:
\(KEYCODE MODIFIERS CHARACTERS CHARACTERS-IGNORING CONVERTING-P)."
  :type 'hook
  :group 'mac-ime)

(defconst mac-ime-NSEventModifierFlagCmd #x100008 "Modifier flag for Cmd key.")
(defconst mac-ime-NSEventModifierFlagRightCmd #x100010 "Modifier flag for Right Cmd key.")
(defconst mac-ime-NSEventModifierFlagControl #x40001 "Modifier flag for Control key.")
(defconst mac-ime-NSEventModifierFlagRightControl #x42000 "Modifier flag for Right Control key.")
(defconst mac-ime-NSEventModifierFlagOption #x80020 "Modifier flag for Option key.")
(defconst mac-ime-NSEventModifierFlagRightOption #x80040 "Modifier flag for Right Option key.")
(defconst mac-ime-NSEventModifierFlagFunction #x800000 "Modifier flag for Function key.")
(defconst mac-ime-NSEventModifierFlagAnyCmd #x100000 "Modifier flag for any Cmd key.")
(defconst mac-ime-NSEventModifierFlagAnyControl #x40000 "Modifier flag for any Control key.")
(defconst mac-ime-NSEventModifierFlagAnyOption #x80000 "Modifier flag for any Option key.")

(defconst mac-ime--modifier-symbols
  '(alt control hyper meta shift super)
  "Modifier symbols of the mac-*-modifier variables used for key events.
Other values, such as `none', make the key a shift-like modifier that
Emacs does not add to the event.")

(defun mac-ime--modifier-of-kind (value kind)
  "Return the modifier specified by VALUE for key events of KIND.
VALUE is the value of a mac-*-modifier variable.  It is either a
symbol or a plist such as (:ordinary SYMBOL :function SYMBOL :mouse
SYMBOL).  KIND is `:ordinary', `:function' or `:mouse'.  Return nil if
VALUE is a plist without a symbol for KIND."
  (if (symbolp value)
      value
    (let ((val (and (consp value) (plist-get value kind))))
      (and (symbolp val) val))))

(defun mac-ime-resolve-modifier-value (modifier-var &optional kind)
  "Return the Emacs modifier symbol specified by MODIFIER-VAR.
MODIFIER-VAR is a variable such as `mac-option-modifier'.  KIND is the
kind of the key event, `:ordinary' (the default) or `:function'.  It
selects the modifier when the value is a plist such as (:ordinary
SYMBOL :function SYMBOL :mouse SYMBOL).  If the modifier is `left', the
corresponding left key variable is used instead.  Like the NS port of
Emacs, a nil value means no modifier.  Return nil unless the modifier
is in `mac-ime--modifier-symbols', so values such as `none' never reach
`event-convert-list'."
  (let ((kind (or kind :ordinary))
        (val (if (boundp modifier-var)
                 ;; An explicit nil means no modifier, as in the NS port.
                 (symbol-value modifier-var)
               ;; Provide fallbacks for non-GUI / batch / headless test
               ;; environments where standard mac-* modifier variables
               ;; are not bound.
               (cond
                ((eq modifier-var 'mac-control-modifier) 'control)
                ((eq modifier-var 'mac-right-control-modifier) 'left)
                ((eq modifier-var 'mac-command-modifier) 'super)
                ((eq modifier-var 'mac-right-command-modifier) 'left)
                ((eq modifier-var 'mac-option-modifier) 'meta)
                ((eq modifier-var 'mac-right-option-modifier) 'left)
                (t nil)))))
    (setq val (mac-ime--modifier-of-kind val kind))
    (when (eq val 'left)
      (let* ((base-var-name (replace-regexp-in-string
                             "-right-" "-" (symbol-name modifier-var)))
             (base-var (intern base-var-name)))
        (setq val (mac-ime--modifier-of-kind
                   (if (boundp base-var)
                       (symbol-value base-var)
                     ;; If base var is not bound, use fallback
                     (cond
                      ((eq base-var 'mac-control-modifier) 'control)
                      ((eq base-var 'mac-command-modifier) 'super)
                      ((eq base-var 'mac-option-modifier) 'meta)
                      (t nil)))
                   kind))))
    (and (memq val mac-ime--modifier-symbols) val)))

(defun mac-ime--sided-modifiers (modifiers any-mask left-mask right-mask
                                           left-var right-var kind)
  "Return the Emacs modifiers for a key that has left and right variants.
MODIFIERS is the Cocoa modifier flags.  ANY-MASK is the
device-independent flag of the key.  LEFT-MASK and RIGHT-MASK are the
flags of the left and right keys.  LEFT-VAR and RIGHT-VAR are the
variables that hold the Emacs modifiers of the left and right keys.
KIND is the kind of the key event, `:ordinary' or `:function'.
Like the NS port of Emacs, the key is treated as the left key when
MODIFIERS does not tell which one is pressed."
  (let (result)
    (unless (zerop (logand modifiers any-mask))
      (let ((left-key (= (logand modifiers left-mask) left-mask))
            (right-key (= (logand modifiers right-mask) right-mask)))
        (when-let* ((right-key)
                    (mod (mac-ime-resolve-modifier-value right-var kind)))
          (push mod result))
        (when-let* (((or left-key (not right-key)))
                    (mod (mac-ime-resolve-modifier-value left-var kind)))
          (push mod result))))
    result))

(defun mac-ime--event-from-cocoa (modifiers chars chars-ignoring)
  "Convert a Cocoa key event to an Emacs event.
MODIFIERS is the Cocoa modifier flags.  CHARS is the string of
characters of the event.  CHARS-IGNORING is the string of characters
ignoring modifiers.  Like the NS port of Emacs, the mac-*-modifier
variables are looked up for the kind of the key, `:function' or
`:ordinary', the fn key is ignored for function keys, and the first
character of CHARS is used for an ordinary key without control-like
modifiers.  Return nil if CHARS-IGNORING is empty."
  (when (and chars-ignoring (> (length chars-ignoring) 0))
    (let* ((char-code (aref chars-ignoring 0))
           (base-key
            (cond
             ;; Special keys (macOS Cocoa key codes in Private Use Area)
             ((= char-code #xF700) 'up)
             ((= char-code #xF701) 'down)
             ((= char-code #xF702) 'left)
             ((= char-code #xF703) 'right)
             ((and (>= char-code #xF704) (<= char-code #xF726))
              (intern (format "f%d" (+ 1 (- char-code #xF704)))))
             ((= char-code #xF727) 'insert)
             ((= char-code #xF728) 'delete)
             ((= char-code #xF729) 'home)
             ((= char-code #xF72B) 'end)
             ((= char-code #xF72C) 'prior)
             ((= char-code #xF72D) 'next)
             ((= char-code #x001B) 'escape)
             ((= char-code #x000D) 'return)
             ((= char-code #x0009)
              (if (not (zerop (logand modifiers #x20000))) ; Shift bit
                  'backtab
                'tab))
             ((= char-code #x0019) 'backtab)
             ((or (= char-code #x007F) (= char-code #x0008)) 'backspace)
             (t char-code)))
           (kind (if (symbolp base-key) :function :ordinary))
           ;; Control, Command and Option keys
           (emacs-mods
            (append
             (mac-ime--sided-modifiers
              modifiers mac-ime-NSEventModifierFlagAnyControl
              mac-ime-NSEventModifierFlagControl
              mac-ime-NSEventModifierFlagRightControl
              'mac-control-modifier 'mac-right-control-modifier kind)
             (mac-ime--sided-modifiers
              modifiers mac-ime-NSEventModifierFlagAnyCmd
              mac-ime-NSEventModifierFlagCmd
              mac-ime-NSEventModifierFlagRightCmd
              'mac-command-modifier 'mac-right-command-modifier kind)
             (mac-ime--sided-modifiers
              modifiers mac-ime-NSEventModifierFlagAnyOption
              mac-ime-NSEventModifierFlagOption
              mac-ime-NSEventModifierFlagRightOption
              'mac-option-modifier 'mac-right-option-modifier kind))))

      ;; Function key.  Cocoa sets the flag on function keys such as the
      ;; arrow keys even if fn is not pressed, so the NS port of Emacs
      ;; ignores it for them.
      (when-let* (((eq kind :ordinary))
                  ((not (zerop (logand modifiers
                                       mac-ime-NSEventModifierFlagFunction))))
                  (mod (mac-ime-resolve-modifier-value
                        'mac-function-modifier kind)))
        (push mod emacs-mods))

      ;; Without control-like modifiers, Emacs receives the characters
      ;; typed with shift-like modifiers such as Option set to `none'.
      ;; With both kinds of modifiers, Emacs looks up the character with
      ;; UCKeyTranslate, which is approximated by CHARS-IGNORING here.
      ;; Control characters in CHARS are not used, because with Control
      ;; set to `none', Ctrl+x gives "\C-x" and would be taken as `C-x'.
      (when (and (eq kind :ordinary)
                 (null (remq 'shift emacs-mods))
                 chars
                 (> (length chars) 0)
                 (>= (aref chars 0) 32))
        (setq base-key (aref chars 0)))

      ;; Shift is handled if base-key is a symbol or control character
      (when (and (not (zerop (logand modifiers #x20000))) ; Shift bit (1 << 17)
                 (or (symbolp base-key)
                     (< base-key 32)
                     (= base-key 127)))
        (push 'shift emacs-mods))

      ;; Convert list to Emacs event
      (when emacs-mods
        (setq emacs-mods (delete-dups emacs-mods)))
      (if emacs-mods
          (event-convert-list (append emacs-mods (list base-key)))
        base-key))))

(defcustom mac-ime-no-ime-input-source-regexp "\\(keylayout\\|roman\\)"
  "Regexp matching input source IDs that indicate IME is off.
Case is ignored."
  :type 'regexp
  :group 'mac-ime)

(defcustom mac-ime-ime-off-input-source nil
  "Input source ID to switch to when a prefix key is pressed (to turn off IME).
If nil, `mac-ime-last-off-input-source` or the first input source matching
`mac-ime-no-ime-input-source-regexp` will be used."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Input Source ID"))
  :group 'mac-ime)

(defcustom mac-ime-ime-on-input-source nil
  "Input source ID to switch to when activating IME.
If nil, `mac-ime-last-on-input-source` or the first input source NOT matching
`mac-ime-no-ime-input-source-regexp` will be used."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Input Source ID"))
  :group 'mac-ime)

(defcustom mac-ime-ime-on-input-source-regexps '("romajityping" "japanese")
  "List of regexps matching input source IDs to prefer when turning on IME.
Regexps are checked in order.  The first one matching any available
input source will be chosen.

Note that this variable is evaluated only when `mac-ime-last-on-input-source'
is nil and `toggle-input-method' (or `activate-input-method') is called."
  :type '(repeat regexp)
  :group 'mac-ime)

(defcustom mac-ime-auto-deactivate-functions '((read-string . 4)
                                               (read-char . 1)
                                               (read-event . 1)
                                               (read-char-exclusive . 1)
                                               (read-char-choice . 2)
                                               (read-no-blanks-input . 2)
                                               (read-from-minibuffer . 6)
                                               (completing-read . 7)
                                               y-or-n-p
                                               yes-or-no-p
                                               map-y-or-n-p)
  "List of functions to automatically deactivate IME during execution.
Each element can be a function symbol or a cons cell (FUNCTION . ARG-INDEX).
If it is a cons cell, ARG-INDEX specifies the position of the
INHERIT-INPUT-METHOD argument.
If the current input method is `mac-ime-input-method` and the argument is nil
\(or not specified), IME is deactivated.  Otherwise, the IME state is not
changed."
  :type '(repeat (choice function (cons function integer)))
  :group 'mac-ime)

(defcustom mac-ime-temporary-deactivate-functions '(universal-argument--mode)
  "List of functions to temporarily deactivate IME before execution.
The IME state is restored in `pre-command-hook`.
 
Note: `universal-argument--mode` is used instead of `universal-argument`
because `universal-argument` is only called once.  `universal-argument--mode`
is called by `universal-argument`, `universal-argument-more`, and
`digit-argument`, ensuring IME is deactivated for the entire sequence."
  :type '(repeat function)
  :group 'mac-ime)

(defcustom mac-ime-poll-interval 0.1
  "Interval in seconds for polling input source events and status."
  :type 'number
  :group 'mac-ime)

(defcustom mac-ime-debug-level 0
  "Debug level for mac-ime.
0: No debug messages.
1: Output input keys.
2: Output function execution messages."
  :type 'integer
  :group 'mac-ime)

(defcustom mac-ime-title-rules
  '(("romajityping" . "[あ]")
    ("kanatyping" . "[かな]")
    (t . "[IME]"))
  "Alist of rules to determine the input method title based on the input source ID.
Each element is a cons cell (REGEXP . TITLE).  The input source ID is matched
against REGEXP (case-insensitive).  If REGEXP is t, it matches any input source
and serves as a default.  The first matching rule determines the title."
  :type '(alist :key-type (choice (string :tag "Regexp") (const :tag "Default" t))
                :value-type string)
  :group 'mac-ime)

(defvar mac-ime-last-on-input-source nil
  "The last used input source ID for IME ON.")

(defvar mac-ime-last-off-input-source nil
  "The last used input source ID for IME OFF.")

(defvar mac-ime--current-input-source nil
  "Cache of the current input source ID.")

(defvar mac-ime--ignore-input-source-change nil
  "If non-nil, `mac-ime--check-input-source-change` skips updates.
The last input source will not be updated.")

(defvar mac-ime--saved-input-source nil
  "Saved input source ID to restore.")

(defun mac-ime--debug (level format-string &rest args)
  "Output a debug message if `mac-ime-debug-level` is >= LEVEL.
FORMAT-STRING and ARGS are passed to `message`."
  (when (>= mac-ime-debug-level level)
    (let ((timestamp (format-time-string "%M:%S.%3N")))
      (apply #'message (concat (format "[%s] mac-ime [DEBUG]: " timestamp) format-string) args))))

(defun mac-ime--hex-string (str)
  "Return a space-separated hex representation of each character code in STR."
  (mapconcat (lambda (char) (format "%02X" char))
             str
             " "))

(defconst mac-ime--modifier-names
  '((#x10000 nil "Caps")
    (#x20000 ((#x02 . "LShift") (#x04 . "RShift")) "Shift")
    (#x40000 ((#x01 . "LCtrl") (#x2000 . "RCtrl")) "Ctrl")
    (#x80000 ((#x20 . "LOpt") (#x40 . "ROpt")) "Opt")
    (#x100000 ((#x08 . "LCmd") (#x10 . "RCmd")) "Cmd")
    (#x800000 nil "Fn"))
  "Table used to describe Cocoa modifier flags.
Each element is (FLAG SIDES NAME).  FLAG is the device-independent
flag, SIDES is an alist of (DEVICE-FLAG . SIDE-NAME) for left/right
keys, and NAME is used when no device-dependent flag is set.")

(defun mac-ime--modifier-string (modifiers)
  "Return a short description of the keys pressed in MODIFIERS.
MODIFIERS is the Cocoa modifier flags.  The result is a string such
as \"LCtrl+RShift\", or \"-\" when no modifier key is pressed."
  (let (names)
    (dolist (entry mac-ime--modifier-names)
      (when (/= 0 (logand modifiers (nth 0 entry)))
        (let (found)
          (dolist (side (nth 1 entry))
            (when (/= 0 (logand modifiers (car side)))
              (push (cdr side) names)
              (setq found t)))
          (unless found
            (push (nth 2 entry) names)))))
    (if names
        (mapconcat #'identity (nreverse names) "+")
      "-")))

(defun mac-ime--get-ime-off-input-source ()
  "Return the input source ID to use to turn off IME.
If `mac-ime-ime-off-input-source` is non-nil, return it.
Otherwise, use `mac-ime-last-off-input-source`.
If that is also nil, find the first input source matching
`mac-ime-no-ime-input-source-regexp` and cache it."
  (or mac-ime-ime-off-input-source
      mac-ime-last-off-input-source
      (setq mac-ime-last-off-input-source
            (cl-loop for source in (mac-ime-get-input-source-list)
                     if (let ((case-fold-search t))
                          (string-match-p mac-ime-no-ime-input-source-regexp source))
                     return source))))

(defun mac-ime--get-ime-on-input-source ()
  "Return the input source ID to use to turn on IME.
If `mac-ime-ime-on-input-source` is non-nil, return it.
Otherwise, use `mac-ime-last-on-input-source`.
If that is also nil, find the first input source matching one of the regexps
in `mac-ime-ime-on-input-source-regexps` in order.
If no match is found, find the first input source NOT matching
`mac-ime-no-ime-input-source-regexp` and cache it."
  (or mac-ime-ime-on-input-source
      mac-ime-last-on-input-source
      (setq mac-ime-last-on-input-source
            (let ((sources (mac-ime-get-input-source-list)))
              (or (cl-loop for regexp in mac-ime-ime-on-input-source-regexps
                           thereis (cl-loop for source in sources
                                            if (let ((case-fold-search t))
                                                 (string-match-p regexp source))
                                            return source))
                  (cl-loop for source in sources
                           if (not (let ((case-fold-search t))
                                     (string-match-p mac-ime-no-ime-input-source-regexp source)))
                           return source))))))

(defun mac-ime--restore-input-source ()
  "Restore the saved input source."
  (mac-ime--debug 2 "mac-ime--restore-input-source")
  (when mac-ime--saved-input-source
    (mac-ime-set-input-source mac-ime--saved-input-source)
    (setq mac-ime--saved-input-source nil))
  (setq mac-ime--ignore-input-source-change nil)
  (remove-hook 'pre-command-hook #'mac-ime--restore-input-source))

(defun mac-ime-deactivate-ime-temporarily ()
  "Deactivate IME temporarily.
The original input source is restored in `pre-command-hook`."
  (mac-ime--debug 2 "mac-ime-deactivate-ime-temporarily")
  (when (and (not mac-ime--saved-input-source)
             (equal current-input-method mac-ime-input-method))
    (let ((source (mac-ime--get-ime-off-input-source))
          (current (mac-ime-get-input-source)))
      (when (and source current (not (string= source current)))
        (setq mac-ime--saved-input-source current)
        (setq mac-ime--ignore-input-source-change t)
        (mac-ime-set-input-source source)
        ;; We need to restore the input source AFTER mac-ime-poll handles any pending events.
        ;; mac-ime-poll has a depth of -100, so we use 100 here to ensure this runs later.
        (add-hook 'pre-command-hook #'mac-ime--restore-input-source 100)))))

(defun mac-ime-deactivate-ime-on-prefix (_keycode modifiers characters characters-ignoring converting-p)
  "Deactivate IME when a prefix key in the current keymap is pressed.
This function is intended to be added to `mac-ime-functions`.
KEYCODE is the virtual key code.
MODIFIERS is the modifier flags.
CHARACTERS is the string of characters.
CHARACTERS-IGNORING is the string of characters ignoring modifiers.
CONVERTING-P is non-nil if IME is currently converting."
  (when (and (not mac-ime--saved-input-source)
             (equal current-input-method mac-ime-input-method)
             (not converting-p)
             characters-ignoring
             (> (length characters-ignoring) 0))
    (let ((event (mac-ime--event-from-cocoa modifiers characters characters-ignoring)))
      (when event
        (let ((binding (key-binding (vector event))))
          (when (or (keymapp binding)
                    ;; Try ASCII fallback for standard translated keys only if the key is not bound
                    (and (null binding)
                         (let ((translated (cond ((eq event 'escape) 27)
                                                 ((eq event 'tab) 9)
                                                 ((eq event 'return) 13)
                                                 ((eq event 'backspace) 127))))
                           (and translated (keymapp (key-binding (vector translated)))))))
            (mac-ime--debug 2 "mac-ime-deactivate-ime-on-prefix: Key %S (or translation) is bound to a keymap, deactivating IME" event)
            (mac-ime-deactivate-ime-temporarily)))))))

(defun mac-ime--module-problem (path)
  "Return a string describing why the module at PATH is unusable.
Return nil if PATH is a readable module with the required version."
  (cond
   ((not (file-exists-p path))
    "Module file not found")
   ((not (file-readable-p path))
    "Module file is not readable")
   (t
    (let ((module-ver (mac-ime--get-module-version path)))
      (cond
       ((null module-ver)
        "Module does not contain a version signature")
       ((not (string= mac-ime-required-module-version module-ver))
        (format "Module version `%s' does not match required `%s'"
                module-ver mac-ime-required-module-version)))))))

(defun mac-ime--check-quarantine (path)
  "Signal an error if the module at PATH has the quarantine attribute."
  (when (and (executable-find "xattr")
             (zerop (call-process "xattr" nil nil nil
                                  "-p" "com.apple.quarantine" path)))
    (mac-ime--report-error (format "mac-ime: Module `%s' has com.apple.quarantine and cannot be loaded.\nPlease run: xattr -d com.apple.quarantine %s" path path))))

(defun mac-ime--locate-module (&optional no-retry)
  "Return the path of a compatible dynamic module.
Search the paths returned by `mac-ime--module-candidates' and return
the first one that has the required version.  If none is found, offer
to download the module into `mac-ime-module-directory'.  If NO-RETRY
is non-nil, do not attempt to download the module.  Signal an error if
no compatible module is available or if it is quarantined."
  (let* ((candidates (mac-ime--module-candidates))
         (path (cl-find-if-not #'mac-ime--module-problem candidates)))
    (if path
        (progn
          (mac-ime--check-quarantine path)
          path)
      (let ((reason (or (cl-some (lambda (p)
                                   (and (file-exists-p p)
                                        (mac-ime--module-problem p)))
                                 candidates)
                        "Module file not found")))
        (if (and (not no-retry)
                 (not noninteractive)
                 (y-or-n-p (format "mac-ime: %s.  Download matching module from GitHub?" reason)))
            (progn
              (mac-ime-download-module)
              ;; Recheck after download, passing t to prevent infinite loop
              (mac-ime--locate-module t))
          (mac-ime--report-error (format "mac-ime: Cannot proceed without a compatible module (%s)" reason)))))))

(defun mac-ime--load-module ()
  "Load the dynamic module if not already loaded."
  (if (featurep 'mac-ime-module)
      ;; Already loaded: verify version compatibility of the loaded module (e.g. after package update)
      (let ((loaded-ver (mac-ime-internal-version)))
        (unless (string= mac-ime-required-module-version loaded-ver)
          (if (and (not (cl-find-if-not #'mac-ime--module-problem
                                        (mac-ime--module-candidates)))
                   (not noninteractive)
                   (y-or-n-p (format "mac-ime: Loaded module version `%s' does not match required `%s'.  Download updated module from GitHub?"
                                     loaded-ver mac-ime-required-module-version)))
              (progn
                (mac-ime-download-module)
                (mac-ime--report-error "mac-ime: Downloaded updated module.  Please restart Emacs to load the new module version"))
            (mac-ime--report-error (format "mac-ime: Loaded module version `%s' does not match required `%s'.  Please restart Emacs"
                                           loaded-ver mac-ime-required-module-version)))))
    ;; Not loaded: locate, verify and load
    (let ((path (mac-ime--locate-module)))
      (condition-case err
          (progn
            (module-load path)
            ;; Double check version at runtime
            (let ((loaded-ver (mac-ime-internal-version)))
              (unless (string= mac-ime-required-module-version loaded-ver)
                (mac-ime--report-error (format "Loaded module version `%s' does not match required `%s'"
                                               loaded-ver mac-ime-required-module-version)))))
        (error (mac-ime--report-error (format "mac-ime: Failed to load module `%s': %s"
                                              path
                                              (error-message-string err))))))))

(defvar mac-ime--last-selected-buffer nil
  "The buffer that was current during the last window selection change.")

(defun mac-ime--call-hook-function (func &rest args)
  "Call FUNC in `mac-ime-functions' with ARGS and return nil.
An error in FUNC is logged and does not stop the other functions or
the processing of the remaining key events."
  (condition-case err
      (apply func args)
    (error
     (message "mac-ime: Error in `mac-ime-functions' (%S): %s"
              func (error-message-string err))))
  nil)

(defun mac-ime-handler (keycode modifiers characters characters-ignoring converting-p)
  "Internal handler called by the C module.
Calls functions in `mac-ime-functions`.
KEYCODE is the virtual key code.
MODIFIERS is the modifier flags.
CHARACTERS is the string of characters.
CHARACTERS-IGNORING is the string of characters ignoring modifiers.
CONVERTING-P is non-nil if IME is currently converting."
  (mac-ime--debug 1 "Key event: keycode=%d, modifiers=%d (%s), characters=%s [%s], characters-ignoring=%s [%s], converting=%s"
                  keycode modifiers (mac-ime--modifier-string modifiers)
                  characters (mac-ime--hex-string characters)
                  characters-ignoring (mac-ime--hex-string characters-ignoring)
                  converting-p)
  (when (>= keycode 0)
    (run-hook-wrapped 'mac-ime-functions #'mac-ime--call-hook-function
                      keycode modifiers characters characters-ignoring converting-p))
  ;; Skip synchronization if the buffer has changed recently.
  ;; This prevents race conditions where the poll runs before window-selection-change-functions.
  (let ((current (current-buffer)))
    (when (eq current mac-ime--last-selected-buffer)
      (mac-ime--check-input-source-change)
      (mac-ime--sync-input-method))))
  

(defun mac-ime--check-input-source-change ()
  "Check if input source has changed and update last used input sources.
Updates `mac-ime-last-on-input-source` and `mac-ime-last-off-input-source`.
Input sources matching `mac-ime-no-ime-input-source-regexp` are saved to
off-source, others to on-source."
  (unless mac-ime--ignore-input-source-change
    (let ((current (mac-ime-get-input-source)))
      (when (and current
                 (not (string= current mac-ime--current-input-source)))
        (let ((case-fold-search t))
          (if (string-match-p mac-ime-no-ime-input-source-regexp current)
              (setq mac-ime-last-off-input-source current)
            (setq mac-ime-last-on-input-source current))))
      (setq mac-ime--current-input-source current))))

(defun mac-ime-poll ()
  "Poll the C module for events."
  (when (featurep 'mac-ime-module)
    (mac-ime-internal-poll #'mac-ime-handler)))

(defun mac-ime-activate-input-method (input-method)
  "Activate the mac-ime input method.
INPUT-METHOD is the name of the input method to activate."
  (mac-ime--debug 2 "mac-ime-activate-input-method called in %s buffer %s" input-method (current-buffer))
  (mac-ime-activate-ime)
  (setq deactivate-current-input-method-function #'mac-ime-deactivate-ime)
  (when-let* ((source (mac-ime-get-input-source)))
    (mac-ime--update-title source)))

(defun mac-ime-update-state (&optional _window)
  "Update IME state based on the current input method.
Activate IME if `current-input-method` is `mac-ime-input-method`.
Otherwise, deactivate IME."
  (mac-ime--debug 2 "mac-ime-update-state: current-input-method=%s buffer=%s" current-input-method (current-buffer))
  (setq mac-ime--last-selected-buffer (current-buffer))
  (unless mac-ime--ignore-input-source-change
    (if (equal current-input-method mac-ime-input-method)
        (mac-ime-activate-ime)
      (mac-ime-deactivate-ime))))

;;;###autoload
(defun mac-ime-enable ()
  "Enable the global key monitor."
  (interactive)
  (mac-ime--debug 2 "mac-ime-enable called")
  (mac-ime--load-module)
  (when (featurep 'mac-ime-module)
    (register-input-method mac-ime-input-method "Japanese" #'mac-ime-activate-input-method "[こ]" "macOS System IME")
    (mac-ime-internal-start)
    (unless mac-ime-timer
      (setq mac-ime-timer (run-with-timer 0 mac-ime-poll-interval #'mac-ime-poll))
      ;; Use a negative depth (-100) to ensure mac-ime-poll runs BEFORE other hooks,
      ;; specifically before mac-ime--restore-input-source (which has depth 100).
      ;; This prevents the IME from being restored before the poll can detect the event.
      (add-hook 'pre-command-hook #'mac-ime-poll -100)
      (add-hook 'mac-ime-functions #'mac-ime-deactivate-ime-on-prefix)
      (dolist (func mac-ime-auto-deactivate-functions)
        (mac-ime-auto-deactivate func))
      (dolist (func mac-ime-temporary-deactivate-functions)
        (mac-ime-temporary-deactivate func))
      (add-hook 'window-selection-change-functions #'mac-ime-update-state)
      (add-hook 'window-buffer-change-functions #'mac-ime-update-state)
      (add-function :after after-focus-change-function #'mac-ime--on-focus)
      (message "mac-ime enabled."))))

;;;###autoload
(defun mac-ime-disable ()
  "Disable the global key monitor."
  (interactive)
  (mac-ime--debug 2 "mac-ime-disable called")
  (when mac-ime-timer
    (cancel-timer mac-ime-timer)
    (setq mac-ime-timer nil))
  (remove-hook 'pre-command-hook #'mac-ime-poll)
  (when (featurep 'mac-ime-module)
    (remove-hook 'mac-ime-functions #'mac-ime-deactivate-ime-on-prefix)
    (mac-ime-internal-stop)
    (dolist (func mac-ime-auto-deactivate-functions)
      (let* ((f-sym (if (consp func) (car func) func))
             (advice-name (intern (format "mac-ime--auto-deactivate-%s" f-sym))))
        (advice-remove f-sym advice-name)))
    (dolist (func mac-ime-temporary-deactivate-functions)
      (advice-remove func #'mac-ime--temporary-deactivate-advice))
    (remove-function after-focus-change-function #'mac-ime--on-focus)
    (remove-hook 'window-selection-change-functions #'mac-ime-update-state)
    (remove-hook 'window-buffer-change-functions #'mac-ime-update-state)
    (message "mac-ime disabled.")))

(defun mac-ime-get-input-source ()
  "Get the current input source ID."
  (when (featurep 'mac-ime-module)
    (mac-ime-internal-get-input-source)))

(defun mac-ime-set-input-source (source-id)
  "Set the current input source to SOURCE-ID."
  (mac-ime--debug 2 "mac-ime-set-input-source: %s" source-id)
  (when (featurep 'mac-ime-module)
    (mac-ime-internal-set-input-source source-id)))

(defun mac-ime-get-input-source-list ()
  "Get a list of all selectable input source IDs."
  (when (featurep 'mac-ime-module)
    (mac-ime-internal-get-input-source-list)))

(defun mac-ime--auto-deactivate-body (orig-fun args config)
  "Body of the auto-deactivate advice.
ORIG-FUN is the original function.
ARGS are the arguments.
CONFIG is the configuration (symbol or cons)."
  (mac-ime--debug 2 "mac-ime--auto-deactivate-body called with config %s" config)
  (let* ((inherit-index (if (consp config) (cdr config) nil))
         (should-inherit (and inherit-index (nth inherit-index args)))
         (should-deactivate
          (and (equal current-input-method mac-ime-input-method)
               (not should-inherit))))
    (if should-deactivate
        (let ((saved-source (mac-ime-get-input-source))
              (off-source (mac-ime--get-ime-off-input-source)))
          (if (and off-source saved-source)
              (progn
                (setq mac-ime--ignore-input-source-change t)
                (mac-ime-set-input-source off-source)
                (unwind-protect
                    (apply orig-fun args)
                  (mac-ime--debug 2 "mac-ime--auto-deactivate-body Restoring input source to %s" saved-source)
                  (mac-ime-set-input-source saved-source)
                  (setq mac-ime--ignore-input-source-change nil)))
            (apply orig-fun args)))
      (apply orig-fun args))))

(defun mac-ime-auto-deactivate (func)
  "Add advice to FUNC to deactivate IME during its execution.
FUNC can be a function symbol or a cons cell (FUNCTION . ARG-INDEX).
If it is a cons cell, ARG-INDEX specifies the position of the
INHERIT-INPUT-METHOD argument.  If the current input method is
`mac-ime-input-method` and the argument is nil (or not specified), IME is
deactivated.  Otherwise, the IME state is not changed.
The IME state is restored after FUNC completes."
  (let* ((f-sym (if (consp func) (car func) func))
         (advice-name (intern (format "mac-ime--auto-deactivate-%s" f-sym))))
    (fset advice-name
          (lambda (orig-fun &rest args)
            (mac-ime--auto-deactivate-body orig-fun args func)))
    (advice-add f-sym :around advice-name)))

(defun mac-ime--temporary-deactivate-advice (&rest _args)
  "Advice to deactivate IME temporarily."
  (mac-ime-deactivate-ime-temporarily))

(defun mac-ime-temporary-deactivate (func)
  "Add advice to FUNC to deactivate IME temporarily before its execution."
  (advice-add func :before #'mac-ime--temporary-deactivate-advice))

(defvar mac-ime--sync-paused nil
  "Whether input method synchronization is paused.")

(defvar mac-ime--expected-input-source nil
  "The expected input source ID when synchronization is paused.")

(defun mac-ime--update-title (input-source)
  "Update `current-input-method-title' based on INPUT-SOURCE.
The rules to determine the title are specified by `mac-ime-title-rules'."
  (let ((title (cl-loop for (regexp . t-str) in mac-ime-title-rules
                        if (or (eq regexp t)
                               (and (stringp regexp)
                                    (let ((case-fold-search t))
                                      (string-match-p regexp input-source))))
                        return t-str)))
    (when title
      (setq current-input-method-title title)
      (force-mode-line-update))))

(defun mac-ime--on-focus ()
  "Handler for focus change.
Resets sync state and synchronizes input method."
  (when (frame-focus-state)
    (mac-ime--debug 2 "mac-ime--on-focus called")
    (setq mac-ime--sync-paused nil
          mac-ime--expected-input-source nil)
    (mac-ime--check-input-source-change)
    (mac-ime--sync-input-method)))

(defun mac-ime--sync-input-method ()
  "Synchronize `current-input-method` with the macOS input source."
  (unless (or mac-ime--saved-input-source
              mac-ime--ignore-input-source-change)
    (let ((current-source (mac-ime-get-input-source)))
      (when current-source
        (if mac-ime--sync-paused
            (when (and mac-ime--expected-input-source
                       (string= current-source mac-ime--expected-input-source))
              (mac-ime--debug 2 "mac-ime--sync-input-method: sync resumed (reached expected source: %s)" current-source)
              (setq mac-ime--sync-paused nil
                    mac-ime--expected-input-source nil)
              (when (equal current-input-method mac-ime-input-method)
                (mac-ime--update-title current-source)))
          (let ((case-fold-search t))
            (if (string-match-p mac-ime-no-ime-input-source-regexp current-source)
                (when (equal current-input-method mac-ime-input-method)
                  (mac-ime--debug 2 "mac-ime--sync-input-method: deactivating input method (source: %s buffer=%s)" current-source (current-buffer))
                  (deactivate-input-method))
              (unless (equal current-input-method mac-ime-input-method)
                (mac-ime--debug 2 "mac-ime--sync-input-method: activating input method (source: %s) buffer=%s" current-source (current-buffer))
                (activate-input-method mac-ime-input-method))
              (when (equal current-input-method mac-ime-input-method)
                (mac-ime--update-title current-source)))))))))

(defun mac-ime-activate-ime ()
  "Activate the IME input source.
Uses `mac-ime--get-ime-on-input-source` to determine the input source."
  (interactive)
  (let ((source (mac-ime--get-ime-on-input-source))
        (current (mac-ime-get-input-source)))
    (mac-ime--debug 2 "mac-ime-activate-ime: source=%s (current=%s) buffer=%s" source current (current-buffer))
    (when (and source current (not (string= source current)))
      (mac-ime-set-input-source source)
      (setq mac-ime--sync-paused t
            mac-ime--expected-input-source source))))

(defun mac-ime-deactivate-ime ()
  "Deactivate the IME input source.
Uses `mac-ime--get-ime-off-input-source` to determine the input source."
  (interactive)
  (let ((source (mac-ime--get-ime-off-input-source))
        (current (mac-ime-get-input-source)))
    (mac-ime--debug 2 "mac-ime-deactivate-ime: source=%s (current=%s) buffer=%s" source current (current-buffer))
    (when (and source current (not (string= source current)))
      (mac-ime-set-input-source source)
      (setq mac-ime--sync-paused t
            mac-ime--expected-input-source source))))

(defun mac-ime-unload-function ()
  "Cleanup mac-ime state before unloading this feature.
This function disables hooks, timers, and advices via
`mac-ime-disable`."
  (mac-ime-disable)
  nil)
      
;; Verify already-loaded module version at package load time
(when (featurep 'mac-ime-module)
  (let ((loaded-ver (mac-ime-internal-version)))
    (unless (string= mac-ime-required-module-version loaded-ver)
      ;; Use a timer to delay the warning display until the load process completes,
      ;; ensuring the warning buffer is popped up (split window) properly.
      (run-with-timer 0.1 nil
                      (lambda ()
                        (display-warning 'mac-ime
                                         (format "Loaded module version `%s' does not match required `%s'.\n\nPlease restart Emacs to complete the update."
                                                 loaded-ver mac-ime-required-module-version)
                                         :error))))))

(provide 'mac-ime)
;;; mac-ime.el ends here
