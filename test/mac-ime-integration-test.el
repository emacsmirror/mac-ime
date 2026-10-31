;;; mac-ime-integration-test.el --- Integration tests for mac-ime -*- lexical-binding: t; no-byte-compile: t; -*-

(setq load-prefer-newer t)

(require 'ert)
(require 'mac-ime)

(ert-deftest mac-ime-integration-load-test ()
  "Test loading the actual dynamic module."
  ;; Ensure the module file exists
  (let ((mac-ime-module-path (expand-file-name "mac-ime-module.so" default-directory)))
    (should (file-exists-p mac-ime-module-path))
    
    ;; Load the module
    (mac-ime--load-module)
    
    ;; Check if features and functions are present
    (should (featurep 'mac-ime-module))
    (should (fboundp 'mac-ime-internal-start))
    (should (fboundp 'mac-ime-internal-stop))
    (should (fboundp 'mac-ime-internal-poll))
    (should (fboundp 'mac-ime-internal-get-input-source))
    (should (fboundp 'mac-ime-internal-set-input-source))
    (should (fboundp 'mac-ime-internal-get-input-source-list))))

(ert-deftest mac-ime-integration-api-test ()
  "Test calling actual module functions."
  (mac-ime--load-module)
  
  ;; Test getting input source
  (let ((source (mac-ime-internal-get-input-source)))
    (if (null source)
        (message "Skipping input source tests (running in a headless environment)")
      (should (stringp source))
      (message "Actual Input Source: %s" source)
      
      ;; Test getting input source list
      (let ((sources (mac-ime-internal-get-input-source-list)))
        (should (listp sources))
        (should (cl-every #'stringp sources))
        (message "Available Sources: %s" sources))))
  
  ;; Test start/stop (basic check)
  (should (equal (mac-ime-internal-start) t))
  (should (equal (mac-ime-internal-stop) t)))

(defun mac-ime-integration-test--set-in-other-process (source)
  "Set the input source to SOURCE from another Emacs process."
  (call-process (expand-file-name invocation-name invocation-directory)
                nil nil nil "-Q" "-batch" "--eval"
                (format "(progn (module-load %S) (mac-ime-internal-set-input-source %S))"
                        (expand-file-name "mac-ime-module.so" default-directory)
                        source)))

(ert-deftest mac-ime-integration-external-change-test ()
  "Test that an input source change by another process is seen.
Without NSApp, as on a text terminal, the module must not return a
stale input source."
  (mac-ime--load-module)
  (let* ((orig (mac-ime-internal-get-input-source))
         (other (cl-find-if (lambda (s)
                              (and (not (equal s orig))
                                   (string-match-p "keylayout\\|inputmethod" s)))
                            (mac-ime-internal-get-input-source-list))))
    (if (not (and orig other))
        (message "Skipping external change test (no other input source)")
      (unwind-protect
          (progn
            (should (mac-ime-internal-set-input-source other))
            (should (equal (mac-ime-internal-get-input-source) other))
            (mac-ime-integration-test--set-in-other-process orig)
            (should (equal (mac-ime-internal-get-input-source) orig)))
        (mac-ime-internal-set-input-source orig)))))

(provide 'mac-ime-integration-test)
