;;; my-whisper.el --- Speech-to-text using Whisper.cpp -*- lexical-binding: t -*-

;; Copyright (C) 2025 Raoul Comninos

;; Author: Raoul Comninos
;; Version: 1.0.1
;; Package-Requires: ((emacs "26.1"))
;; Keywords: convenience, speech, whisper, transcription
;; URL: https://github.com/emacselements/my-whisper
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining
;; a copy of this software and associated documentation files (the
;; "Software"), to deal in the Software without restriction, including
;; without limitation the rights to use, copy, modify, merge, publish,
;; distribute, sublicense, and/or sell copies of the Software, and to
;; permit persons to whom the Software is furnished to do so, subject to
;; the following conditions:

;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
;; IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
;; CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
;; TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
;; SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

;;; Commentary:

;; My-Whisper provides simple speech-to-text transcription using
;; Whisper.cpp.  It records audio via sox and transcribes it using
;; Whisper models, inserting the transcribed text at your cursor.

;; Features:
;; - Two transcription modes: fast (base.en) and accurate (medium.en)
;; - Custom vocabulary support for specialized terminology
;; - Automatic vocabulary length validation
;; - Async processing with process sentinels
;; - Clean temporary file management

;; Basic usage:
;;   M-x my-whisper-transcribe-fast  ; Fast mode (base.en model)
;;   M-x my-whisper-transcribe       ; Accurate mode (medium.en)

;; Configuration:
;;   Add to your init.el:
;;     (global-set-key (kbd "C-c v") #'my-whisper-transcribe-fast)
;;     (global-set-key (kbd "C-c n") #'my-whisper-transcribe)

;; See the README for installation and configuration details.

;;; Code:

(defgroup my-whisper nil
  "Speech-to-text transcription using Whisper.cpp."
  :group 'convenience
  :prefix "my-whisper-")

(defcustom my-whisper-executable (expand-file-name "~/whisper.cpp/build/bin/whisper-cli")
  "Path to the whisper-cli executable.
This is the compiled Whisper.cpp command-line tool."
  :type '(file :must-match t)
  :group 'my-whisper)

;; Optional, opt-in reliability settings (safe to remove as a block)
;; --- Begin: Input device resilience options ---
(defcustom my-whisper-input-source nil
  "Optional PulseAudio source name to record from.
When nil, uses the system default input (sox \=`-d\=').
Example: \=`alsa_input.usb-YourMicName\='."
  :type '(choice (const :tag "Default input" nil)
                 (string :tag "PulseAudio source name"))
  :group 'my-whisper)

(defcustom my-whisper-reset-default-source nil
  "If non-nil, reset the default PulseAudio source before recording.
This can fix first-try recording issues across different microphones."
  :type 'boolean
  :group 'my-whisper)

(defcustom my-whisper-prewarm nil
  "If non-nil, perform a 1s warm-up capture before recording.
Helps avoid stale device state on first use."
  :type 'boolean
  :group 'my-whisper)

(defun my-whisper--maybe-reset-default-source ()
  "Optionally reset the default PulseAudio source (opt-in)."
  (when my-whisper-reset-default-source
    (message "Resetting input device (PulseAudio) ...")
    (ignore-errors
      (call-process "/bin/sh" nil nil nil "-c"
                    "pactl suspend-source @DEFAULT_SOURCE@ 1; sleep 0.2; pactl suspend-source @DEFAULT_SOURCE@ 0"))))

(defun my-whisper--maybe-prewarm ()
  "Optionally do a short warm-up capture (opt-in)."
  (when my-whisper-prewarm
    (message "Pre-warming microphone for 1s ...")
    (ignore-errors
      (call-process "/bin/sh" nil nil nil "-c"
                    "timeout 1 sox -d -r 16000 -c 1 -b 16 \"$(mktemp /tmp/whisper-warmup.XXXXXX.wav)\" --no-show-progress 2>/dev/null"))))
;; --- End: Input device resilience options ---

(defcustom my-whisper-model-path (expand-file-name "~/whisper.cpp/models/ggml-medium.en.bin")
  "Path to the Whisper model to use for transcription.
Larger models are more accurate but slower."
  :type '(file :must-match t)
  :group 'my-whisper)

(defcustom my-whisper-base-model-path (expand-file-name "~/whisper.cpp/models/ggml-base.en.bin")
  "Path to the Whisper base model for fast transcription.
Used by `my-whisper-transcribe-fast'."
  :type '(file :must-match t)
  :group 'my-whisper)

(defcustom my-whisper-vocabulary-file (locate-user-emacs-file "whisper-vocabulary.txt")
  "Path to file containing vocabulary hints for Whisper.
This should contain proper nouns, specialized terms, etc.
The file should contain comma-separated words/phrases that Whisper
should recognize.
Set to nil to disable vocabulary hints."
  :type '(choice (const :tag "No vocabulary file" nil)
                 (file :tag "Vocabulary file path"))
  :group 'my-whisper)

(defun my-whisper--get-vocabulary-prompt ()
  "Read vocabulary file and return as a prompt string for Whisper.
Returns nil if file doesn't exist or is empty."
  (when (and my-whisper-vocabulary-file
             (file-exists-p my-whisper-vocabulary-file))
    (with-temp-buffer
      (insert-file-contents my-whisper-vocabulary-file)
      (let ((content (string-trim (buffer-string))))
        (unless (string-empty-p content)
          content)))))

(defun my-whisper--check-vocabulary-length ()
  "Check vocabulary file length and return word count.
Returns nil if file doesn't exist or is empty."
  (when (and my-whisper-vocabulary-file
             (file-exists-p my-whisper-vocabulary-file))
    (with-temp-buffer
      (insert-file-contents my-whisper-vocabulary-file)
      (let* ((content (string-trim (buffer-string)))
             (word-count (length (split-string content))))
        (unless (string-empty-p content)
          word-count)))))

(defun my-whisper-transcribe-fast ()
  "Record audio and transcribe using Whisper base.en model (fast).
Records audio until you press \\[keyboard-quit], then transcribes it
and inserts the text at point."
  (interactive)
  (let* ((original-buf (current-buffer))
         (original-point (point-marker))  ; Marker tracks position even if buffer changes
         (wav-file (expand-file-name "whisper-recording.wav" (temporary-file-directory)))
         (temp-buf (generate-new-buffer " *Whisper Temp*"))
         (vocab-prompt (my-whisper--get-vocabulary-prompt))
         (vocab-word-count (my-whisper--check-vocabulary-length)))

    ;; Clean up any existing processes and files
    (when (get-process "whisper-stt-fast")
      (delete-process "whisper-stt-fast"))
    (when (get-process "record-audio")
      (delete-process "record-audio"))
    (when (file-exists-p wav-file)
      (delete-file wav-file))

    ;; Optional resilience steps
    (my-whisper--maybe-reset-default-source)
    (my-whisper--maybe-prewarm)
    ;; Start recording audio (use PulseAudio source if provided)
    (start-process
     "record-audio" nil "/bin/sh" "-c"
     (if (and my-whisper-input-source (not (string-empty-p my-whisper-input-source)))
       (format "sox -t pulseaudio %s -r 16000 -c 1 -b 16 %s --no-show-progress 2>/dev/null"
           (shell-quote-argument my-whisper-input-source)
           (shell-quote-argument wav-file))
       (format "sox -d -r 16000 -c 1 -b 16 %s --no-show-progress 2>/dev/null"
           (shell-quote-argument wav-file))))
    ;; Inform user recording has started with vocabulary warning if needed
    (if (and vocab-word-count (> vocab-word-count 150))
        (message "Recording started (fast mode). Press C-g to stop. WARNING: Vocabulary file has %d words (max: 150)!" vocab-word-count)
      (message "Recording started (fast mode). Press C-g to stop."))
    ;; Wait for user to stop (C-g)
    (condition-case nil
        (while t (sit-for 1))
      (quit (interrupt-process "record-audio")))

    ;; Give sox a moment to finish writing the file
    (sleep-for 0.1)

    (run-at-time 0.1 nil
                 (lambda ()
                   (message "Processing transcription, please wait...")))

    ;; Run Whisper STT with base.en model
    (let* (
           (whisper-cmd (if vocab-prompt
                            (format "%s -m %s -f %s -nt -np --prompt \"%s\" 2>/dev/null"
                                    (expand-file-name my-whisper-executable)
                                    (expand-file-name my-whisper-base-model-path)
                                    wav-file
                                    (replace-regexp-in-string "\"" "\\\\\"" vocab-prompt))
                          (format "%s -m %s -f %s -nt -np 2>/dev/null"
                                  (expand-file-name my-whisper-executable)
                                  (expand-file-name my-whisper-base-model-path)
                                  wav-file)))
           (proc (start-process "whisper-stt-fast" temp-buf "/bin/sh" "-c" whisper-cmd)))
      ;; Properly capture `temp-buf` using a lambda
      (set-process-sentinel
       proc
       `(lambda (proc event)
          (when (memq (process-status proc) '(exit signal))
            (when (buffer-live-p ,temp-buf)
              (let* ((output (string-trim (with-current-buffer ,temp-buf (buffer-string))))) ;; Trim excess whitespace
                (if (string-empty-p output)
                    (message "Whisper: No transcription output.")
                  (when (buffer-live-p ,original-buf)
                    (with-current-buffer ,original-buf
                      (goto-char ,original-point)
                      (insert output " ")  ;; Insert text with a single space after
                      (goto-char (point))))
                  (message "Transcription complete!")))
              ;; Clean up temporary buffer
              (kill-buffer ,temp-buf)
              (when (file-exists-p ,wav-file)
                (delete-file ,wav-file)))))))))

(defun my-whisper-transcribe ()
  "Record audio and transcribe using configurable Whisper model (accurate).
Uses the model specified in `my-whisper-model-path'.  Records audio
until you press \\[keyboard-quit], then transcribes it and inserts the
text at point."
  (interactive)
  (let* ((original-buf (current-buffer))
         (original-point (point-marker))  ; Marker tracks position even if buffer changes
         (wav-file (expand-file-name "whisper-recording.wav" (temporary-file-directory)))
         (temp-buf (generate-new-buffer " *Whisper Temp*"))
         (vocab-prompt (my-whisper--get-vocabulary-prompt))
         (vocab-word-count (my-whisper--check-vocabulary-length)))

    ;; Clean up any existing processes and files
    (when (get-process "whisper-stt-accurate")
      (delete-process "whisper-stt-accurate"))
    (when (get-process "record-audio")
      (delete-process "record-audio"))
    (when (file-exists-p wav-file)
      (delete-file wav-file))

    ;; Optional resilience steps
    (my-whisper--maybe-reset-default-source)
    (my-whisper--maybe-prewarm)
    ;; Start recording audio (use PulseAudio source if provided)
    (start-process
     "record-audio" nil "/bin/sh" "-c"
     (if (and my-whisper-input-source (not (string-empty-p my-whisper-input-source)))
       (format "sox -t pulseaudio %s -r 16000 -c 1 -b 16 %s --no-show-progress 2>/dev/null"
           (shell-quote-argument my-whisper-input-source)
           (shell-quote-argument wav-file))
       (format "sox -d -r 16000 -c 1 -b 16 %s --no-show-progress 2>/dev/null"
           (shell-quote-argument wav-file))))
    ;; Inform user recording has started with vocabulary warning if needed
    (if (and vocab-word-count (> vocab-word-count 150))
        (message "Recording started (accurate mode). Press C-g to stop. WARNING: Vocabulary file has %d words (max: 150)!" vocab-word-count)
      (message "Recording started (accurate mode). Press C-g to stop."))
    ;; Wait for user to stop (C-g)
    (condition-case nil
        (while t (sit-for 1))
      (quit (interrupt-process "record-audio")))

    ;; Give sox a moment to finish writing the file
    (sleep-for 0.1)

    (run-at-time 0.1 nil
                 (lambda ()
                   (message "Processing transcription, please wait...")))

    ;; Run Whisper STT
    (let* (
           (whisper-cmd (if vocab-prompt
                            (format "%s -m %s -f %s -nt -np --prompt \"%s\" 2>/dev/null"
                                    (expand-file-name my-whisper-executable)
                                    (expand-file-name my-whisper-model-path)
                                    wav-file
                                    (replace-regexp-in-string "\"" "\\\\\"" vocab-prompt))
                          (format "%s -m %s -f %s -nt -np 2>/dev/null"
                                  (expand-file-name my-whisper-executable)
                                  (expand-file-name my-whisper-model-path)
                                  wav-file)))
           (proc (start-process "whisper-stt-accurate" temp-buf "/bin/sh" "-c" whisper-cmd)))
      ;; Properly capture `temp-buf` using a lambda
      (set-process-sentinel
       proc
       `(lambda (proc event)
          (if (memq (process-status proc) '(exit signal))
              (when (buffer-live-p ,temp-buf)
                (let* ((output (string-trim (with-current-buffer ,temp-buf (buffer-string)))))
                  (if (string-empty-p output)
                      (message "Whisper: No transcription output.")
                    (when (buffer-live-p ,original-buf)
                      (with-current-buffer ,original-buf
                        (goto-char ,original-point)
                        (insert output " ")
                        (goto-char (point))))
                    (message "Transcription complete!")))
                (kill-buffer ,temp-buf)
                (when (file-exists-p ,wav-file)
                  (delete-file ,wav-file)))
            (message "Whisper process error: %s" event)))))))

(provide 'my-whisper)
;;; my-whisper.el ends here
