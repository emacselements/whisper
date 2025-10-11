;; -*- lexical-binding: t; -*-
;; Author: Raoul Comninos

(defvar whisper-model-path "~/whisper.cpp/models/ggml-medium.en.bin"
  "Path to the Whisper model to use for transcription. Larger models are more accurate.")

(defvar whisper-vocabulary-file (expand-file-name "~/.emacs.d/whisper-vocabulary.txt")
  "Path to file containing vocabulary hints for Whisper (proper nouns, specialized terms, etc.).
The file should contain comma-separated words/phrases that Whisper should recognize.
You can customize this path by setting it in your init.el:
  (setq whisper-vocabulary-file \"/path/to/your/vocabulary.txt\")")

(defun whisper--get-vocabulary-prompt ()
  "Read vocabulary file and return as a prompt string for Whisper.
Returns nil if file doesn't exist or is empty."
  (when (and whisper-vocabulary-file
             (file-exists-p whisper-vocabulary-file))
    (with-temp-buffer
      (insert-file-contents whisper-vocabulary-file)
      (let ((content (string-trim (buffer-string))))
        (unless (string-empty-p content)
          content)))))

(defun run-whisper-stt-fast ()
  "Record audio and transcribe it using Whisper (base.en model - fast), inserting text at cursor position."
  (interactive)
  (let* ((original-buf (current-buffer))
         (original-point (point-marker))  ; Marker tracks position even if buffer changes
         (wav-file "/tmp/whisper-recording.wav")
         (temp-buf (generate-new-buffer " *Whisper Temp*")))

    ;; Start recording audio
    (start-process "record-audio" nil "/bin/sh" "-c"
                   (format "sox -d -r 16000 -c 1 -b 16 %s --no-show-progress 2>/dev/null" wav-file))
    ;; Inform user recording has started
    (message "Recording started (fast mode). Press C-g to stop.")
    ;; Wait for user to stop (C-g)
    (condition-case nil
        (while t (sit-for 1))
      (quit (interrupt-process "record-audio")))

    ;; Run Whisper STT with base.en model
    (let* ((vocab-prompt (whisper--get-vocabulary-prompt))
           (whisper-cmd (if vocab-prompt
                            (format "~/whisper.cpp/build/bin/whisper-cli -m ~/whisper.cpp/models/ggml-base.en.bin -f %s -nt -np --prompt \"%s\" 2>/dev/null"
                                    wav-file
                                    (replace-regexp-in-string "\"" "\\\\\"" vocab-prompt))
                          (format "~/whisper.cpp/build/bin/whisper-cli -m ~/whisper.cpp/models/ggml-base.en.bin -f %s -nt -np 2>/dev/null"
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
                    (insert output " ")  ;; Insert text with a single space after
                    (goto-char (point))))) ;; Move cursor to end of inserted text
              ;; Clean up temporary buffer
              (kill-buffer ,temp-buf))))))))

(defun run-whisper-stt ()
  "Record audio and transcribe it using Whisper (configurable model - more accurate), inserting text at cursor position."
  (interactive)
  (let* ((original-buf (current-buffer))
         (original-point (point-marker))  ; Marker tracks position even if buffer changes
         (wav-file "/tmp/whisper-recording.wav")
         (temp-buf (generate-new-buffer " *Whisper Temp*")))

    ;; Start recording audio
    (start-process "record-audio" nil "/bin/sh" "-c"
                   (format "sox -d -r 16000 -c 1 -b 16 %s --no-show-progress 2>/dev/null" wav-file))
    ;; Inform user recording has started
    (message "Recording started (accurate mode). Press C-g to stop.")
    ;; Wait for user to stop (C-g)
    (condition-case nil
        (while t (sit-for 1))
      (quit (interrupt-process "record-audio")))

    ;; Run Whisper STT
    (let* ((vocab-prompt (whisper--get-vocabulary-prompt))
           (whisper-cmd (if vocab-prompt
                            (format "~/whisper.cpp/build/bin/whisper-cli -m %s -f %s -nt -np --prompt \"%s\" 2>/dev/null"
                                    whisper-model-path wav-file
                                    (replace-regexp-in-string "\"" "\\\\\"" vocab-prompt))
                          (format "~/whisper.cpp/build/bin/whisper-cli -m %s -f %s -nt -np 2>/dev/null"
                                  whisper-model-path wav-file)))
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

(global-set-key (kbd "C-c v") 'run-whisper-stt-fast)
(global-set-key (kbd "C-c n") 'run-whisper-stt)

(provide 'my-whisper)
