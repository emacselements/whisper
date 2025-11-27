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
;;       M-x my-whisper-transcribe  ; Use mode selected by `my-whisper-model'
;;                                  ; which is the accurate mode by default.
;;   C-u M-x my-whisper-transcribe  ; Fast mode (base.en model)

;; Recommended keybindings (add to your init.el):
;;   (global-set-key (kbd "C-c n") #'my-whisper-transcribe)

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

(defconst my-whisper-model-fast "ggml-base.en.bin"
  "Base model, fast mode.")

(defcustom my-whisper-model "ggml-medium.en.bin"
  "Whisper Model.

Select one of the following:
- 1: Base model,   fast mode:     ggml-base.en.bin
- 2: Medium model, accurate mode: ggml-medium.en.bin - default.
- 3: Other: specify the file name."
  :group 'my-whisper
  :type '(choice
          (const :tag "Base model:   fast mode"     my-whisper-model-fast)
          (const :tag "Medium model: accurate mode" "ggml-medium.en.bin")
          (string :tag "Other")))

(defun my-whisper--cli-path ()
  "Return the path to the whisper-cli executable."
  (format "%s/build/bin/whisper-cli"
          (directory-file-name my-whisper-homedir)))

(defun my-whisper--model-path (&optional fast-mode-p)
  "Return the path to the whisper model file.
If FAST-MODE-P is non-nil return the medium model (fast mode), otherwise
return the model selected by the `my-whisper-model' user-option."
  (format "%s/models/%s"
          (directory-file-name my-whisper-homedir)
          (if fast-mode-p my-whisper-model-fast
            my-whisper-model)))


(defcustom my-whisper-vocabulary-file (expand-file-name
                                       (locate-user-emacs-file
                                        "whisper-vocabulary.txt"))
  "Path to file containing vocabulary hints for Whisper.
This should contain proper nouns, specialized terms, etc.
The file should contain comma-separated words/phrases that Whisper
should recognize.

You can either customize this path or set it in your init.el:
  (setq my-whisper-vocabulary-file \"/path/to/your/vocabulary.txt\")"
  :group 'my-whisper
  :type 'file)

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
  (let ((cli-path (my-whisper--cli-path))
        (model-path (my-whisper--model-path)))
    (unless (executable-find "sox")
      (user-error "The sox command is not accessible in your PATH."))
    (unless (file-directory-p my-whisper-homedir)
      (user-error "Invalid my-whisper-homedir (%s)" my-whisper-homedir))
    (unless (file-executable-p cli-path)
      (if (file-exists-p cli-path)
          (user-error "My-whisper-cli (%s) is not an executable file"
                      cli-path))
      (user-error "My-whisper-cli (%s) does not exist" cli-path))
    (unless (file-exists-p model-path)
      (user-error "My-whisper-model-path (%s) does not exist"
                  model-path))))

(defun my-whisper--start-message (fast-mode-p vocab-word-count)
  "Inform user recording is starting and warn if vocabulary is too large.
A FAST-MODE-P non-nil indicate fast mode, otherwise it indicate accurate mode.
The VOCAB-WORD-COUNT is the number of words detected in the vocabulary file."
  (if (and vocab-word-count (> vocab-word-count 150))
      (message "\
Recording is starting (%s mode). Editing halted. Press C-g to stop.
WARNING: Vocabulary file has %d words (max: 150)!"
               (if fast-mode-p "fast" "accurate")
               vocab-word-count)
    (message "\
Recording is starting (%s mode). Editing halted. Press C-g to stop."
             (if fast-mode-p "fast" "accurate"))))

(defun my-whisper-record-audio-in (wav-file)
  "Record audio, store it in the specified WAV-FILE."
  ;; Start recording audio.
  ;; Use the sox command. Ref: https://sourceforge.net/projects/sox/
  ;;  -d : record audio
  ;;  -r sample-rate in Hz
  ;;  -c channel : number of channel audio in the file.  Use 1.
  ;;  -b bits: bit-length of each encoded sample.
  ;;  --no-show-progress : do not print a progress bar in stdout.
  (start-process "record-audio" nil "sox"
                 "-d" "-r" " 16000" "-c" "1" "-b" "16"
                 wav-file
                 "--no-show-progress")
    ;; Wait for user to stop (C-g)
    (condition-case nil
        (while t (sit-for 1))
      (quit (interrupt-process "record-audio"))))

(defun my-whisper-transcribe (&optional fast-mode-p)
  "Record audio and transcribe text in current buffer.
By default, or when FAST-MODE-P is nil, use the model selected by
the `my-whisper-model' user-option.
When FAST-MODE-P is non-nil use the fast mode, the model specified by
`my-whisper-model-fast'.

Record audio until you press \\[keyboard-quit], then transcribes it and insert
the text at point."
  (interactive "P")
  (my-whisper--validate-environment)
  (let* ((original-buf (current-buffer))
         (original-point (point-marker)) ; Marker tracks position even if buffer changes
         (wav-file (format "/tmp/whisper-recording-%s.wav" (emacs-pid)))
         (temp-buf (generate-new-buffer " *Whisper Temp*"))
         (vocab-prompt (my-whisper--get-vocabulary-prompt))
         (vocab-word-count (my-whisper--check-vocabulary-length)))

    ;; Inform user recording is starting. Warn if vocabulary is too large.
    (my-whisper--start-message fast-mode-p vocab-word-count)

    ;; Record audio in the specified wav-file
    (my-whisper-record-audio-in wav-file)

    ;; Run Whisper STT with selected model
    (let* ((whisper-cmd
            (if vocab-prompt
                (format "%s -m %s -f %s -nt -np --prompt \"%s\" 2>/dev/null"
                        (my-whisper--cli-path)
                        (my-whisper--model-path fast-mode-p)
                        wav-file
                        (replace-regexp-in-string "\"" "\\\\\"" vocab-prompt))
              (format "%s -m %s -f %s -nt -np 2>/dev/null"
                      (my-whisper--cli-path)
                      (my-whisper--model-path fast-mode-p)
                      wav-file)))
           (proc
            (start-process "whisper-stt" temp-buf "/bin/sh" "-c" whisper-cmd)))
      ;; Properly capture `temp-buf` using a lambda
      (set-process-sentinel
       proc
       `(lambda (proc event)
          (if (string= event "finished\n")
              (when (buffer-live-p ,temp-buf)
                ;; Trim excess white space
                (let* ((output (string-trim
                                (with-current-buffer ,temp-buf
                                  (buffer-string)))))
                  (if (string-empty-p output)
                      (message "Whisper: No transcription output.")
                    (when (buffer-live-p ,original-buf)
                      (with-current-buffer ,original-buf
                        (goto-char ,original-point)
                        ;; Insert text, then a single space
                        (insert output " ")))))
                ;; Clean up temporary buffer
                (kill-buffer ,temp-buf)
                ;; And delete WAV file that has been processed.
                (when (file-exists-p ,wav-file)
                  (delete-file ,wav-file)))
            ;; No detection of end: error!
            (message "Whisper process error: %s" event)))))))

(provide 'my-whisper)
;;; my-whisper.el ends here
