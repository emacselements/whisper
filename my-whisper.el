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

(defcustom my-whisper-sox "sox"
  "The SoX Sound eXchange program name, with or without path.

The default is sox, without a path; you can use this unchanged if it
is installed in a directory in your PATH.  If it is stored somewhere else, then
include its directory path."
  :group 'my-whisper
  :type 'string)

(defcustom my-whisper-model-fast "ggml-base.en.bin"
  "Whisper model for fast transcription mode.
This model is used by `my-whisper-transcribe-fast'."
  :group 'my-whisper
  :type 'string)

(defcustom my-whisper-model "ggml-medium.en.bin"
  "Whisper model for accurate transcription mode.
This model is used by `my-whisper-transcribe'.

The common options (all English) models:
- ggml-large-v3-turbo.bin: Best accuracy, slower
- ggml-medium.en.bin     : Good balance of speed and accuracy
- ggml-small.en.bin      : Faster than medium, less accurate
- ggml-base.en.bin       : Fastest, least accurate"
  :group 'my-whisper
  :type '(choice
          (const :tag "Large  model, best accuracy, slower  " "ggml-large-v3-turbo.bin")
          (const :tag "Medium model, balance speed/accuracy " "ggml-medium.en.bin")
          (const :tag "Small  model, faster, less accurate  " "ggml-small.en.bin")
          (const :tag "Base   model, fastest, least accurate" "ggml-base.en.bin")
          (string :tag "Other model")))

(defun my-whisper-model-desc (model)
  "Return a description string of specified MODEL, a string."
  (cond
   ((string= model "ggml-large-v3-turbo.bin") "Large model, best accuracy, slower")
   ((string= model "ggml-medium.en.bin")      "Medium model, balance speed/accuracy")
   ((string= model "ggml-small.en.bin")       "Small model, faster, less accurate" )
   ((string= model "ggml-base.en.bin")        "Base model, fastest, least accurate")
   (t model)))

(defun my-whisper--cli-path ()
  "Return the path to the whisper-cli executable."
  (format "%s/build/bin/whisper-cli"
          (directory-file-name my-whisper-homedir)))

(defun my-whisper--model-path (&optional model)
  "Return the path to the whisper model file.
If MODEL is nil, use `my-whisper-model'."
  (format "%s/models/%s"
          (directory-file-name my-whisper-homedir)
          (or model my-whisper-model)))

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

(defun my-whisper--validate-environment (&optional model)
  "Validate current settings.
If MODEL is nil, use `my-whisper-model'."
  (let ((cli-path (my-whisper--cli-path))
        (model-path (my-whisper--model-path model)))
    (unless (executable-find my-whisper-sox)
      (user-error "The sox command is not accessible; is my-whisper-sox valid?"))
    (unless (file-directory-p my-whisper-homedir)
      (user-error "Invalid my-whisper-homedir (%s)" my-whisper-homedir))
    (unless (file-executable-p cli-path)
      (if (file-exists-p cli-path)
          (user-error "My-whisper-cli (%s) is not an executable file!"
                      cli-path))
      (user-error "My-whisper-cli (%s) does not exist!" cli-path))
    (unless (file-exists-p model-path)
      (user-error "My-whisper-model-path (%s) does not exist!"
                  model-path))))

(defun my-whisper--start-message (model vocab-word-count)
  "Inform user recording is starting with MODEL, warn if vocabulary is too large.
The VOCAB-WORD-COUNT is the number of words detected in the vocabulary file."
  (if (and vocab-word-count (> vocab-word-count 150))
      (message "\
Recording starting with %s. Editing halted. Press C-g to stop.
WARNING: Vocabulary file has %d words (max: 150)!"
               (my-whisper-model-desc model)
               vocab-word-count)
    (message "\
Recording starting with %s. Editing halted. Press C-g to stop."
             (my-whisper-model-desc model))))

(defun my-whisper-record-audio-in (wav-file)
  "Record audio, store it in the specified WAV-FILE."
  ;; Start recording audio.
  ;; Use the sox command. Ref: https://sourceforge.net/projects/sox/
  ;;  -d : record audio
  ;;  -r sample-rate in Hz
  ;;  -c channel : number of channel audio in the file.  Use 1.
  ;;  -b bits: bit-length of each encoded sample.
  ;;  --no-show-progress : do not print a progress bar in stdout.
  (start-process "record-audio" nil my-whisper-sox
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
  (let ((model (if fast-mode-p my-whisper-model-fast
                 my-whisper-model)))
    (my-whisper--validate-environment model)
    (let* ((original-buf (current-buffer))
           (original-point (point-marker)) ; Marker tracks position even if buffer changes
           (wav-file (format "/tmp/whisper-recording-%s.wav" (emacs-pid)))
           (temp-buf (generate-new-buffer " *Whisper Temp*"))
           (vocab-prompt (my-whisper--get-vocabulary-prompt))
           (vocab-word-count (my-whisper--check-vocabulary-length)))

      ;; Inform user recording is starting. Warn if vocabulary is too large.
      (my-whisper--start-message model vocab-word-count)

      ;; Record audio in the specified wav-file
      (my-whisper-record-audio-in wav-file)

      ;; Run Whisper STT (Speech To Text) with selected model
      (let* ((whisper-cmd
              (format "%s -m %s -f %s -nt -np %s 2>/dev/null"
                      (my-whisper--cli-path)
                      (my-whisper--model-path model)
                      wav-file
                      (if vocab-prompt
                          (format "--prompt \"%s\""
                                  (replace-regexp-in-string "\"" "\\\\\""
                                                            vocab-prompt))
                        "")))
             (proc
              (start-process "whisper-stt" temp-buf "/bin/sh" "-c" whisper-cmd)))
        ;; Properly capture `temp-buf` using a lambda
        (set-process-sentinel
         proc
         (lambda (_proc event)
            (if (string= event "finished\n")
                (when (buffer-live-p temp-buf)
                  ;; Trim excess white space
                  (let ((output (string-trim
                                 (with-current-buffer temp-buf
                                   (buffer-string)))))
                    (if (string-empty-p output)
                        (message "Whisper: No transcription output.")
                      (when (buffer-live-p original-buf)
                        (with-current-buffer original-buf
                          (goto-char original-point)
                          ;; Insert text, then a single space
                          (insert output " ")))))
                  ;; Clean up temporary buffer
                  (kill-buffer temp-buf)
                  ;; And delete WAV file that has been processed.
                  (when (file-exists-p wav-file)
                    (delete-file wav-file)))
              ;; No detection of end: error!
              (message "Whisper process error: %s" event))))))))

(provide 'my-whisper)
;;; my-whisper.el ends here
