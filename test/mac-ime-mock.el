;;; mac-ime-mock.el --- Mock module for mac-ime testing -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2025 Masami

;;; Commentary:

;; This file provides a mock implementation of the mac-ime dynamic module
;; for testing purposes. It simulates the behavior of the C module in Elisp.

;;; Code:

(require 'mac-ime)

(defvar mac-ime-mock-running nil
  "Whether the mock monitor is running.")

(defvar mac-ime-mock-event-queue nil
  "Queue of simulated events. Each element is (KEYCODE . MODIFIERS).")

(defvar mac-ime-mock-current-source "com.apple.keylayout.US"
  "Current simulated input source ID.")

(defvar mac-ime-mock-source-list
  '("com.apple.keylayout.US"
    "com.apple.inputmethod.Kotoeri.RomajiTyping"
    "com.apple.inputmethod.Kotoeri.KanaTyping")
  "List of available input sources.")

(defvar mac-ime-mock-converting nil
  "Whether the mock IME is converting.")

(defun mac-ime-mock-reset ()
  "Reset the mock state."
  (setq mac-ime-mock-running nil
        mac-ime-mock-event-queue nil
        mac-ime-mock-current-source "com.apple.keylayout.US"
        mac-ime-mock-converting nil))

(defun mac-ime-mock-simulate-event (keycode modifiers &optional characters characters-ignoring)
  "Add a simulated event to the queue."
  (setq mac-ime-mock-event-queue
        (append mac-ime-mock-event-queue
                (list (list keycode modifiers characters characters-ignoring mac-ime-mock-converting)))))

;; Mock implementations of internal functions (only when not compiling)
(unless (bound-and-true-p byte-compile-current-file)
  (defun mac-ime-internal-start ()
    (setq mac-ime-mock-running t)
    t)

  (defun mac-ime-internal-stop ()
    (setq mac-ime-mock-running nil)
    t)

  (defun mac-ime-internal-poll (callback)
    (let ((count 0))
      (dolist (event mac-ime-mock-event-queue)
        (funcall callback
                 (nth 0 event)
                 (nth 1 event)
                 (nth 2 event)
                 (nth 3 event)
                 (nth 4 event))
        (setq count (1+ count)))
      (setq mac-ime-mock-event-queue nil)
      (if (> count 0) count nil)))

  (defun mac-ime-internal-get-input-source ()
    mac-ime-mock-current-source)

  (defun mac-ime-internal-set-input-source (source-id)
    (if (member source-id mac-ime-mock-source-list)
        (progn
          (setq mac-ime-mock-current-source source-id)
          t)
      nil))

  (defun mac-ime-internal-get-input-source-list ()
    mac-ime-mock-source-list)

  (defun mac-ime-internal-version ()
    "0.1.0"))

;; Override mac-ime--load-module to do nothing but ensure our mocks are ready
(defun mac-ime-mock-enable ()
  "Enable the mock implementation."
  (advice-add 'mac-ime--load-module :override #'ignore)
  ;; Ensure the feature is provided so mac-ime thinks the module is loaded
  (provide 'mac-ime-module))

(defun mac-ime-mock-disable ()
  "Disable the mock implementation."
  (advice-remove 'mac-ime--load-module #'ignore)
  (setq features (delq 'mac-ime-module features)))

(provide 'mac-ime-mock)
;;; mac-ime-mock.el ends here
