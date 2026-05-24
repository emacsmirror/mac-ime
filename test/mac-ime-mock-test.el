;;; mac-ime-test.el --- Tests for mac-ime -*- lexical-binding: t; no-byte-compile: t; -*-

(setq load-prefer-newer t)

(require 'ert)
(require 'mac-ime)

;; Add test directory to load-path to find mac-ime-mock
(eval-and-compile
  (add-to-list 'load-path (file-name-directory (or load-file-name byte-compile-current-file buffer-file-name)))
  (require 'mac-ime-mock))

;; Declare test function to silence complier warning
(defun mac-ime-test-func () nil)

;; Enable mock only when not compiling
(unless (bound-and-true-p byte-compile-current-file)
  (mac-ime-mock-enable))

(defun mac-ime-test-reset ()
  "Reset both mock and mac-ime internal state."
  (mac-ime-mock-reset)
  (setq mac-ime--saved-input-source nil
        mac-ime--sync-paused nil
        mac-ime--expected-input-source nil
        mac-ime--current-input-source nil
        mac-ime-last-on-input-source nil
        mac-ime-last-off-input-source nil
        mac-ime--ignore-input-source-change nil
        current-input-method nil
        mac-ime-functions nil
        mac-ime-debug-level 2))

(ert-deftest mac-ime-mock-basic-test ()
  "Test basic mock functionality."
  (mac-ime-test-reset)
  (should (equal (mac-ime-internal-start) t))
  (should mac-ime-mock-running)
  (should (equal (mac-ime-internal-stop) t))
  (should-not mac-ime-mock-running))

(ert-deftest mac-ime-mock-input-source-test ()
  "Test input source get/set with mock."
  (mac-ime-test-reset)
  (should (equal (mac-ime-internal-get-input-source) "com.apple.keylayout.US"))
  (should (mac-ime-internal-set-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping"))
  (should (equal (mac-ime-internal-get-input-source) "com.apple.inputmethod.Kotoeri.RomajiTyping"))
  (should-not (mac-ime-internal-set-input-source "invalid.source")))

(ert-deftest mac-ime-event-handling-test ()
  "Test event handling via poll."
  (mac-ime-test-reset)
  (mac-ime-internal-start)
  
  (let ((called nil))
    (add-hook 'mac-ime-functions (lambda (k m c ci cv) (setq called (list k m c ci cv))))
    
    ;; Simulate 'x' key (keycode 7) with no modifiers
    (mac-ime-mock-simulate-event 7 0 "x" "x")
    
    ;; Poll should trigger the hook
    (mac-ime-poll)
    
    (should (equal called '(7 0 "x" "x" nil)))))

(ert-deftest mac-ime-auto-deactivate-on-prefix-test ()
  "Test automatic IME deactivation on prefix key."
  (mac-ime-test-reset)
  ;; Setup: IME is ON
  (mac-ime-internal-set-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping")
  (setq current-input-method mac-ime-input-method)
  (setq mac-ime-last-off-input-source "com.apple.keylayout.US")
  
  (add-hook 'mac-ime-functions #'mac-ime-deactivate-ime-on-prefix)
  
  ;; Simulate C-x (Control flag, characters = "\x18", charactersIgnoring = "x")
  (mac-ime-mock-simulate-event 7 mac-ime-NSEventModifierFlagControl "\x18" "x")
  
  ;; Poll
  (mac-ime-poll)
  
  ;; Check if IME was deactivated (input source changed to US)
  (should (equal (mac-ime-internal-get-input-source) "com.apple.keylayout.US"))
  
  ;; Run pre-command-hook to restore IME
  (run-hooks 'pre-command-hook)
  
  ;; Check if IME was restored
  (should (equal (mac-ime-internal-get-input-source) "com.apple.inputmethod.Kotoeri.RomajiTyping")))

(ert-deftest mac-ime-auto-deactivate-on-prefix-esc-test ()
  "Test automatic IME deactivation on Escape prefix key."
  (mac-ime-test-reset)
  ;; Setup: IME is ON
  (mac-ime-internal-set-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping")
  (setq current-input-method mac-ime-input-method)
  (setq mac-ime-last-off-input-source "com.apple.keylayout.US")
  
  (add-hook 'mac-ime-functions #'mac-ime-deactivate-ime-on-prefix)
  
  ;; Simulate ESC (keycode 53, no modifiers, characters = "\x1b", charactersIgnoring = "\x1b")
  (mac-ime-mock-simulate-event 53 0 "\x1b" "\x1b")
  
  ;; Poll
  (mac-ime-poll)
  
  ;; Check if IME was deactivated (input source changed to US)
  (should (equal (mac-ime-internal-get-input-source) "com.apple.keylayout.US"))
  
  ;; Run pre-command-hook to restore IME
  (run-hooks 'pre-command-hook)
  
  ;; Check if IME was restored
  (should (equal (mac-ime-internal-get-input-source) "com.apple.inputmethod.Kotoeri.RomajiTyping")))

(ert-deftest mac-ime-no-deactivate-on-non-prefix-test ()
  "Test that IME is not deactivated when a non-prefix key is pressed."
  (mac-ime-test-reset)
  ;; Setup: IME is ON
  (mac-ime-internal-set-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping")
  (setq current-input-method mac-ime-input-method)
  (setq mac-ime-last-off-input-source "com.apple.keylayout.US")
  
  (add-hook 'mac-ime-functions #'mac-ime-deactivate-ime-on-prefix)
  
  ;; Simulate 'a' key (keycode 0, no modifiers, characters = "a", charactersIgnoring = "a")
  (mac-ime-mock-simulate-event 0 0 "a" "a")
  
  ;; Poll
  (mac-ime-poll)
  
  ;; Check if IME was NOT deactivated (input source remains RomajiTyping)
  (should (equal (mac-ime-internal-get-input-source) "com.apple.inputmethod.Kotoeri.RomajiTyping")))

(ert-deftest mac-ime-focus-change-test ()
  "Test focus change handling."
  (mac-ime-test-reset)
  (mac-ime-enable)
  (setq mac-ime--sync-paused t)
  (setq mac-ime--expected-input-source "some-source")
  
  ;; Mock frame-focus-state to return t
  (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _frame) t)))
    (funcall after-focus-change-function))
  
  (should-not mac-ime--sync-paused)
  (should-not mac-ime--expected-input-source)
  (mac-ime-disable))

(ert-deftest mac-ime-focus-change-sync-kana-test ()
  "Test that focus change with a new external IME source updates cache and does not revert."
  (mac-ime-test-reset)
  (mac-ime-enable)
  
  ;; Setup: Last ON source was RomajiTyping.
  (setq mac-ime-last-on-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping")
  (setq mac-ime--current-input-source "com.apple.keylayout.US")
  (setq current-input-method nil)
  
  ;; OS input source is changed externally to KanaTyping (which is ON source)
  (mac-ime-internal-set-input-source "com.apple.inputmethod.Kotoeri.KanaTyping")
  
  ;; Simulate focus change (Emacs becomes active)
  (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _frame) t)))
    (funcall after-focus-change-function))
  
  ;; Check that last ON source is updated to KanaTyping
  (should (equal mac-ime-last-on-input-source "com.apple.inputmethod.Kotoeri.KanaTyping"))
  
  ;; Check that input method is activated
  (should (equal current-input-method mac-ime-input-method))
  
  ;; Check that OS input source was NOT reverted to RomajiTyping
  (should (equal (mac-ime-internal-get-input-source) "com.apple.inputmethod.Kotoeri.KanaTyping"))
  
  (mac-ime-disable))

(ert-deftest mac-ime-unload-function-cleans-up-test ()
  "Test that `mac-ime-unload-function` cleans up runtime state."
  (mac-ime-test-reset)
  (mac-ime-enable)

  (let ((read-string-advice (intern "mac-ime--auto-deactivate-read-string")))
    (should mac-ime-timer)
    (should (member #'mac-ime-poll pre-command-hook))
    (should (member #'mac-ime-update-state
                    window-selection-change-functions))
    (should (advice-member-p #'mac-ime--temporary-deactivate-advice
                             'universal-argument--mode))
    (should (advice-member-p read-string-advice 'read-string))

    (should-not (mac-ime-unload-function))

    (should-not mac-ime-timer)
    (should-not (member #'mac-ime-poll pre-command-hook))
    (should-not (member #'mac-ime-update-state
                        window-selection-change-functions))
    (should-not (advice-member-p #'mac-ime--temporary-deactivate-advice
                                 'universal-argument--mode))
    (should-not (advice-member-p read-string-advice 'read-string))))

(ert-deftest mac-ime-auto-deactivate-functions-test ()
  "Test automatic IME deactivation for specific functions."
  (mac-ime-test-reset)
  ;; Setup: IME is ON
  (mac-ime-internal-set-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping")
  (setq current-input-method mac-ime-input-method)
  (setq mac-ime-last-off-input-source "com.apple.keylayout.US")
  
  (let ((inner-source nil))
    ;; Redefine function cleanly for tests
    (defalias 'mac-ime-test-func
      (lambda () (setq inner-source (mac-ime-internal-get-input-source))))
    
    ;; Register function
    (mac-ime-auto-deactivate 'mac-ime-test-func)
    
    ;; Call function
    (mac-ime-test-func)
    
    ;; Check if IME was deactivated inside the function
    (should (equal inner-source "com.apple.keylayout.US"))
    
    ;; Check if IME was restored after the function
    (should (equal (mac-ime-internal-get-input-source) "com.apple.inputmethod.Kotoeri.RomajiTyping"))
    
    ;; Cleanup advice
    (advice-remove 'mac-ime-test-func (intern "mac-ime--auto-deactivate-mac-ime-test-func"))
    (fmakunbound 'mac-ime-test-func)))

(ert-deftest mac-ime-sync-state-test ()
  "Test synchronization of Emacs input method state with OS input source."
  (mac-ime-test-reset)
  
  ;; Case 1: OS changes to Japanese -> Emacs should activate mac-ime
  (mac-ime-internal-set-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping")
  
  ;; Trigger sync (activates IME, sets paused=t, expected=RomajiTyping)
  (mac-ime--sync-input-method)
  
  (should (equal current-input-method mac-ime-input-method))
  
  ;; Resolve paused state
  ;; The mock set-input-source was called by activate-ime, so current source is RomajiTyping.
  ;; Calling sync again should match expected source and clear paused.
  (mac-ime--sync-input-method)
  (should-not mac-ime--sync-paused)
  
  ;; Case 2: OS changes to US -> Emacs should deactivate mac-ime
  (mac-ime-internal-set-input-source "com.apple.keylayout.US")
  (mac-ime--sync-input-method)
  
  (should (equal current-input-method nil)))


(ert-deftest mac-ime-auto-deactivate-on-prefix-converting-test ()
  "Test that IME deactivation on prefix key is skipped when converting."
  (mac-ime-test-reset)
  ;; Setup: IME is ON
  (mac-ime-internal-set-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping")
  (setq current-input-method mac-ime-input-method)
  (setq mac-ime-last-off-input-source "com.apple.keylayout.US")
  
  (add-hook 'mac-ime-functions #'mac-ime-deactivate-ime-on-prefix)
  
  ;; Set Converting to TRUE
  (setq mac-ime-mock-converting t)

  ;; Simulate C-x (Control flag, characters = "\x18", charactersIgnoring = "x")
  (mac-ime-mock-simulate-event 7 mac-ime-NSEventModifierFlagControl "\x18" "x")
  
  ;; Poll
  (mac-ime-poll)
  
  ;; Check if IME was NOT deactivated (input source remains RomajiTyping)
  (should (equal (mac-ime-internal-get-input-source) "com.apple.inputmethod.Kotoeri.RomajiTyping")))

(ert-deftest mac-ime-get-ime-on-input-source-priority-test ()
  "Test prioritized IME-on input source selection."
  (mac-ime-test-reset)
  (let ((mac-ime-mock-source-list
         '("com.apple.keylayout.US"
           "com.apple.inputmethod.Kotoeri.Roman"
           "com.apple.inputmethod.OtherIME"
           "com.apple.inputmethod.Kotoeri.Japanese"
           "com.apple.inputmethod.Kotoeri.RomajiTyping"))
        (mac-ime-ime-on-input-source-regexps '("romajityping" "japanese")))
    
    ;; 1. Both exist: preferred 1st (romajityping) should be selected
    (should (equal (mac-ime--get-ime-on-input-source)
                   "com.apple.inputmethod.Kotoeri.RomajiTyping"))
    
    ;; Reset cache
    (setq mac-ime-last-on-input-source nil)
    
    ;; 2. Only 2nd exists: 2nd (japanese) should be selected
    (let ((mac-ime-mock-source-list
           '("com.apple.keylayout.US"
             "com.apple.inputmethod.Kotoeri.Roman"
             "com.apple.inputmethod.OtherIME"
             "com.apple.inputmethod.Kotoeri.Japanese")))
      (should (equal (mac-ime--get-ime-on-input-source)
                     "com.apple.inputmethod.Kotoeri.Japanese")))
    
    ;; Reset cache
    (setq mac-ime-last-on-input-source nil)
    
    ;; 3. Neither exists: fallback to first non-no-ime source (OtherIME)
    (let ((mac-ime-mock-source-list
           '("com.apple.keylayout.US"
             "com.apple.inputmethod.Kotoeri.Roman"
             "com.apple.inputmethod.OtherIME")))
      (should (equal (mac-ime--get-ime-on-input-source)
                     "com.apple.inputmethod.OtherIME")))))

(ert-deftest mac-ime-dummy-event-test ()
  "Test that dummy events (keycode < 0) skip key hooks but trigger sync."
  (mac-ime-test-reset)
  (mac-ime-internal-start)
  (setq mac-ime--last-selected-buffer (current-buffer))
  
  (let ((hook-called nil))
    (add-hook 'mac-ime-functions (lambda (k m c ci cv) (setq hook-called t)))
    
    ;; Set up initial input source (US)
    (mac-ime-internal-set-input-source "com.apple.keylayout.US")
    (setq mac-ime--current-input-source "com.apple.keylayout.US")
    
    ;; Simulate a dummy event with keycode = -1 (input source change)
    ;; and simulate changing the mock input source to RomajiTyping
    (setq mac-ime-mock-current-source "com.apple.inputmethod.Kotoeri.RomajiTyping")
    (mac-ime-mock-simulate-event -1 0)
    
    ;; Poll
    (mac-ime-poll)
    
    ;; Verify that the key hook was NOT called
    (should-not hook-called)
    
    ;; Verify that synchronization was triggered and the cached current input source is updated
    (should (equal mac-ime--current-input-source "com.apple.inputmethod.Kotoeri.RomajiTyping"))))

(provide 'mac-ime-mock-test)
