;;; my-whisper.el --- Speech-to-text using Whisper.cpp -*- lexical-binding: t -*-

;; Copyright (C) 2025 Raoul Comninos

;; Author: Raoul Comninos
;; Version: 1.0.0
;; Package-Requires: ((emacs "25.1"))
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

;; Default keybindings:
;;   C-c v - Fast transcription
;;   C-c n - Accurate transcription

;; See the README for installation and configuration details.

;;; Code:

(defgroup my-whisper nil
  "Speech-to-text using Whisper.cpp system."
  :group 'convenience
  :link '(url-link :tag "my-whisper @ Github"
                   "https://github.com/emacselements/my-whisper"))


(defcustom my-whisper-homedir "~/whisper.cpp/"
  "The whisper.cpp top directory."
  :group 'my-whisper
  :type 'directory)

(defcustom my-whisper-model "ggml-base.en.bin"
  "Whisper Model.

Select one of the following:
- 1: Base model,   fast mode:     ggml-base.en.bin
- 2: Medium model, accurate mode: ggml-medium.en.bin
- 3: Other: specify the file name."
  :group 'my-whisper
  :type '(choice
          (const :tag "Base model: fast mode" "ggml-base.en.bin")
          (const :tag "Medium model: accurate mode" "ggml-medium.en.bin")
          (string :tag "Other")))

(defconst my-whisper-cli  (format "%s/build/bin/whisper-cli"
                                   (directory-file-name my-whisper-homedir))
  "Path name of the whisper-cli.")

(defconst my-whisper-model-path (format "%s/models/%s"
                                    (directory-file-name my-whisper-homedir)
                                    my-whisper-model)
  "Path name of the whisper model.")


(defcustom my-whisper-vocabulary-file (expand-file-name (locate-user-emacs-file "whisper-vocabulary.txt"))
  "Path to file containing vocabulary hints for Whisper.
This should contain proper nouns, specialized terms, etc.
The file should contain comma-separated words/phrases that Whisper
should recognize.

You can either customize this path or set it in your init.el:
  (setq my-whisper-vocabulary-file \"/path/to/your/vocabulary.txt\")"
  :group 'my-whisper
  :type 'directory)

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

(defun my-whisper--validate-environment ()
  "Validate current settings.  Issue a user error if something is wrong."
  (unless (file-directory-p my-whisper-homedir)
    (user-error "Invalid my-whisper-homedir (%s)" my-whisper-homedir))
  (unless (file-executable-p my-whisper-cli)
    (if (file-exists-p my-whisper-cli)
        (user-error "my-whisper-cli (%s) is not an executable file"
                    my-whisper-cli))
    (user-error "my-whisper-cli (%s) does not exist" my-whisper-cli))
  (unless (file-exists-p my-whisper-model-path)
    (user-error "my-whisper-model-path (%s) does not exist"
                my-whisper-model-path)))

(defun my-whisper-transcribe-fast ()
  "Record audio and transcribe using Whisper base.en model (fast).
Records audio until you press \\[keyboard-quit], then transcribes it
and inserts the text at point."
  (interactive)
  (my-whisper--validate-environment)
  (let* ((original-buf (current-buffer))
         (original-point (point-marker)) ; Marker tracks position even if buffer changes
         (wav-file (format "/tmp/whisper-recording-%s.wav" (emacs-pid)))
         (temp-buf (generate-new-buffer " *Whisper Temp*"))
         (vocab-prompt (my-whisper--get-vocabulary-prompt))
         (vocab-word-count (my-whisper--check-vocabulary-length)))

    ;; Start recording audio
    (start-process "record-audio" nil "/bin/sh" "-c"
                   (format "sox -d -r 16000 -c 1 -b 16 %s --no-show-progress 2>/dev/null" wav-file))
    ;; Inform user recording has started with vocabulary warning if needed
    (if (and vocab-word-count (> vocab-word-count 150))
        (message "Recording started (fast mode). Press C-g to stop. WARNING: Vocabulary file has %d words (max: 150)!" vocab-word-count)
      (message "Recording started (fast mode). Press C-g to stop."))
    ;; Wait for user to stop (C-g)
    (condition-case nil
        (while t (sit-for 1))
      (quit (interrupt-process "record-audio")))

    ;; Run Whisper STT with base.en model
    (let* ((whisper-cmd (if vocab-prompt
                            (format "%s -m %s -f %s -nt -np --prompt \"%s\" 2>/dev/null"
                                    my-whisper-cli
                                    my-whisper-model-path
                                    wav-file
                                    (replace-regexp-in-string "\"" "\\\\\"" vocab-prompt))
                          (format "%s -m %s -f %s -nt -np 2>/dev/null"
                                  my-whisper-cli
                                  my-whisper-model-path
                                  wav-file)))
           (proc (start-process "whisper-stt" temp-buf "/bin/sh" "-c" whisper-cmd)))
      ;; Properly capture `temp-buf` using a lambda
      (set-process-sentinel
       proc
       `(lambda (proc event)
          (when (string= event "finished\n")
            (when (buffer-live-p ,temp-buf)
              (let* ((output (string-trim (with-current-buffer ,temp-buf (buffer-string))))) ;; Trim excess whitespace
                (when (buffer-live-p ,original-buf)
                  (with-current-buffer ,original-buf
                    (goto-char ,original-point)
                    (insert output " ") ;; Insert text with a single space after
                    (goto-char (point))))) ;; Move cursor to end of inserted text
              ;; Clean up temporary buffer
              (kill-buffer ,temp-buf))))))))

(defun my-whisper-transcribe ()
  "Record audio and transcribe using configurable Whisper model (accurate).
Uses the model specified in `my-whisper-model-path'.  Records audio
until you press \\[keyboard-quit], then transcribes it and inserts the
text at point."
  (interactive)
  (my-whisper--validate-environment)
  (let* ((original-buf (current-buffer))
         (original-point (point-marker)) ; Marker tracks position even if buffer changes
         (wav-file (format "/tmp/whisper-recording-%s.wav" (emacs-pid)))
         (temp-buf (generate-new-buffer " *Whisper Temp*"))
         (vocab-prompt (my-whisper--get-vocabulary-prompt))
         (vocab-word-count (my-whisper--check-vocabulary-length)))

    ;; Start recording audio
    (start-process "record-audio" nil "/bin/sh" "-c"
                   (format "sox -d -r 16000 -c 1 -b 16 %s --no-show-progress 2>/dev/null" wav-file))
    ;; Inform user recording has started with vocabulary warning if needed
    (if (and vocab-word-count (> vocab-word-count 150))
        (message "Recording started (accurate mode). Press C-g to stop. WARNING: Vocabulary file has %d words (max: 150)!" vocab-word-count)
      (message "Recording started (accurate mode). Press C-g to stop."))
    ;; Wait for user to stop (C-g)
    (condition-case nil
        (while t (sit-for 1))
      (quit (interrupt-process "record-audio")))

    ;; Run Whisper STT
    (let* ((whisper-cmd (if vocab-prompt
                            (format "%s -m %s -f %s -nt -np --prompt \"%s\" 2>/dev/null"
                                    my-whisper-cli
                                    my-whisper-model-path
                                    wav-file
                                    (replace-regexp-in-string "\"" "\\\\\"" vocab-prompt))
                          (format "%s -m %s -f %s -nt -np 2>/dev/null"
                                  my-whisper-cli
                                  my-whisper-model-path
                                  wav-file)))
           (proc (start-process "whisper-stt" temp-buf "/bin/sh" "-c" whisper-cmd)))
      ;; Properly capture `temp-buf` using a lambda
      (set-process-sentinel
       proc
       `(lambda (proc event)
          (if (string= event "finished\n")
              (when (buffer-live-p ,temp-buf)
                (let* ((output (string-trim (with-current-buffer ,temp-buf (buffer-string)))))
                  (if (string-empty-p output)
                      (message "Whisper: No transcription output.")
                    (when (buffer-live-p ,original-buf)
                      (with-current-buffer ,original-buf
                        (goto-char ,original-point)
                        (insert output " ")
                        (goto-char (point))))))
                (kill-buffer ,temp-buf)
                (when (file-exists-p ,wav-file)
                  (delete-file ,wav-file)))
            (message "Whisper process error: %s" event)))))))

(global-set-key (kbd "C-c v") #'my-whisper-transcribe-fast)
(global-set-key (kbd "C-c n") #'my-whisper-transcribe)

(provide 'my-whisper)
;;; my-whisper.el ends here
