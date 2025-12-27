;;; clickup-emacs.el --- ClickUp.com integration -*- lexical-binding: t; -*-

;; Copyright (C) 2025
;; Author: Simon GANON
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (request "0.3.0") (dash "2.17.0") (s "1.12.0"))
;; Keywords: tools, org, clickup
;; URL: https://github.com/sganon/clickup-emacs

;;; Commentary:
;; clickup-emacs.el provides an interface to ClickUp.com task tracking from Emacs.
;; It performs a one-way sync from defined ClickUp lists to specific Org files,
;; allowing you to view your tasks and assignments directly in Org mode.

;;; Code:

;; Dependencies
(require 'request)
(require 'json)
(require 'dash)
(require 's)
(require 'org)
(require 'cl-lib)

;;; Customization and Variables

(defgroup clickup-emacs nil
  "Integration with ClickUp task tracking."
  :group 'tools
  :prefix "clickup-emacs-")

(defcustom clickup-emacs-api-key nil
  "API key for ClickUp.com.
Can be set manually or loaded from CLICKUP_API_KEY environment variable."
  :type 'string
  :group 'clickup-emacs)

(defcustom clickup-emacs-api-url "https://api.clickup.com/api/v2"
  "REST API endpoint URL for ClickUp."
  :type 'string
  :group 'clickup-emacs)

(defcustom clickup-emacs-list-mappings '()
  "A list of plists mapping ClickUp List IDs to specific Org files.
Example:
  '((:id \"12345678\" :file \"~/org/work.org\")
    (:id \"87654321\" :file \"~/org/personal.org\"))"
  :type '(repeat (plist :key-type symbol :value-type string))
  :group 'clickup-emacs)

(defcustom clickup-emacs-filter-statuses
  '("BACKLOG" "TO DO" "IN PROGRESS" "BLOCKED" "TECH REVIEW" "REVIEW")
  "List of specific ClickUp statuses to fetch.
If nil, fetches all non-archived tasks.
Note: ClickUp expects exact status names."
  :type '(repeat string)
  :group 'clickup-emacs)

(defcustom clickup-emacs-filter-assigned-to-me t
  "If non-nil, only fetch tasks assigned to the authenticated user."
  :type 'boolean
  :group 'clickup-emacs)

(defcustom clickup-emacs-debug nil
  "Enable debug logging for ClickUp requests."
  :type 'boolean
  :group 'clickup-emacs)

(defcustom clickup-emacs-sync-custom-fields '("Custom ID")
  "List of ClickUp Custom Field names to sync to Org properties.
Example: '(\"Custom ID\" \"Sprint Points\" \"Client Name\")"
  :type '(repeat string)
  :group 'clickup-emacs)

(defcustom clickup-emacs-status-mapping
  '(("backlog" . "BACKLOG")
    ("to do" . "TODO")
    ("in progress" . "IN-PROGRESS")
    ("blocked" . "BLOCKED")
    ("tech review" . "TECH-REVIEW")
    ("review" . "REVIEW")
    ("done" . "DONE"))
  "Mapping between ClickUp status names and 'org-mode' TODO states.
Keys are the ClickUp status strings (case-insensitive).
Values are the Org-mode keywords."
  :type '(alist :key-type string :value-type string)
  :group 'clickup-emacs)

;; Internal Cache
(defvar clickup-emacs--current-user-id nil
  "Cache for the authenticated user's ID.")

(defvar clickup-emacs--cache-tasks nil
  "Cache for the most recently fetched tasks.")

;;; Core API Functions

(defun clickup-emacs--headers ()
  "Return headers for ClickUp API requests."
  (unless clickup-emacs-api-key
    (error "ClickUp API key not set."))
  `(("Content-Type" . "application/json")
    ("Authorization" . ,clickup-emacs-api-key)))

(defun clickup-emacs--log (format-string &rest args)
  "Log message with FORMAT-STRING and ARGS if debug is enabled."
  (when clickup-emacs-debug
    (apply #'message (concat "[ClickUp] " format-string) args)))

(defun clickup-emacs--request-async (method endpoint &optional params data-payload success-fn error-fn)
  "Make an async REST request to ClickUp API."
  (clickup-emacs--log "Making async ClickUp request: %s %s" method endpoint)
  
  (unless success-fn
    (setq success-fn (lambda (data) (clickup-emacs--log "Request success: %s" (prin1-to-string data)))))
  (unless error-fn
    (setq error-fn (lambda (err _response _data) (message "ClickUp API error: %s" err))))

  (let ((url (s-concat clickup-emacs-api-url endpoint))
        (request-data (when data-payload (json-encode data-payload)))) 
    (request
      url
      :type (symbol-name method)
      :headers (clickup-emacs--headers)
      :params params
      :data request-data
      :parser 'json-read
      :success (cl-function
                (lambda (&key data &allow-other-keys)
                  (funcall success-fn data)))
      :error (cl-function
              (lambda (&key error-thrown response data &allow-other-keys)
                (funcall error-fn error-thrown response data))))))

(defun clickup-emacs-get-current-user-async (callback)
  "Fetch the authenticated user's ID, using cache if available."
  (if clickup-emacs--current-user-id
      (funcall callback clickup-emacs--current-user-id)
    (clickup-emacs--log "Fetching current user info...")
    (clickup-emacs--request-async 
     'GET "/user" nil nil
     (lambda (response)
       (let ((user (cdr (assoc 'user response))))
         (if user
             (let ((id (cdr (assoc 'id user))))
               (setq clickup-emacs--current-user-id id)
               (clickup-emacs--log "Identified current user as ID: %s" id)
               (funcall callback id))
           (message "Could not identify current user.")
           (funcall callback nil))))
     (lambda (err _r _d)
       (message "Error fetching user: %s" err)
       (funcall callback nil)))))

;;; Task Fetching

(defun clickup-emacs-get-tasks-async (list-id callback)
  "Asynchronously get tasks for LIST-ID, optionally filtering by assignee and status."
  (clickup-emacs--log "Fetching tasks for list %s" list-id)
  
  (let ((start-fetching-fn
         (lambda (&optional user-id)
           (let ((all-tasks nil)
                 (page 0))
             
             (cl-labels ((fetch-next-page ()
                           (let ((params `(("archived" . "false")
                                           ("page" . ,(number-to-string page)))))
                             
                             (when clickup-emacs-filter-statuses
                               (dolist (status clickup-emacs-filter-statuses)
                                 (push (cons "statuses[]" status) params)))
                             
                             (when user-id
                               (push (cons "assignees[]" user-id) params))

                             (clickup-emacs--request-async
                              'GET 
                              (format "/list/%s/task" list-id)
                              params nil
                              (lambda (response)
                                (let ((new-tasks (cdr (assoc 'tasks response))))
                                  (when (vectorp new-tasks)
                                    (setq new-tasks (append new-tasks nil)))

                                  (if (or (null new-tasks) (eq (length new-tasks) 0))
                                      (progn
                                        (message "Fetched %d tasks." (length all-tasks))
                                        (setq clickup-emacs--cache-tasks all-tasks)
                                        (funcall callback all-tasks))
                                    ;; Recurse for next page
                                    (setq all-tasks (append all-tasks new-tasks))
                                    (setq page (1+ page))
                                    (message "Fetching page %d (total: %d)..." page (length all-tasks))
                                    (fetch-next-page))))
                              (lambda (err _r _d)
                                (message "Error fetching tasks: %s" err)
                                (funcall callback all-tasks))))))
               
               (fetch-next-page))))))

    (if clickup-emacs-filter-assigned-to-me
        (clickup-emacs-get-current-user-async start-fetching-fn)
      (funcall start-fetching-fn nil))))

;;; Org Mode Formatting & Writing

(defun clickup-emacs--map-org-state-to-clickup (org-state)
  "Find the ClickUp status string for a given ORG-STATE."
  ;; We search the alist where the CDR (value) matches org-state
  (let ((match (rassoc org-state clickup-emacs-status-mapping)))
    (if match
        (car match) ;; Return the key (e.g., "in progress")
      nil)))

(defun clickup-emacs--format-date-from-ms (ms-string)
  "Convert ClickUp millisecond timestamp string to Org date string.
Returns nil if MS-STRING is nil."
  (when (and ms-string (not (string-empty-p ms-string)))
    ;; ClickUp uses milliseconds, Emacs uses seconds.
    (let* ((seconds (/ (string-to-number ms-string) 1000))
           (time (seconds-to-time seconds)))
      (format-time-string "%Y-%m-%d %a" time))))

(defun clickup-emacs--map-clickup-status-to-org (status)
  "Map ClickUp status name to 'org-mode' TODO state string (case-insensitive)."
  (let* ((status-lower (downcase status))
         (match (seq-find (lambda (mapping)
                            (string-equal (downcase (car mapping)) status-lower))
                          clickup-emacs-status-mapping)))
    (if match
        (cdr match)
      (progn
        (message "[ClickUp Warning] No mapping found for status '%s'. Defaulting to TODO." status)
        "TODO"))))

(defun clickup-emacs--read-date-to-ms (prompt)
  "Read a date string (allowing empty input), parse with Org, and convert to ms."
  ;; Use read-string first. This allows the user to hit RET to return ""
  (let ((input (read-string prompt)))
    (if (string-empty-p input)
        nil ;; Return nil if user skipped
      
      ;; If user typed something (e.g. "+2d"), use org-read-date to parse it
      ;; We pass 't' as the 2nd arg to get a Time Object
      ;; We pass 'input' as the 6th arg (DEFAULT-INPUT) so it parses what we typed
      (let ((time (org-read-date nil t nil nil nil input)))
        (floor (* (float-time time) 1000))))))

(defun clickup-emacs--format-task-as-org-entry (task)
  "Format a ClickUp TASK as an 'org-mode' entry."
  (let* ((id (cdr (assoc 'id task)))
         (name (cdr (assoc 'name task)))
         (description (or (cdr (assoc 'description task)) ""))
         (status-obj (cdr (assoc 'status task)))
         (status-name (cdr (assoc 'status status-obj)))
         (todo-state (clickup-emacs--map-clickup-status-to-org status-name))
         (priority-obj (cdr (assoc 'priority task)))
         (priority-num (and priority-obj (cdr (assoc 'priority priority-obj))))
         (priority (cond ((null priority-num) "[#C]") 
                         ((string= priority-num "1") "[#A]")
                         ((string= priority-num "2") "[#B]")
                         (t "[#C]")))
         (link (cdr (assoc 'url task)))
         (due-date-raw (cdr (assoc 'due_date task)))
         (start-date-raw (cdr (assoc 'start_date task)))
         (due-date (clickup-emacs--format-date-from-ms due-date-raw))
         (start-date (clickup-emacs--format-date-from-ms start-date-raw))
         (custom-id (cdr (assoc 'custom_id task)))
         (custom-fields (cdr (assoc 'custom_fields task)))
         (result ""))

    (setq result (concat result (format "*** %s %s %s\n" todo-state priority name)))
    (setq result (concat result ":PROPERTIES:\n"))
    (setq result (concat result (format ":ID-CLICKUP: %s\n" id)))
    (when (and custom-id (not (string-empty-p custom-id)))
      (setq result (concat result (format ":CLICKUP-CUSTOM-ID: %s\n" custom-id))))
    (setq result (concat result (format ":LINK: %s\n" link)))


    (when (and clickup-emacs-sync-custom-fields custom-fields)
      (dolist (field (append custom-fields nil))
        (let ((field-name (cdr (assoc 'name field)))
              (field-type (cdr (assoc 'type field)))
              (field-value (cdr (assoc 'value field))))
          
          (when (and field-name 
                     field-value 
                     (member field-name clickup-emacs-sync-custom-fields))
            
            (let ((display-value 
                   (cond
                    ;; Dropdowns AND Labels
                    ((member field-type '("drop_down" "labels"))
                     (let* ((type-config (cdr (assoc 'type_config field)))
                            (options (cdr (assoc 'options type-config)))
                            (selected-ids (if (vectorp field-value) 
                                              (append field-value nil) 
                                            (list field-value))))
                       
                       (mapconcat 
                        (lambda (uuid)
                          (let ((match (seq-find (lambda (opt) 
                                                   (equal (cdr (assoc 'id opt)) uuid)) 
                                                 options)))
                            (if match 
                                ;; FIX: Check for 'label' OR 'name'
                                (or (cdr (assoc 'label match)) 
                                    (cdr (assoc 'name match)))
                              (format "%s" uuid))))
                        selected-ids 
                        ", ")))
                    
                    ;; URL fields
                    ((string= field-type "url")
                     (if (listp field-value) 
                         (cdr (assoc 'value field-value))
                       field-value))

                    ;;Default
                    (t (format "%s" field-value)))))

              (let ((clean-prop-name (concat "CLICKUP-" (upcase (replace-regexp-in-string " " "-" field-name)))))
                (setq result (concat result (format ":%s: %s\n" clean-prop-name display-value)))))))))
    
    (setq result (concat result ":END:\n"))

    (when (or due-date start-date)
      (when due-date
        (setq result (concat result (format "DEADLINE: <%s> " due-date))))
      (when start-date
        (setq result (concat result (format "SCHEDULED: <%s> " start-date))))
      (setq result (concat result "\n")))
    
    (when (and (stringp description) (not (string-empty-p description)))
      (setq result (concat result ":DESCRIPTION: |\n"))
      (dolist (line (split-string description "\n"))
        (setq result (concat result (format "  %s\n" line)))))
    
    (setq result (concat result "\n"))
    result))

(defun clickup-emacs--write-tasks-to-file (tasks file-path list-id)
  "Write TASKS to FILE-PATH, overwriting existing content."
  (condition-case err
      (progn
        (make-directory (file-name-directory file-path) t)
        (with-temp-buffer
          (insert ":PROPERTIES:\n")
          (insert (format ":CLICKUP-LIST-ID: %s\n" list-id))
          (insert (format ":LAST-SYNC: %s\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
          (insert ":END:\n")
          (insert (format "#+TITLE: ClickUp Tasks (%s)\n" list-id))
          (insert "#+TODO: BACKLOG TODO IN-PROGRESS TECH-REVIEW REVIEW BLOCKED | DONE\n\n")

          (dolist (task tasks)
            (insert (clickup-emacs--format-task-as-org-entry task)))

          (write-region (point-min) (point-max) file-path nil 'quiet)
          (message "Successfully synced %d tasks to %s" (length tasks) file-path)))
    (error
     (message "Error writing to %s: %s" file-path (error-message-string err)))))

(defun clickup-emacs-update-status-on-change ()
  "Hook to sync Org status changes to ClickUp."
  (let* ((task-id (org-entry-get (point) "ID-CLICKUP"))
         (new-state org-state)) ;; org-state is a variable provided by the hook
    
    (when (and task-id new-state)
      (let ((clickup-status (clickup-emacs--map-org-state-to-clickup new-state)))
        
        (if clickup-status
            (progn
              (message "Syncing status '%s' to ClickUp..." clickup-status)
              (clickup-emacs--request-async
               'PUT
               (format "/task/%s" task-id)
               nil
               `(("status" . ,clickup-status)) ;; Payload
               (lambda (response)
                 (message "Successfully updated ClickUp task %s to %s" task-id clickup-status))
               (lambda (err _r _d)
                 (message "Failed to sync status: %s" err))))
          
          (message "No ClickUp mapping found for Org state '%s'. Skipping sync." new-state))))))

;;; User-facing Commands

;;;###autoload
(defun clickup-emacs-sync-all ()
  "Sync all lists defined in `clickup-emacs-list-mappings`."
  (interactive)
  (if (null clickup-emacs-list-mappings)
      (error "No mappings defined. Please configure `clickup-emacs-list-mappings`")
    
    (message "Starting sync for %d lists..." (length clickup-emacs-list-mappings))
    
    (dolist (mapping clickup-emacs-list-mappings)
      (let ((list-id (plist-get mapping :id))
            (file-path (expand-file-name (plist-get mapping :file))))
        
        (if (and list-id file-path)
            (clickup-emacs-get-tasks-async
             list-id
             (lambda (tasks)
               (clickup-emacs--write-tasks-to-file tasks file-path list-id)))
          (message "Invalid mapping found: %S" mapping))))))

;;;###autoload
(defun clickup-emacs-enable-status-sync ()
  "Enable automatic status syncing from Org to ClickUp."
  (interactive)
  (add-hook 'org-after-todo-state-change-hook #'clickup-emacs-update-status-on-change)
  (message "ClickUp status sync enabled."))

;;;###autoload
(defun clickup-emacs-disable-status-sync ()
  "Disable automatic status syncing."
  (interactive)
  (remove-hook 'org-after-todo-state-change-hook #'clickup-emacs-update-status-on-change)
  (message "ClickUp status sync disabled."))

;;;###autoload
(defun clickup-emacs-capture ()
  "Create a new task in ClickUp with optional dates and auto-assignment."
  (interactive)
  
  (if (null clickup-emacs-list-mappings)
      (error "No mappings defined. Configure `clickup-emacs-list-mappings` first")
    
    (let* ((choices (mapcar (lambda (m)
                              (cons (format "%s (%s)" 
                                            (file-name-nondirectory (plist-get m :file))
                                            (plist-get m :id))
                                    (plist-get m :id)))
                            clickup-emacs-list-mappings))
           (selection (completing-read "Capture to List: " choices nil t))
           (list-id (cdr (assoc selection choices))))
      
      (when list-id
        (let* ((title (read-string "Task Title: "))
               (desc (read-string "Description (optional): "))
               
               (status-keys (mapcar #'car clickup-emacs-status-mapping))
               (status (completing-read "Status: " status-keys nil t))

               ;; Passing 't' to org-read-date allows empty input (skip)
               (start-date-ms (clickup-emacs--read-date-to-ms "Start Date (optional, RET to skip): "))
               (due-date-ms (clickup-emacs--read-date-to-ms "Due Date (optional, RET to skip): ")))
          
          (message "Creating task '%s'..." title)

          (let ((create-fn 
                 (lambda (&optional assignee-id)
                   (let ((payload `(("name" . ,title)
                                    ("description" . ,desc)
                                    ("status" . ,status))))
                     
                     ;; Inject Assignee
                     (when assignee-id
                       (push `("assignees" . [,assignee-id]) payload))

                     ;; Inject Dates
                     (when start-date-ms
                       (push `("start_date" . ,start-date-ms) payload))
                     (when due-date-ms
                       (push `("due_date" . ,due-date-ms) payload))

                     (clickup-emacs--request-async
                      'POST
                      (format "/list/%s/task" list-id)
                      nil
                      payload
                      (lambda (response)
                        (let ((url (cdr (assoc 'url response))))
                          (message "Task created! Link: %s" url)
                          (kill-new url)))
                      (lambda (err _r _d)
                        (message "Failed to create task: %s" err)))))))

            (if clickup-emacs-filter-assigned-to-me
                (clickup-emacs-get-current-user-async create-fn)
              (funcall create-fn nil))))))))

(provide 'clickup-emacs)
;;; clickup-emacs.el ends here
