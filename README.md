# clickup-emacs

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

This package provides integration between Emacs and ClickUp, allowing you to view, and make basic edits to your tasks directly in Org-mode without leaving your editor.

## Features

- **One-Way Sync:** Pull tasks from ClickUp Lists into local Org files.
- **Two-Way Status Sync:** Changing a TODO state in Emacs automatically updates the status in ClickUp.
- **Multiple List Support:** Map different ClickUp lists to different Org files (e.g., `work.org` vs `personal.org`).
- **Status Mapping:** Map ClickUp statuses (e.g., "TECH REVIEW", "BLOCKED") to specific Org-mode keywords.
- **Deadline Mapping:** ClickUp due dates are automatically mapped to Org `DEADLINE` timestamps for Agenda visibility.
- **Assignee Filtering:** Optionally fetch only tasks assigned to you.
- **Status Filtering:** Fetch only relevant tasks (e.g., ignore "Done" or "Closed" tasks to save bandwidth).
- **Rich Org Metadata:** Tasks include links back to ClickUp, descriptions, and priorities.

## Installation

### Prerequisites

This package requires the following dependencies:
- `request`
- `dash`
- `s`

### Manual Installation

1. Clone this repository:
```shell
   git clone [https://github.com/sganon/clickup-emacs.git](https://github.com/sganon/clickup-emacs.git) /path/to/clickup-emacs
```

2.2.  Add to your Emacs config:

``` emacs-lisp
(add-to-list 'load-path "/path/to/clickup-emacs")
(require 'clickup-emacs)
```

### Doom Emacs Installation

1. In `packages.el`:

``` emacs-lisp
(package! clickup-emacs :recipe (:host github :repo "sganon/clickup-emacs"))
```

2. In `config.el`, configure the package (see below).

3. Run `doom sync`

## Configuration

### Basic Setup

You need to provide your API key and map your lists.

To find your List ID:

1. Open ClickUp.
2. Right-click a List in the sidebar.
3. Select Copy Link.
4. The ID is the number at the end of the URL (e.g., .../li/901204368).

``` emacs-lisp
(use-package! clickup-emacs
  :commands (clickup-emacs-sync-all)
  :config
  ;; 1. Set your API Key
  (setq clickup-emacs-api-key "pk_YOUR_API_KEY") 

  ;; 2. Map Lists to Files
  (setq clickup-emacs-list-mappings
        '((:id "<PRODUCT_LIST_ID>" :file "~/org/clickup/product.org")
          (:id "<PERSONAL_LIST_ID>" :file "~/org/clickup/personal.org")))

  ;; 3. (Optional) Filter only tasks assigned to you
  (setq clickup-emacs-filter-assigned-to-me t)

  ;; 4. (Optional) Filter specific statuses 
  (setq clickup-emacs-filter-statuses 
        '("TO DO" "IN PROGRESS" "BLOCKED" "TECH REVIEW" "REVIEW"))

  ;; 5. Map ClickUp statuses to Org keywords
  (setq clickup-emacs-status-mapping
        '(("backlog" . "BACKLOG")
          ("to do" . "TODO")
          ("in progress" . "IN-PROGRESS")
          ("blocked" . "BLOCKED")
          ("tech review" . "TECH-REVIEW")
          ("review" . "REVIEW")))
      
  ;; 6. Enable Two-Way Status Sync
  ;; This hook triggers whenever you change a TODO state in Org
  (add-hook 'org-after-todo-state-change-hook #'clickup-emacs-update-status-on-change)
)
```

### Org Agenda Integration
To see these tasks in your daily agenda, you must tell Org-mode where the generated files are and recognize the specific TODO keywords.

``` emacs-lisp
(after! org
  ;; Add the directory where clickup-emacs saves files
  (add-to-list 'org-agenda-files "~/org/clickup/")
  
  ;; Register your custom keywords
  (setq org-todo-keywords
        '((sequence 
           "BACKLOG(b)" 
           "TODO(t)" 
           "IN-PROGRESS(p)" 
           "TECH-REVIEW(r)" 
           "REVIEW(R)" 
           "BLOCKED(B)" 
           "|" 
           "DONE(d)")))

  ;; Optional: Add colors for better visibility
  (setq org-todo-keyword-faces
        '(("TECH-REVIEW" . "orange")
          ("BLOCKED" . +org-todo-cancel)
          ("IN-PROGRESS" . +org-todo-active))))
```

## Usage

### Syncing Tasks

Run the sync command to fetch tasks from ClickUp and overwrite the target Org files:

`M-x clickup-emacs-sync-all`

This will:

1. Fetch tasks for every list defined in clickup-emacs-list-mappings.
2. Filter them by assignee and status.
3. Convert them to Org format.
4. Write them to the specified files.

## Two-Way Status Sync

This package includes a hook to push status changes back to ClickUp.

1. Enable the hook in your config (see above).
2. Open your synced Org file.
3. Change a task state (e.g., from `TODO` to `IN-PROGRESS` using `SPC m t` or `S-RIGHT`).
4. Emacs will automatically send a `PUT` request to ClickUp updating the status.

**Note:** The sync only happens if the new Org state maps to a valid ClickUp status in your `clickup-emacs-status-mapping`.

### Viewing in Agenda

Once synced, simply open your Org Agenda:

- Doom Emacs: `SPC n t (Todo list)` or `SPC n a (Agenda view)`.
- Vanilla: `M-x org-agenda`.

## Licence

GPLv3 
 
