;;; helm-deft.el --- helm module for grepping note files over directories

;; Copyright (C) 2014 Derek Feichtinger

;; Author: Derek Feichtinger <dfeich@gmail.com>
;; Keywords: convenience
;; Homepage: https://github.com/dfeich/helm-deft
;; Version: TODO
;; Package-Requires: ((helm "1.7.7") (f "0.17.0") (cl-lib "0.5") (emacs "24.4"))

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

;;; Commentary:
;; Helm command to find files fast based on contents and filename. Inspired
;; by the great emacs deft package. It allows defining a list of input directories
;; that can be defined and that are searched recursively.
;;
;; helm-deft is composed of three search sources
;; - file names: simple match of pattern vs. file name
;; - file match: shows file names of files where all of the individual patterns
;;   match anywhere in the file
;; - file contents: show the lines where the last word in the search patterns
;;   matches

;;; Code:

(require 'helm)
(require 'helm-grep)
(require 'helm-files)
(require 'f)
(require 'cl-lib)
(require 'subr-x)

(defgroup helm-deft nil
  "customization group for the helm-deft utility" :group 'helm :version 24.3)

(defcustom helm-deft-dir-list
  '("~/Documents")
  "List of directories in which to search recursively for candidate files.
It is possible to either define it as a simple list of strings or as an association
list structured to contain group names and the respective directory list definitions.

Example:
'((\"group1\" . (\"dir1\" \"dir2\" \"dir3\"))
  (\"group2\" . (\"dir1\" \"dir4\")))
"
  :group 'helm-deft
  )

(defcustom helm-deft-extension "org"
  "Defines file extension for identifying candidate files to be searched for.")

(defcustom helm-deft-fname-search-fn 'helm-deft-fname-search-default
  "Function for searching all preconfigured directories for matching files.

Returns the filenames as a list.")

(defvar helm-deft-active-dir-list nil
  "Contains the currently active list of directories to search")

(defvar helm-deft-file-list nil
  "Variable to store the list of candidate files.
This is constant over the invocation of one helm-deft.")

(defvar helm-deft-backup-file-list nil
  "Variable to store a backup of the list of candidate files.
Used for allowing the user to reset the candidate file list after manipulations.")

(defvar helm-deft-matching-files '()
  "Used for building the list of filenames that the grep matched.")

(defvar helm-deft-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map helm-map)
    (define-key map (kbd "C-r") 'helm-deft-rotate-searchkeys)
    (define-key map (kbd "C-d") 'helm-deft-remove-candidate-file)
    (define-key map (kbd "C-s") 'helm-deft-set-to-marked)
    (define-key map (kbd "C-.") 'helm-deft-reset-to-init)
    (define-key map (kbd "C-,") 'helm-deft-change-dir-list)
    (delq nil map))
  "Helm keymap used for helm deft sources.")

(defvar helm-source-deft-fn
  (helm-build-in-buffer-source "File Names"
    :header-name (lambda (name)
		   (format "%s:   %s" name  "C-r: rotate pattern C-s/C-d: set/delete (marked) candidates"))
    :init (lambda ()
	    (progn (unless helm-deft-file-list
		     (setq helm-deft-file-list (funcall helm-deft-fname-search-fn))
		     (setq helm-deft-backup-file-list helm-deft-file-list))
		   (helm-init-candidates-in-buffer 'local
		     helm-deft-file-list)
		   ))
    :match-part (lambda (c) (helm-basename c))
    :action helm-find-files-actions
    ;; :candidate-transformer (lambda (c) (sort (helm-highlight-files c)
    ;; 					     (lambda (a b)
    ;; 					       (string< (downcase (car a))
    ;; 							(downcase (car b))))))
    :keymap helm-deft-map
    :cleanup (lambda () (setq helm-deft-file-list nil))))

(defun helm-deft-fname-search-default ()
  "Search all preconfigured directories for matching files.

Lisp-only default implementation. Returns the filenames as a list."
  (cl-loop for dir in helm-deft-active-dir-list
	   do (assert (file-exists-p dir) nil
		      (format "Directory %s does not exist. Check helm-deft-dir-list" dir))
	   collect (f--files dir (equal (f-ext it) helm-deft-extension) t)
	   into reslst
	   finally (return (apply #'append reslst)))
  )

(defun helm-deft-fname-search-shell ()
  "Search all preconfigured directories for matching files.

Implementation using shell command and a sub process. Returns the
filenames as a list."
  (with-temp-buffer
    (cl-loop for dir in helm-deft-active-dir-list
	     do (assert (file-exists-p dir) nil
			(format "Directory %s does not exist. Check helm-deft-dir-list" dir))
	     do (call-process-shell-command
		 (format "find %s -name \\*.%s" dir helm-deft-extension)
		 nil t)
	     )
    (split-string (buffer-string) "\n")))

(defvar helm-source-deft-filegrep
  (helm-build-async-source "File contents"
    :candidates-process #'helm-deft-fgrep-search
    ;; We use the action from the helm-grep module
    :action #'helm-grep-action
    :requires-pattern 2
    :pattern-transformer (lambda (pattern)
			   (cl-loop for ptr in (split-string pattern "  *" t)
				    if (string-prefix-p "w:" ptr)
				    collect (string-remove-prefix "w:" ptr) into cptr
				    else collect ptr into cptr
				    finally return (mapconcat 'identity cptr " ")))
    :filter-one-by-one (lambda (candidate)
			 ;; we abuse the filter-one-by-one function
			 ;; for building the candidates list for the
			 ;; matching-files source
			 (helm-deft-matching-files-search candidate)
			 ;; we borrow the helm-grep filter function
			 (helm-grep-filter-one-by-one candidate))
    :cleanup (lambda () (when (get-buffer "*helm-deft-proc*")
			  (let ((kill-buffer-query-functions nil))
			    (kill-buffer "*helm-deft-proc*"))))))

;; TODO: I do not remember exactly why I introduced this function. But I guess it was a stepf
;; for first producing the list of matching filenames and then the grep results in contrast to
;; the present was of first getting the full grep results, and then the matching files from them.
(defun helm-deft-build-match-cmd (ptrnlst filelst)
  (if ptrnlst
      (cl-labels ((build-inner-cmd
		   (ptrnlst filelst)
		   (let* ((pattern (pop ptrnlst))
			  (addflags
			   (if (string-prefix-p "w:" pattern)
			       (progn
				 (setq pattern
				       (string-remove-prefix
					"w:" pattern))
				 "-w")
			     "")))
		     (if ptrnlst
			 (format "$(grep %s -Elie '%s' %s)"
				 addflags pattern
				 (build-inner-cmd ptrnlst filelst))
		       (format "$(grep %s -Elie '%s' %s)"
			       addflags pattern filelst)))))
	(build-inner-cmd ptrnlst filelst))
    filelst)
  )

(defun helm-deft-build-cmd (ptrnstr filelst)
  "Builds a grep command based on the patterns and file list.
PTRNSTR may contain multiple search patterns separated by
spaces.  The first pattern will be used to retrieve matching
lines.  All other patterns will be used to pre-select files with
matching lines.  FILELST is a list of file paths"
  (let* ((ptrnlst (reverse (split-string ptrnstr "  *" t)))
	 (firstp (pop ptrnlst))
	 (firstaddflag (if (string-prefix-p "w:" firstp)
			   (progn
			     (setq firstp (string-remove-prefix "w:" firstp))
			     "-w")
			 ""))
	 (filelst (mapconcat 'identity filelst " "))
	 (innercmd (if ptrnlst
		       (cl-labels ((build-inner-cmd
				    (ptrnlst filelst)
				    (let* ((pattern (pop ptrnlst))
					   (addflags
					    (if (string-prefix-p "w:" pattern)
						(progn
						  (setq pattern
							(string-remove-prefix
							 "w:" pattern))
						  "-w")
					      "")))
				      (if ptrnlst
					  (format "$(grep %s -Elie '%s' %s)"
						  addflags pattern
						  (build-inner-cmd ptrnlst filelst))
					(format "$(grep %s -Elie '%s' %s)"
						addflags pattern filelst)))))
			 (build-inner-cmd ptrnlst filelst))
		     filelst)))
    (format "grep %s -EHine '%s' %s" firstaddflag firstp innercmd))
  )

(defun helm-deft-fgrep-search ()
  "Greps for the helm search pattern in the configuration defined file list."
  (setq helm-deft-matching-files '())
  ;; need to pass helm-input (the real input line) to the build
  ;; function since helm-pattern is already cleaned by the
  ;; pattern-transformer function of helm-source-deft-filegrep
  (let* ((shcmd (helm-deft-build-cmd helm-input helm-deft-file-list)))
    (helm-log "grep command: %s" shcmd)
    ;; the function must return the process object
    (prog1
	;; a process buffer is not needed since helm is collecting the
	;; output using a filter function for the process
	(start-process-shell-command "helm-deft-proc" nil
				     shcmd)
      (set-process-sentinel
       (get-process "helm-deft-proc")
       (lambda (process event)
	 (helm-log "file contents sentinel event: %s"
		   (replace-regexp-in-string "\n" "" event))
      	 (cond
	  ;; Helm may kill the process in
	  ;; helm-output-filter--process-source if the number of results is
	  ;; getting larger than the limit.
	  ;; TODO: maybe do something more sensible int the sentinel
      	  ((or (string= event "finished\n")
	       (string= event "killed\n"))
	   (helm-log "doing nothing")
      	   ;; (with-helm-window
      	   ;;   (setq mode-line-format
      	   ;; 	   '(" " mode-line-buffer-identification " "
      	   ;; 	     (:eval (format "L%s" (helm-candidate-number-at-point))) " "
      	   ;; 	     (:eval (propertize
      	   ;; 		     ;; TODO: The count is wrong since it counts all sources
      	   ;; 		     (format
      	   ;; 		      "[Grep process finished - (%s results)] "
      	   ;; 		      (max (1- (count-lines
      	   ;; 				(point-min)
      	   ;; 				(point-max)))
      	   ;; 			   0))
      	   ;; 		     'face 'helm-grep-finish))))
	   ;;(force-mode-line-update)
	   ;; )
	   
	   )

	  ;; Catch unhandled events in log.
	  (t
	   (helm-log
	    "Unhandled event in process sentinel: %s"
	    (replace-regexp-in-string "\n" "" event))))
	 ))
      )
    ))


(defvar helm-source-deft-matching-files
  (helm-build-sync-source "Matching Files"
    :header-name (lambda (name)
		   (format "%s:   %s" name  "C-r: rotate pattern C-s/C-d: set/delete (marked) candidates"))
    :candidates 'helm-deft-matching-files
    :action helm-find-files-actions
    ;; do not do string matching on the resulting filenames (i.e. all candidates
    ;; match)
    :match (lambda (candidate) t)
    ;; (candidate-transformer . (lambda (c) (sort (helm-highlight-files c)
    ;; 					       (lambda (a b)
    ;; 						 (string< (downcase (car a))
    ;; 							  (downcase (car b)))))))
    :requires-pattern 2
    :volatile t
    :keymap helm-deft-map
    )
  "Source definition for showing matching files from the grep buffer of the `helm-deft' utility.")


(defun helm-deft-matching-files-search (candidate)
  "Add entry to helm-deft-matching-files list from a grep CANDIDATE."
  (when (string-match "\\([^:]+\\):[0-9]+:" candidate)
    (pushnew (match-string 1 candidate) helm-deft-matching-files :test #'equal)))


(defun helm-deft-rotate-searchkeys ()
  "Rotate the words of the search pattern in the helm minibuffer."
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

(defun helm-deft-remove-candidate-file ()
  "Remove the file under point from the list of candidates."
  (interactive)
  ;; helm-get-selection returns current item under point
  ;; helm-marked-candidates returns all marked candidates or the item under point
  (dolist (selection (helm-marked-candidates))
    (when (string-match "\\([^:]+\\):[0-9]+:" selection)
      (setq selection (match-string 1 selection)))
    (setq helm-deft-file-list (delete selection helm-deft-file-list)))
  (helm-unmark-all)
  (helm-force-update))

(defun helm-deft-set-to-marked ()
  "Set the filelist to the marked files."
  (interactive)
  (setq helm-deft-file-list (helm-marked-candidates))
  (helm-unmark-all)
  (helm-force-update))

(defun helm-deft-reset-to-init ()
  "Set the filelist back to the initial candidates"
  (interactive)
  (setq helm-deft-file-list helm-deft-backup-file-list)
  (helm-unmark-all)
  (helm-force-update))

(defun helm-deft-change-dir-list ()
  "Change the active directory search list.
Allows to select another directory group from `helm-deft-dir-list'."
  (interactive)
  (when (eq 'cons (type-of (car helm-deft-dir-list)))
    (setq helm-deft-active-dir-list
	  (car (helm-comp-read "dir group: " helm-deft-dir-list
			       :must-match t
			       :allow-nest t)))
    (setq helm-deft-file-list nil) ; this will trigger full reinitialization
    (helm-force-update))
  ;; ;; another way to set the group in the minibuffer using standard emacs functionality 
  ;; (let ((enable-recursive-minibuffers t))
  ;;   (setq helm-deft-active-dir-list
  ;; 	  (completing-read "group: " '(("a" . (a b c)) ("x" . (x y z))) nil t)))
  )

;;;###autoload
(defun helm-deft ()
  "Preconfigured `helm' module for locating matching files.
Either the filename or the file contents must match the query
string.  Inspired by the Emacs `deft' extension"
  (interactive)
  (assert helm-deft-extension nil "No file extension defined for helm-deft")
  (assert helm-deft-dir-list nil "No directories defined for helm-deft")
  (setq helm-deft-active-dir-list
	(if (eq  'cons (type-of (car helm-deft-dir-list)))
	    (cadar helm-deft-dir-list)
	  helm-deft-dir-list))
  (helm :sources '(helm-source-deft-fn helm-source-deft-matching-files
				       helm-source-deft-filegrep)
	:keymap helm-deft-map))

(provide 'helm-deft)
;;; helm-deft.el ends here
