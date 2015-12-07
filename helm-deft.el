;;; helm-deft.el --- helm module for grepping note files over directories

;; Copyright (C) 2014 Derek Feichtinger

;; Author: Derek Feichtinger <derek.feichtinger@psi.ch>
;; Keywords: convenience
;; Homepage: https://github.com/dfeich/helm-deft
;; Version: TODO

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Code:

(require 'helm)
(require 'helm-grep)
(require 'helm-files)
(require 'f)
(require 'cl)

(defgroup helm-deft nil
  "customization group for the helm-deft utility" :group 'helm :version 24.3)

(defcustom helm-deft-dir-list
  '("~/Documents")
  "list of directories in which to search recursively for candidate files."
  :group 'helm-deft
  )

(defcustom helm-deft-extension "org"
  "defines file extension for identifying candidate files to be searched for.")

(defvar helm-deft-file-list ""
  "variable to store the list of candidate files. This is
  constant over the invocation of one helm-deft.")

(defvar helm-deft-matching-files '()
  "used for building the list of filenames that the grep matched.")

(defvar helm-source-deft-fn
  '((name . "File Names")
    (init . (lambda ()
	      (progn (setq helm-deft-file-list (helm-deft-fname-search))
		     (with-current-buffer (helm-candidate-buffer 'local)
		       (insert (mapconcat 'identity
					  helm-deft-file-list "\n"))))))
    (candidates-in-buffer)
    ;; matching is done in the buffer when candidates-in-buffer is used
    ;; We only want against the basename and not the full path
    (match-part . (lambda (c) (helm-basename c)))
    (type . file)
    ;; Note: We override the transformer that the file type brings. We
    ;; want the file list sorted
    (candidate-transformer . (lambda (c) (sort (helm-highlight-files c)
					       (lambda (a b)
						 (string< (downcase (car a))
							  (downcase (car b)))))))
    ;; (action . (("open file" . (lambda (candidate)
    ;; 				(find-file candidate)))))
    ;;(persistent-help . "show name")    
    )
  "Source definition for matching filenames of the `helm-deft' utility")

(defun helm-deft-fname-search ()
  "search all preconfigured directories for matching files and return the
filenames as a list"
  (assert helm-deft-extension nil "No file extension defined for helm-deft")
  (assert helm-deft-dir-list nil "No directories defined for helm-deft")
  (cl-loop for dir in helm-deft-dir-list
	   do (assert (file-exists-p dir) nil
		      (format "Directory %s does not exist. Check helm-deft-dir-list" dir))
	   collect (f--files dir (equal (f-ext it) helm-deft-extension) t)
	   into reslst
	   finally (return (apply #'append reslst)))
  )

(defvar helm-source-deft-filegrep
  '((name . "File Contents")
    (candidates-process . helm-deft-fgrep-search)
    ;; We use the action from the helm-grep module
    (action . helm-grep-action)
    (requires-pattern)
    ;; we abuse the filter-one-by-one function for building the
    ;; candidates list for the matching-files source
    (filter-one-by-one . (lambda (candidate)
			   (helm-deft-matching-files-search candidate)
			   (helm-grep-filter-one-by-one candidate)))
    (cleanup . (lambda () (when (get-buffer "*helm-deft-proc*")
			    (let ((kill-buffer-query-functions nil))
			      (kill-buffer "*helm-deft-proc*")))))
    )
  "Source definition for matching against file contents for the
  `helm-deft' utility")

(defun helm-deft-build-cmd (ptrnstr filelst)
  "Builds a grep command where PTRNSTR may contain multiple search patterns
separated by spaces. The first pattern will be used to retrieve matching lines.
All other patterns will be used to pre-select files with matching lines.
FILELST is a list of file paths"
  (let* ((ptrnlst (reverse (split-string ptrnstr "  *" t)))
	 (firstp (pop ptrnlst))
	 (filelst (mapconcat 'identity filelst " "))
	 (innercmd (if ptrnlst
		       (cl-labels ((build-inner-cmd
				    (ptrnlst filelst)
				    (let ((pattern (pop ptrnlst)))
				      (if ptrnlst
					  (format "$(grep -Elie '%s' %s)" pattern
						  (build-inner-cmd ptrnlst filelst))
					(format "$(grep -Elie '%s' %s)"
						pattern filelst)))))
			 (build-inner-cmd ptrnlst filelst))
		     filelst)))
    (format "grep -EHine '%s' %s" firstp innercmd))
  )

(defun helm-deft-fgrep-search ()
  "greps for the helm search pattern in the configuration defined
file list"
  (setq helm-deft-matching-files '())
  (let* ((shcmd (helm-deft-build-cmd helm-pattern helm-deft-file-list)))
    (helm-log "grep command: %s" shcmd)
    ;; the function must return the process object
    (prog1
	(start-process-shell-command "helm-deft-proc" "*helm-deft-proc*"
				     shcmd)
      (set-process-sentinel
       (get-process "helm-deft-proc")
       (lambda (process event)      	 
	 (cond
	  ((string= event "finished\n")
	   (with-helm-window
	     (setq mode-line-format
		   '(" " mode-line-buffer-identification " "
		     (:eval (format "L%s" (helm-candidate-number-at-point))) " "
		     (:eval (propertize
			     ;; TODO: The count is wrong since it counts all sources
			     (format
			      "[Grep process finished - (%s results)] "
			      (max (1- (count-lines
					(point-min)
					(point-max)))
				   0))
			     'face 'helm-grep-finish))))
	     (force-mode-line-update))
	   ;; must NOT DO a targeted update here. Seems to call also this source
	   ;; and we end in an infinite loop
	   ;; (helm-update nil helm-source-deft-matching-files)
	   )
	  ;; Catch error output in log.
	  (t (helm-log
	      "Error: Grep %s"
	      (replace-regexp-in-string "\n" "" event))))
	 ))
      )
    ))

(defvar helm-source-deft-matching-files
  '((name . "Matching Files")
    (candidates . helm-deft-matching-files)
    (type . file)
    ;; need to override the file type's match settings
    (match . (lambda (candidate) t))
    (candidate-transformer . (lambda (c) (sort (helm-highlight-files c)
    					       (lambda (a b)
    						 (string< (downcase (car a))
    							  (downcase (car b)))))))
    (requires-pattern)
    (volatile)
    )
  "Source definition for showing matching files from the grep buffer of the
  `helm-deft' utility")

(defun helm-deft-matching-files-search (candidate)
  (when (string-match "\\([^:]+\\):[0-9]+:" candidate)
    (pushnew (match-string 1 candidate) helm-deft-matching-files :test #'equal)))

;; (defun helm-deft-matching-files-search ()
;;   (when (get-buffer "*helm-deft-proc*")
;;     (with-current-buffer "*helm-deft-proc*"
;;       (beginning-of-buffer)
;;       (while (and
;; 	      (looking-at "^\\([^:]+\\):[0-9]+:")
;; 	      (not (equal (forward-line) 1)))
;; 	(push (match-string 1) helm-deft-matching-files)))
;;     (cl-remove-duplicates helm-deft-matching-files :test #'equal))
;;   )

(defun helm-deft-rotate-searchkeys ()
  "rotate the words of the search pattern in the helm minibuffer"
  (interactive)
  (helm-log "Executing helm-deft-rotate-searchkeys")
  (let ((patlst (split-string helm-pattern "  *")))
    (when (and (>= (length patlst) 1)
	       (> (length (car patlst)) 0))
      (delete-minibuffer-contents)
      (insert (mapconcat #'identity
			 (append (cdr patlst) (list (car patlst)))
			 " "))
      (helm-update)))
  )

(defvar helm-deft-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map helm-map)
    (define-key map (kbd "C-r") 'helm-deft-rotate-searchkeys)
    (delq nil map))
  "helm keymap used for helm deft sources")

;;;###autoload
(defun helm-deft ()
  "Preconfigured `helm' module for locating note files where either the
filename or the file contents match the query string. Inspired by the
emacs `deft' extension"
  (interactive)
  (helm :sources '(helm-source-deft-fn helm-source-deft-matching-files
				       helm-source-deft-filegrep)
	:keymap helm-deft-map))

(provide 'helm-deft)



