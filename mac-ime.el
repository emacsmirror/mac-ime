;;; mac-ime.el --- NSEvent hook for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Masami
;; Author: Masami Iwata
;; Version: 0.1.6
;; Keywords: mac, input, ime
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/ma0001/mac-ime

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This package provides a way to hook into macOS global key events
;; using a dynamic module.  It is intended to be used for IME integration.

;;; Code:

(require 'cl-lib)
(require 'nadvice)

(declare-function mac-ime-internal-get-input-source-list nil ())
(declare-function mac-ime-internal-get-input-source nil ())
(declare-function mac-ime-internal-set-input-source nil (source-id))
(declare-function mac-ime-internal-poll nil (hook-func))
(declare-function mac-ime-internal-start nil ())
(declare-function mac-ime-internal-stop nil ())

(defconst mac-ime-input-method "mac-ime"
  "Name of the mac-ime input method.")

(defvar mac-ime-module-file "mac-ime-module.so"
  "Name of the dynamic module file.")

(defvar mac-ime-module-path
  (expand-file-name mac-ime-module-file
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Full path to the dynamic module.")

(defvar mac-ime-timer nil
  "Timer object for polling events.")

(defcustom mac-ime-functions nil
  "List of functions to call when a key event occurs.
Each function is called with five arguments: (KEYCODE MODIFIERS CHARACTERS CHARACTERS-IGNORING CONVERTING-P)."
  :type 'hook
  :group 'mac-ime)

(defconst mac-ime-NSEventModifierFlagCmd #x100108 "Modifier flag for Cmd key.")
(defconst mac-ime-NSEventModifierFlagRightCmd #x100110 "Modifier flag for Right Cmd key.")
(defconst mac-ime-NSEventModifierFlagControl #x40101 "Modifier flag for Control key.")
(defconst mac-ime-NSEventModifierFlagRightControl #x42100 "Modifier flag for Right Control key.")
(defconst mac-ime-NSEventModifierFlagOption #x80120 "Modifier flag for Option key.")
(defconst mac-ime-NSEventModifierFlagRightOption #x80140 "Modifier flag for Right Option key.")
(defconst mac-ime-NSEventModifierFlagFunction #x800100 "Modifier flag for Function key.")

(defun mac-ime-resolve-modifier-value (modifier-var)
  "Resolve the value of MODIFIER-VAR, handling `left' inheritance."
  (let ((val (if (boundp modifier-var) (symbol-value modifier-var) nil)))
    (if (eq val 'left)
        (let ((base-var-name (replace-regexp-in-string "-right-" "-" (symbol-name modifier-var))))
          (let ((base-var (intern base-var-name)))
            (if (boundp base-var)
                (symbol-value base-var)
              val)))
      val)))

(defun mac-ime--event-from-cocoa (modifiers chars chars-ignoring)
  "Convert Cocoa MODIFIERS, CHARS, and CHARS-IGNORING to an Emacs event."
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
           (emacs-mods '()))

      ;; Control keys
      (when (and (= (logand modifiers mac-ime-NSEventModifierFlagControl) mac-ime-NSEventModifierFlagControl)
                 (mac-ime-resolve-modifier-value 'mac-control-modifier))
        (push (mac-ime-resolve-modifier-value 'mac-control-modifier) emacs-mods))
      (when (and (= (logand modifiers mac-ime-NSEventModifierFlagRightControl) mac-ime-NSEventModifierFlagRightControl)
                 (mac-ime-resolve-modifier-value 'mac-right-control-modifier))
        (push (mac-ime-resolve-modifier-value 'mac-right-control-modifier) emacs-mods))

      ;; Command keys
      (when (and (= (logand modifiers mac-ime-NSEventModifierFlagCmd) mac-ime-NSEventModifierFlagCmd)
                 (mac-ime-resolve-modifier-value 'mac-command-modifier))
        (push (mac-ime-resolve-modifier-value 'mac-command-modifier) emacs-mods))
      (when (and (= (logand modifiers mac-ime-NSEventModifierFlagRightCmd) mac-ime-NSEventModifierFlagRightCmd)
                 (mac-ime-resolve-modifier-value 'mac-right-command-modifier))
        (push (mac-ime-resolve-modifier-value 'mac-right-command-modifier) emacs-mods))

      ;; Option/Meta keys
      (when (and (= (logand modifiers mac-ime-NSEventModifierFlagOption) mac-ime-NSEventModifierFlagOption)
                 (mac-ime-resolve-modifier-value 'mac-option-modifier))
        (push (mac-ime-resolve-modifier-value 'mac-option-modifier) emacs-mods))
      (when (and (= (logand modifiers mac-ime-NSEventModifierFlagRightOption) mac-ime-NSEventModifierFlagRightOption)
                 (mac-ime-resolve-modifier-value 'mac-right-option-modifier))
        (push (mac-ime-resolve-modifier-value 'mac-right-option-modifier) emacs-mods))

      ;; Function key
      (when (and (= (logand modifiers mac-ime-NSEventModifierFlagFunction) mac-ime-NSEventModifierFlagFunction)
                 (mac-ime-resolve-modifier-value 'mac-function-modifier))
        (push (mac-ime-resolve-modifier-value 'mac-function-modifier) emacs-mods))

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
(or not specified), IME is deactivated.  Otherwise, the IME state is not
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

(defun mac-ime-deactivate-ime-on-prefix (keycode modifiers characters characters-ignoring converting-p)
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

(defun mac-ime--load-module ()
  "Load the dynamic module if not already loaded."
  (unless (featurep 'mac-ime-module)
    (if (file-exists-p mac-ime-module-path)
        (condition-case err
            (module-load mac-ime-module-path)
          (error (concat "mac-ime: Failed to load module `%s': %s\n"
                         "Hint: On macOS, this can be caused by quarantine.\n"
                         "Try: xattr -d com.apple.quarantine %s")
                 mac-ime-module-path
                 (error-message-string err)
                 mac-ime-module-path))
      (error "mac-ime: Module not found at %s" mac-ime-module-path))))

(defvar mac-ime--last-selected-buffer nil
  "The buffer that was current during the last window selection change.")

(defun mac-ime-handler (keycode modifiers characters characters-ignoring converting-p)
  "Internal handler called by the C module.
Calls functions in `mac-ime-functions`.
KEYCODE is the virtual key code.
MODIFIERS is the modifier flags.
CHARACTERS is the string of characters.
CHARACTERS-IGNORING is the string of characters ignoring modifiers.
CONVERTING-P is non-nil if IME is currently converting."
  (mac-ime--debug 1 "Key event: keycode=%d, modifiers=%d, characters=%s, characters-ignoring=%s, converting=%s"
                  keycode modifiers characters characters-ignoring converting-p)
  (when (>= keycode 0)
    (run-hook-with-args 'mac-ime-functions keycode modifiers characters characters-ignoring converting-p))
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
  (when-let ((source (mac-ime-get-input-source)))
    (mac-ime--update-title source)))

(register-input-method mac-ime-input-method "Japanese" 'mac-ime-activate-input-method "[こ]" "macOS System IME")

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
    (message "mac-ime disabled.")))

;;;###autoload
(defun mac-ime-get-input-source ()
  "Get the current input source ID."
  (mac-ime--load-module)
  (when (featurep 'mac-ime-module)
    (mac-ime-internal-get-input-source)))

;;;###autoload
(defun mac-ime-set-input-source (source-id)
  "Set the current input source to SOURCE-ID."
  (mac-ime--debug 2 "mac-ime-set-input-source: %s" source-id)
  (mac-ime--load-module)
  (when (featurep 'mac-ime-module)
    (mac-ime-internal-set-input-source source-id)))

;;;###autoload
(defun mac-ime-get-input-source-list ()
  "Get a list of all selectable input source IDs."
  (mac-ime--load-module)
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

;;;###autoload
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

;;;###autoload
(defun mac-ime-temporary-deactivate (func)
  "Add advice to FUNC to deactivate IME temporarily before its execution."
  (advice-add func :before #'mac-ime--temporary-deactivate-advice))

(defvar mac-ime--sync-paused nil
  "Whether input method synchronization is paused.")

(defvar mac-ime--expected-input-source nil
  "The expected input source ID when synchronization is paused.")

(defun mac-ime--update-title (input-source)
  "Update `current-input-method-title`.
based on INPUT-SOURCE and `mac-ime-title-rules`."
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
  (unless mac-ime--saved-input-source
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

;;;###autoload
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

;;;###autoload
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
      
(provide 'mac-ime)
;;; mac-ime.el ends here
