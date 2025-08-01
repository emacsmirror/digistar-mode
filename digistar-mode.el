;;; digistar-mode.el --- Major mode for Digistar scripts -*- lexical-binding: t; -*-

;; Copyright (C) 2014-2025  John Foerch <jjfoerch@gmail.com>

;; Author: John Foerch <jjfoerch@gmail.com>
;; Version: 0.9.18
;; Date: 2025-07-10
;; URL: https://github.com/retroj/digistar-mode/
;; Keywords: languages
;; Package-Requires: ((emacs "25.1"))

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides digistar-mode, a major mode for editing Digistar
;; scripts.  If installed via elpa, the auto-mode-list entry for this mode
;; will be setup automatically.  If installed manually, use a snippet like
;; the following to set it up:
;;
;;     (when (locate-library "digistar-mode")
;;       (add-to-list 'auto-mode-alist '("\\.ds\\'" . digistar-mode)))
;;

;;; Code:

(require 'filenotify)


;;
;; Variables
;;

(defcustom digistar-gui-pathname
  (seq-find #'file-exists-p
            (list "C:/CXSoftware/Apps/Digistar/Bin/UI/Digistar.exe"
                  "C:/D7Software/Apps/Digistar/Bin/UI/Digistar.exe"
                  "C:/D7Software/Bin/GUI/Digistar.exe"
                  "C:/D6Software/Bin/GUI/Digistar.exe"
                  "C:/D5Software/Bin/GUI/Digistar.exe"))
  "Pathname of Digistar GUI executable."
  :type '(file :must-match t :tag "Digistar GUI exe path")
  :group 'digistar)

(defcustom digistar-path-aliases
  (let ((digistar-software-path (seq-find #'file-exists-p
                                          (list "c:/CXSoftware"
                                                "c:/D7Software"
                                                "c:/D6Software"
                                                "c:/D5Software")
                                          "c:/D7Software")))
    `(("$Content" . ,(seq-find #'file-exists-p
                               (list "c:/CXContent"
                                     "c:/D7Content"
                                     "c:/D6Content"
                                     "c:/D5Content")
                               "c:/D7Content"))
      ("$Digistar" . ,digistar-software-path)
      ("$Software" . ,digistar-software-path)))
  "Aliases for resolution of Digistar paths."
  :type '(alist :key-type string :value-type string)
  :group 'digistar)

(defvar digistar-identifier-re
  (rx-to-string '(: alpha (* graph))))

(defvar digistar-command-re
  (rx-to-string
     `(: (* blank) (group (regexp ,digistar-identifier-re))
         (* blank) (group (regexp ,digistar-identifier-re)))))


;;
;; Utils
;;

(defun digistar-mode-asset (relpath)
  "Resolve RELPATH against the location of digistar-mode.el.
Used for tool-bar button icons."
  (let ((digistar-mode-path (file-name-directory
                             (or load-file-name
                                 (locate-library "digistar-mode")))))
    (concat digistar-mode-path "/" relpath)))

(defun digistar-format-decimal-number (n)
  "Format number N for use in a Digistar timestamp."
  (let ((str (replace-regexp-in-string "\\.?0*$" "" (format "%.11f" n))))
    (cond
     ((string-match "^\\([0-9]\\)\\.\\([0-9]*?\\)\\(\\(?:0000+\\|9999+\\)[0-9]*\\)$" str)
      (let* ((n1 (match-string 1 str))
             (n2 (match-string 2 str))
             (n3 (match-string 3 str))
             (s (number-to-string (round (string-to-number (concat n1 n2 "." n3))))))
        (if (string= "" n2)
            s
          (concat n1 "." s))))
     ((string-match "^\\(.*?\\)0*$" str)
      (match-string 1 str)))))

(defun digistar-seconds-to-timestamp (s)
  "Format seconds S as a Digistar timestamp."
  (let* ((sd (digistar-format-decimal-number (- s (truncate s))))
         (sd (substring (if (string= sd "") "0" sd) 1))
         (h (floor s 3600))
         (s (- s (* h 3600)))
         (m (floor s 60))
         (s (truncate (- s (* m 60)))))
    (cond
     ((> h 0)
      (format "%d:%02d:%02d%s" h m s sd))
     ((> m 0)
      (format "%d:%02d%s" m s sd))
     (t
      (format "%d%s" s sd)))))

(defun digistar-timestamp-to-seconds (ts)
  "Convert timestamp TS to seconds."
  (if (string-match (concat "\\`\\(?:\\([[:digit:]]+\\):\\)??"
                            "\\(?:\\([[:digit:]]+\\):\\)?"
                            "\\([[:digit:]]+\\(?:\\.[[:digit:]]+\\)?\\)\\'")
                    ts)
      (let ((h (string-to-number (or (match-string 1 ts) "0")))
            (m (string-to-number (or (match-string 2 ts) "0")))
            (s (string-to-number (match-string 3 ts))))
        (+ (* 3600 h) (* 60 m) s))
    (error "Not a valid timestamp")))

(defun digistar-absolute-time-at-point-1 ()
  "This procedure is for internal use by `digistar-absolute-time-at-point'.
It assumes that the caller has just used a regexp operation to
find a timestamp.  If it is a relative timestamp, this procedure
returns its value in seconds.  If it is an absolute timestamp, it
throws `return' with the value in seconds."
  (let ((relativep (match-string 1))
        (s (digistar-timestamp-to-seconds (match-string 2))))
    (if relativep
        s
      (throw 'return s))))

(defvar digistar-timestamp-regexp "^[[:blank:]]*\\(\\+\\)?\\([0-9:.]+\\)")

(defun digistar-absolute-time-at-point (&optional pt)
  "Displays the absolute time of the line at point or optional PT."
  (save-excursion
    (save-restriction
      (when pt
        (goto-char pt))
      (beginning-of-line)
      (let ((time 0))
        (let ((abstime
               (catch 'return
                 (when (looking-at digistar-timestamp-regexp)
                   (setq time (digistar-absolute-time-at-point-1)))
                 (while (re-search-backward digistar-timestamp-regexp nil t)
                   (setq time (+ time (digistar-absolute-time-at-point-1))))
                 0.0)))
          (+ abstime time))))))

(defun digistar-resolve-path (path)
  "Resolve a Digistar PATH to an OS path, according to `digistar-path-aliases'."
  (let* ((lcpath (downcase (subst-char-in-string ?\\ ?/ path)))
         (found
          (seq-find (lambda (x)
                      (string-prefix-p (concat (downcase (car x)) "/") lcpath))
                    digistar-path-aliases)))
    (if found
        (concat (cdr found) "/" (substring path (1+ (length (car found)))))
      path)))

(defun digistar-unresolve-path (path)
  "Unresolve an OS PATH to a Digistar path, according to `digistar-path-aliases'."
  (let* ((lcpath (downcase path))
         (found
          (seq-find (lambda (x)
                      (string-prefix-p (concat (downcase (cdr x)) "/") lcpath))
                    digistar-path-aliases)))
    (if found
        (concat (car found) "/" (substring path (1+ (length (cdr found)))))
      path)))

(defun digistar-path-at-point ()
  "Return Digistar path at point."
  (save-excursion
    (re-search-backward "\\$\\|\\s-\\.\\|\\b[a-zA-Z]:" (point-at-bol) t)
    (when (looking-at "\\s-?\\(\\(?:\\$\\|\\.\\.?[/\\\\]\\|[a-zA-Z]:\\)[^|#\"\n]*\\)\\(\\s-*[|#\"].*\\)?$")
      (match-string 1))))


;;
;; Commands
;;

(defun digistar-show-absolute-time (&optional insert)
  "Show absolute time (in-script) of the current line.
If mark is active, the duration between point and mark will be
reported instead.  With prefix argument INSERT, inserts the
result."
  (interactive "P")
  (let* ((s1 (digistar-absolute-time-at-point))
         (s2 (if mark-active
                 (digistar-absolute-time-at-point (mark))
               0))
         (s (abs (- s2 s1))))
    (cond
     ((consp insert)
      (save-excursion
        (save-restriction
          (beginning-of-line)
          (when (looking-at digistar-timestamp-regexp)
            (delete-region (point) (match-end 0)))
          (insert (digistar-seconds-to-timestamp s)))))
     ((>= s 60)
      (message "%s (%s)" s (digistar-seconds-to-timestamp s)))
     (t (message "%s" s)))))

(defun digistar-show-lis-file ()
  "Show the .lis file for the current Digistar script file, if it exists."
  (interactive)
  (let* ((f (or (buffer-file-name) (error "Not visiting a file")))
         (sans-ds-ext (if (string-equal "ds" (file-name-extension f))
                          (file-name-sans-extension f)
                        f))
         (lisfile (concat sans-ds-ext ".lis")))
    (unless (file-exists-p lisfile)
      (error "LIS file does not exist (%s)" lisfile))
    (let ((buf (find-file-noselect lisfile)))
      (with-current-buffer buf
        (unless (eq major-mode 'digistar-mode)
          (digistar-mode)))
      (pop-to-buffer buf))))

(defun digistar-filenotify-callback (event &optional delete)
  "Callback to display the .lis file.

EVENT is provided by filenotify.
DELETE is a flag to delete the .lis file after displaying it."
  (let* ((descriptor (nth 0 event))
         (action (nth 1 event))
         (lisfile (nth 2 event))
         (dsfile (concat (file-name-sans-extension lisfile) ".ds")))
    ;;XXX assumption that only one changed event will occur
    (when (eq 'changed action)
      (file-notify-rm-watch descriptor)
      (display-buffer
       (with-current-buffer (get-buffer-create " *Digistar Lis*")
         (insert-file-contents lisfile nil nil nil t)
         (digistar-mode)
         (current-buffer)))
      (when delete
        (delete-file dsfile)
        (delete-file lisfile)))))

(defun digistar-filenotify-callback-with-delete (event)
  "Helper when showing the .lis file.

EVENT is for filenotify."
  (digistar-filenotify-callback event t))

(defun digistar-play-script ()
  "Play this script in Digistar.

If region is active, write its contents to a temporary file, and
play that script in Digistar.

If the buffer is narrowed, play only that portion.

The contents of the generated LIS file will be shown in the
*Digistar Lis* buffer in a non-selected window, and if a temporary file
was created, both the temporary file and its associated LIS file
will be automatically deleted.

When playing a region, relative paths will be resolved."
  (interactive)
  (unless digistar-gui-pathname
    (error "Digistar executable not found.  See `digistar-gui-pathname'"))
  (let* ((using-temp-file (or (region-active-p) (buffer-narrowed-p)))
         (dsfile
          (if using-temp-file
              (let* ((prefix (concat (file-name-base (buffer-file-name)) "-"))
                     (file-directory (file-name-directory (buffer-file-name)))
                     (default-directory file-directory)
                     (region-text (if (region-active-p)
                                      (buffer-substring (region-beginning) (region-end))
                                    (buffer-string))))
                ;; resolve relative paths
                (with-temp-buffer
                  (insert region-text)
                  (goto-char (point-min))
                  (while (re-search-forward
                          (concat "^[[:blank:]]*\\+?[0-9:.]*[[:blank:]]*"
                                  digistar-identifier-re "[[:blank:]]+"
                                  digistar-identifier-re "[[:blank:]]+"
                                  "\\(\\.[^#;]*\\)")
                          nil t)
                    (replace-match (digistar-unresolve-path
                                    (file-truename (match-string 1)))
                                   t t nil 1)
                    (end-of-line))
                  (make-temp-file prefix nil ".ds" (buffer-string))))
            buffer-file-name))
         (lisfile (concat (file-name-sans-extension dsfile) ".lis")))
    (file-notify-add-watch lisfile '(change)
                           (if using-temp-file
                               #'digistar-filenotify-callback-with-delete
                             #'digistar-filenotify-callback))
    (call-process digistar-gui-pathname nil nil nil
                  "-p" (replace-regexp-in-string "/" "\\\\" dsfile))))

(defun digistar-insert-filepath (filepath)
  "Prompt for and insert a FILEPATH as a Digistar path."
  (interactive "fFile: \n")
  (insert (digistar-unresolve-path filepath)))

(defun digistar-find-file-at-point ()
  "Find-file-at-point with support for Digistar paths."
  (interactive)
  (if-let ((path (digistar-path-at-point)))
      (let ((resolved-path (digistar-resolve-path path)))
        (find-file resolved-path))
    (message "No Digistar path was found at point")))


;;
;; Digistar-Time-Record mode
;;

(defvar digistar-time-record-last-time nil)
(make-variable-buffer-local 'digistar-time-record-last-time)

(defun digistar-time-record-init-or-insert (&optional relative)
  "Record a timestamp.

It will be a relative timestamp if RELATIVE is t."
  (interactive)
  (cond
   ((null digistar-time-record-last-time)
    (let ((realtime (float-time))
          (scripttime (digistar-absolute-time-at-point)))
      (setq digistar-time-record-last-time (cons realtime scripttime))
      (message "Recording times relative to %s. C-c C-c to end."
               (digistar-seconds-to-timestamp scripttime))))
   (t
    (let* ((prev-realtime (car digistar-time-record-last-time))
           (prev-scripttime (cdr digistar-time-record-last-time))
           (realtime (float-time))
           (delta (- realtime prev-realtime))
           (scripttime (+ prev-scripttime delta)))
      (setq digistar-time-record-last-time (cons realtime scripttime))
      (end-of-line)
      (open-line 1)
      (forward-line)
      (if relative
          (insert "+" (digistar-seconds-to-timestamp delta))
          (insert (digistar-seconds-to-timestamp scripttime)))))))

(defun digistar-time-record-init-or-insert-relative ()
  "Record a timestamp with relative mode on."
  (interactive)
  (digistar-time-record-init-or-insert t))

(defun digistar-time-record-mode-done ()
  "End `digistar-time-record-mode'."
  (interactive)
  (digistar-time-record-mode -1)
  (message "Digistar-Time-Record mode disabled"))

(defvar digistar-time-record-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'digistar-time-record-init-or-insert)
    (define-key map (kbd "S-SPC") #'digistar-time-record-init-or-insert-relative)
    (define-key map (kbd "C-c C-c") #'digistar-time-record-mode-done)
    map))

(define-minor-mode digistar-time-record-mode
  "A minor mode for quickly creating a set of timestamps in a script.

Digistar-Time-Record mode is a minor mode that records
timestamps into a Digistar script in realtime when you press SPC
or S-SPC.  Once enabled, the first press of SPC initializes the
relative clock to `digistar-absolute-time-at-point`.  Subsequent
presses of SPC or S-SPC insert new timestamps into the script
based on that initialization time.  SPC inserts an absolute
timestamp and S-SPC inserts a relative timestamp."
  :lighter " Time-Record"
  :keymap digistar-time-record-mode-map
  (cond
   (digistar-time-record-mode
    (message "digistar-time-record-mode: C-c C-c to finish"))
   (t
    (setq digistar-time-record-last-time nil))))


;;
;; Digistar mode
;;

(defcustom digistar-tab-width 12
  "Value for `tab-width' in Digistar-mode buffers."
  :type 'integer
  :group 'digistar)

(defvar digistar-menu-bar-menu
  (let ((map (make-sparse-keymap "Digistar")))
    (define-key map [digistar-play-script]
                '(menu-item "Play Script" digistar-play-script
                            :help "Play the script in Digistar"))
    map))

(defvar digistar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap indent-for-tab-command] #'digistar-indent-for-tab-command)
    (define-key map (kbd "C-c TAB") #'digistar-insert-filepath)
    (define-key map (kbd "C-c C-f") #'digistar-find-file-at-point)
    (define-key map (kbd "C-c C-l") #'digistar-show-lis-file)
    (define-key map (kbd "C-c C-p") #'digistar-play-script)
    (define-key map (kbd "C-c C-t") #'digistar-show-absolute-time)
    (define-key map (kbd "C-c C-r") #'digistar-time-record-mode)
    (define-key map [menu-bar digistar-menu] (cons "Digistar" digistar-menu-bar-menu))
    map)
  "The keymap for Digistar mode.")

(defun digistar-make-tool-bar-map ()
  "Generate `tool-bar-map' when starting Digistar mode.

The reason it must be generated on demand rather than defined
when loading digistar-mode.el is that there is no way that I know
of to just append buttons to the default `tool-bar-map' - instead
we must clone `tool-bar-map' and append our button to that clone.
Since the user may have customized `tool-bar-map' at any point
during runtime, we must make our clone as late as possible."
  (let ((map (keymap-canonicalize tool-bar-map)))
    (define-key-after map [separator-digistar] menu-bar-separator)
    (define-key-after map [digistar-play-script]
      `(menu-item "Play Script" digistar-play-script
                  :help "Play the script in Digistar"
                  :image ,(tool-bar--image-expression
                           (digistar-mode-asset "images/digistar-play"))))
    map))

(defvar digistar-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?# "<" table)  ;; comment syntax
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    table)
  "The syntax table for font-lock in Digistar mode.")

(defun digistar-highlight-line (limit)
  "Font lock helper for Digistar syntax highlighting.

LIMIT is provided by font lock."
  (let (class0b class0e
        file0b file0e
        dur0b dur0e dur1b dur1e)
    (when (re-search-forward digistar-command-re limit t)
      ;;XXX maybe instead of searching to eol, we should search up to the
      ;;    first comment character on the line, or eol if there is no
      ;;    comment.
      (let ((eol (point-at-eol)))
        (pcase-let ((`(,g0b ,g0e ,g1b ,g1e ,g2b ,g2e)
                     (match-data)))
          (let ((object (match-string 1))
                (cmdorprop (match-string 2)))
            (unless (member object
                            '("capture" "dome" "eye" "js" "scene" "script"))
              (setq g1b nil
                    g1e nil))
            (cond
             ((string= "is" cmdorprop)
              (when (looking-at (rx-to-string
                                 `(: (+ blank)
                                     (group (regexp ,digistar-identifier-re)))))
                (goto-char (match-end 0))
                (setq class0b (match-beginning 1)
                      class0e (match-end 1))))
             ;; not a special word
             ((not (member cmdorprop
                           `("add" "delete" "face" "goto" "init" "loop"
                             "moveto" "pause" "play" "remove" "reset"
                             "stop" "turnto" "on" "off")))
              (setq g2b nil
                    g2e nil))))
          ;; filenames
          (when (or (re-search-forward (rx (group "$" (* (not (any "#" ";"))))) eol t)
                    (re-search-forward (rx (* blank)
                                           (group (* (not (any "#" ";")))
                                                  (any "/" "\\")
                                                  (* (not (any "#" ";")))))
                                       eol t))
            (setq file0b (match-beginning 1)
                  file0e (match-end 1)))
          ;; duration
          (when (re-search-forward (rx bow (group "dur" (optional "ation"))
                                       (* blank) (group (* (any "." num))))
                                   eol t)
            (setq dur0b (match-beginning 1)
                  dur0e (match-end 1)
                  dur1b (match-beginning 2)
                  dur1e (match-end 2)))
          (re-search-forward (rx (* (not (any "#" ";")))) eol t)
          (set-match-data
           (list g0b g0e
                 g1b g1e
                 g2b g2e
                 class0b class0e
                 file0b file0e
                 dur0b dur0e
                 dur1b dur1e))
          t)))))


(defvar digistar-font-lock-keywords
  `(;; errors in .lis files
    ("^!.*$" . font-lock-warning-face)

    ;; timestamps
    ("^[[:blank:]]*\\(\\+?[0-9:.]+\\)"
     (1 font-lock-preprocessor-face))

    ;; commands
    (digistar-highlight-line
     (1 font-lock-keyword-face nil t) ;; special objects
     (2 font-lock-keyword-face nil t)
     (3 font-lock-type-face nil t) ;; classname/prototype following 'is'
     (4 font-lock-string-face nil t) ;; filename
     (5 font-lock-keyword-face nil t) ;; duration
     (6 font-lock-constant-face nil t)) ;; duration
)
  "A `font-lock-keywords' table for Digistar mode.  See `font-lock-defaults'.")

(defun digistar-electric-indent-function (c)
  "Hook for `electric-indent-functions'.

C is for `electric-indent-functions'."
  (and (memq c '(?+ ?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9 ?. ?:))
       (eolp)
       (string-match "^\\s-*[0-9:.+]+$"
                     (buffer-substring (point-at-bol) (point)))))

(defun digistar-indent-line-function ()
  "An `indent-line-function' for Digistar scripts.

Indents timestamps to column 0 and commands with a tab."
  (let (bol
        toplevel-comment-start
        timestamp-start
        timestamp-end
        command-start
        (pt (point)))
    (save-excursion
      (beginning-of-line)
      (setq bol (point))
      (cond
       ((looking-at "[[:blank:]]*\\(###\\|#+[[:blank:]]*[0-9+]\\|#[[:blank:]]*{\\[\\)")
        (setq toplevel-comment-start (match-beginning 1)))
       ((looking-at "[[:blank:]]*\\([0-9:.+]+\\)?[[:blank:]]*\\(.+\\)?$")
        (setq timestamp-start (match-beginning 1)
              timestamp-end (match-end 1)
              command-start (match-beginning 2)))))
    (cond
     (toplevel-comment-start
      (unless (= bol toplevel-comment-start)
        (delete-region bol toplevel-comment-start)))
     (timestamp-start
      (when command-start
        (cond
         ((string= "\t" (buffer-substring timestamp-end command-start))
          (when (>= pt timestamp-end)
            (forward-char)))
         (t (delete-region timestamp-end command-start)
            (cond
             ((or (< pt timestamp-end) (> pt command-start))
              (save-excursion
                (goto-char timestamp-end)
                (insert "\t")))
             (t (goto-char timestamp-end)
                (insert "\t"))))))
      (unless (= bol timestamp-start)
        (delete-region bol timestamp-start)))
     ((and command-start (> (point) command-start))
      (save-excursion
        (indent-line-to tab-width)))
     (t
      (indent-line-to tab-width)))))

(defun digistar-indent-for-tab-command (&optional arg)
  "Indent according to Digistar conventions.

If at the end of a line with only a timestamp, ARG is passed to `insert-tab'."
  (interactive "P")
  (cond
   ;; The region is active, indent it.
   ((use-region-p)
    (indent-region (region-beginning) (region-end)))
   ((and (eolp)
         (string-match "^[0-9:.+]+$"
                       (buffer-substring (point-at-bol) (point))))
    (insert-tab arg))
   (t
    (funcall indent-line-function))))

(defalias 'digistar-parent-mode
  (if (fboundp 'prog-mode) 'prog-mode 'fundamental-mode))

;;;###autoload
(define-derived-mode digistar-mode digistar-parent-mode
  "Digistar"
  "A major mode for Digistar scripts.

\\{digistar-mode-map}"
  :syntax-table digistar-syntax-table

  ;; Indentation
  (set (make-local-variable 'tab-always-indent) nil)
  (set (make-local-variable 'indent-line-function)
       #'digistar-indent-line-function)
  (set (make-local-variable 'tab-width) digistar-tab-width)
  (add-hook 'electric-indent-functions
            #'digistar-electric-indent-function nil t)

  ;; Syntax Highlighting
  (setq font-lock-defaults (list digistar-font-lock-keywords nil t))

  ;; Comments
  (set (make-local-variable 'comment-start) "# ")
  (set (make-local-variable 'comment-end) "")

  ;; Whitespace
  (set (make-local-variable 'indent-tabs-mode) t)
  (set (make-local-variable 'require-final-newline) t)
  (set (make-local-variable 'align-to-tab-stop) nil)

  ;; Menu & Toolbar
  (setq-local tool-bar-map (digistar-make-tool-bar-map)))


;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ds\\'" . digistar-mode))


;;
;; Digistar MRSLog mode
;;

(defface digistar-mrslog-timestamp
  '((t :background "gray10" :foreground "gray50"))
  "Face used in Digistar MRSLog Mode."
  :group 'digistar-faces)
(defvar digistar-mrslog-timestamp-face 'digistar-mrslog-timestamp)

(defface digistar-mrslog-time
  '((t :inherit digistar-mrslog-timestamp :foreground "lightblue"))
  "Face used in Digistar MRSLog Mode."
  :group 'digistar-faces)
(defvar digistar-mrslog-time-face 'digistar-mrslog-time)

(defface digistar-mrslog-mrs
  '((t :foreground "violet"))
  "Face used in Digistar MRSLog Mode."
  :group 'digistar-faces)
(defvar digistar-mrslog-mrs-face 'digistar-mrslog-mrs)

(defface digistar-mrslog-oid
  '((t :foreground "gray50"))
  "Face used in Digistar MRSLog Mode."
  :group 'digistar-faces)
(defvar digistar-mrslog-oid-face 'digistar-mrslog-oid)

(defface digistar-mrslog-cmdecho-time
  '((t :foreground "lightblue"))
  "Face used in Digistar MRSLog Mode."
  :group 'digistar-faces)
(defvar digistar-mrslog-cmdecho-time-face 'digistar-mrslog-cmdecho-time)

(defface digistar-mrslog-cmdecho-pathname
  '((t :foreground "chartreuse3"))
  "Face used in Digistar MRSLog Mode."
  :group 'digistar-faces)
(defvar digistar-mrslog-cmdecho-pathname-face 'digistar-mrslog-cmdecho-pathname)

(defvar digistar-mrslog-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-f") 'digistar-find-file-at-point)
    map)
  "The keymap for Digistar MRSLog Mode.")

(defvar digistar-mrslog-line-re
  (rx-to-string
   `(: bol
       (group
        (group (1+ num) ?/ (1+ num) ?/ (1+ num)) ;; date
        (1+ space)
        (group (1+ num) ?: (1+ num) ?: (1+ num)) ;; time
        (1+ space)
        (group (or "AM" "PM"))
        ?: space)
       (regexp ".*"))))

(defvar digistar-mrslog-oid-re
  (rx-to-string
   `(: (group "OID") ?: space
       (group (1+ (any num))) space ?: space
       (group (1+ (any alnum))) space ?: space
       (group (1+ (any alpha))) space ?: space)))

(defvar digistar-mrslog-cmdecho-re
  (rx-to-string
   `(: (group (1+ graphic))                     ;; script name
       (? (1+ space) (group (0+ (any num ?.)))) ;; script timestamp
       ?: space
       (group (*? (not (any ?$ ?\"))))
       (? (or (group ?\$ (* anychar))
           (group ?\" (* anychar))
           (group "dur" (? "ation") space (1+ (any ?. num))
                  (? space (1+ (any ?. num)) (? space (1+ (any ?. num)))))))
       eol)))

(defun digistar-mrslog-highlight-oid-line (limit)
  "Font lock helper for Digistar MRSLog Mode.

LIMIT is provided by font lock."
  (let ((whole-match-b (point))
        (whole-match-e limit))
    (when (re-search-forward digistar-mrslog-oid-re limit t)
      (let ((oid-common-e (match-end 0))
            (oid-b (match-beginning 1))
            (oid-e (match-end 1))
            (oid-id-b (match-beginning 2))
            (oid-id-e (match-end 2))
            (oid-name-b (match-beginning 3))
            (oid-name-e (match-end 3))
            (category-b (match-beginning 4))
            (category-e (match-end 4))
            (category (match-string 4))
            status-b status-e warning-b warning-e
            error-b error-e
            cmdecho-script-b cmdecho-script-e
            cmdecho-time-b cmdecho-time-e
            cmdecho-command-b cmdecho-command-e
            cmdecho-pathname-b cmdecho-pathname-e
            cmdecho-string-b cmdecho-string-e
            cmdecho-duration-b cmdecho-duration-e)

        ;; status warning error
        (cond
         ((string= "CmdEcho" category)
          (when (re-search-forward digistar-mrslog-cmdecho-re limit t)
            (setq cmdecho-script-b (match-beginning 1)
                  cmdecho-script-e (match-end 1)
                  cmdecho-time-b (match-beginning 2)
                  cmdecho-time-e (match-end 2)
                  cmdecho-command-b (match-beginning 3)
                  cmdecho-command-e (match-end 3)
                  cmdecho-pathname-b (match-beginning 4)
                  cmdecho-pathname-e (match-end 4)
                  cmdecho-string-b (match-beginning 5)
                  cmdecho-string-e (match-end 5)
                  cmdecho-duration-b (match-beginning 6)
                  cmdecho-duration-e (match-end 6))))
         ((member category '("Status" "SystemStatus" "LogOnly"))
          (setq status-b oid-common-e
                status-e whole-match-e))
         ((string= "Warning" category)
          (setq warning-b oid-common-e
                warning-e whole-match-e))
         ((member category '("Error" "Fatal"))
          (setq error-b oid-common-e
                error-e whole-match-e)))

        (forward-line)
        (set-match-data
         (list whole-match-b whole-match-e
               oid-b oid-e
               oid-id-b oid-id-e
               oid-name-b oid-name-e
               category-b category-e
               status-b status-e
               warning-b warning-e
               error-b error-e
               cmdecho-script-b cmdecho-script-e
               cmdecho-time-b cmdecho-time-e
               cmdecho-command-b cmdecho-command-e
               cmdecho-pathname-b cmdecho-pathname-e
               cmdecho-string-b cmdecho-string-e
               cmdecho-duration-b cmdecho-duration-e))
        t))))

(defvar digistar-mrslog-font-lock-keywords
  (let ((override t)
        (laxmatch t))
    `((,digistar-mrslog-line-re
       (1 digistar-mrslog-timestamp-face)
       (3 digistar-mrslog-time-face ,override nil)

       ;; OID entries
       (digistar-mrslog-highlight-oid-line ;; anchored match
        (goto-char (match-end 1)) nil
        ; (0 font-lock-keyword-face) ;; whole line
        (1 digistar-mrslog-oid-face ,override) ;; OID
        (2 digistar-mrslog-oid-face ,override) ;; OID ID
        (3 digistar-mrslog-oid-face ,override) ;; OID Name
        (4 font-lock-keyword-face ,override) ;; Message Category
        (5 digistar-mrslog-oid-face ,override ,laxmatch) ;; status
        (6 'warning ,override ,laxmatch) ;; warning
        (7 'error ,override ,laxmatch) ;; error
        (8 font-lock-constant-face ,override ,laxmatch) ;; CmdEcho script name
        (9 digistar-mrslog-cmdecho-time-face ,override ,laxmatch) ;; CmdEcho timestamp
        ; (10 'error ,override ,laxmatch) ;; CmdEcho command
        (11 digistar-mrslog-cmdecho-pathname-face ,override ,laxmatch) ;; CmdEcho pathname
        (12 font-lock-string-face ,override ,laxmatch) ;; CmdEcho string
        (13 font-lock-type-face ,override ,laxmatch) ;; CmdEcho duration
        )

       ;; MRS entries
       (".*"                    ;; anchored match
        (goto-char (match-end 1)) nil
        (0 digistar-mrslog-mrs-face)))))

  "A `font-lock-keywords' table for Digistar MRSLog Mode.

See `font-lock-defaults'.")

;;;###autoload
(define-derived-mode digistar-mrslog-mode fundamental-mode
  "Digistar MRSLog"
  "A major mode for Digistar MRSLog files.

\\{digistar-mrslog-mode-map}"

  ;; Syntax Highlighting
  (setq font-lock-defaults (list digistar-mrslog-font-lock-keywords t t)))


;;;###autoload
(add-to-list 'auto-mode-alist '("\\.mrslog\\.txt\\'" . digistar-mrslog-mode))


(provide 'digistar-mode)
;;; digistar-mode.el ends here
