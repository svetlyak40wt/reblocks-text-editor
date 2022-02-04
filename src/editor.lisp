(uiop:define-package #:reblocks-text-editor/editor
  (:use #:cl)
  (:import-from #:common-doc)
  (:import-from #:common-html)
  (:import-from #:reblocks-parenscript)
  (:import-from #:reblocks-lass)
  (:import-from #:reblocks-text-editor/html)
  (:import-from #:reblocks-text-editor/frontend/js)
  (:import-from #:reblocks-text-editor/frontend/css)
  (:import-from #:reblocks-text-editor/document/editable)
  (:import-from #:reblocks-text-editor/document/ops
                #:map-document)
  (:import-from #:reblocks-text-editor/utils/markdown)
  (:import-from #:parenscript
                #:create
                #:chain
                #:@)
  (:import-from #:bordeaux-threads
                #:make-lock)
  (:import-from #:alexandria
                #:curry))
(in-package #:reblocks-text-editor/editor)


(defun make-initial-document ()
  (let* ((content (reblocks-text-editor/utils/markdown::from-markdown "
Hello **Lisp** World!

Second Line.

"))
         (doc (make-instance 'reblocks-text-editor/document/editable::editable-document
                             :children (list content))))
    
    (reblocks-text-editor/document/ops::add-reference-ids doc)))


(reblocks/widget:defwidget editor ()
  ((document :type reblocks-text-editor/document/editable::editable-document
             :initform (make-initial-document)
             :reader document)))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; 
;; This is our BACKEND code doing most business logic ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar *document* nil)
(defvar *widget* nil)


(defun process-usual-update (document path new-html cursor-position)
  (let* ((paragraph (reblocks-text-editor/document/ops::find-changed-node document path))
         (plain-text (reblocks-text-editor/utils/text::remove-html-tags new-html)))
    (cond
      (paragraph
       (log:error "Updating paragraph at" path)
       (multiple-value-bind (current-node cursor-position)
           (reblocks-text-editor/document/ops::update-paragraph-content
            document paragraph plain-text cursor-position)

         (reblocks-text-editor/document/ops::ensure-cursor-position-is-correct
          current-node cursor-position)))
      (t
       (log:warn "Cant find paragraph at" path)))))


(defmethod reblocks/widget:render ((widget editor))
  (let ((document (document widget)))
    (setf *document*
          document)
    (setf *widget*
          widget)


    (labels ((process-update (&key change-type version new-html path cursor-position &allow-other-keys)
               (bordeaux-threads:with-lock-held ((reblocks-text-editor/document/editable::document-lock document))
                 (when (> version (reblocks-text-editor/document/editable::content-version document))
                   (log:error "Processing" new-html path cursor-position version change-type)
                  
                   (setf (reblocks-text-editor/document/editable::content-version document)
                         version)

                   (cond
                     ;; This operation is similar to "split-paragraph"
                     ;; but it splits a paragraph and created a new list
                     ;; item when the cursor is in the list item.
                     ((string= change-type
                               "split")
                      (reblocks-text-editor/document/ops::split-paragraph
                       document path new-html cursor-position
                       :dont-escape-from-list-item t)

                     
                      (let* ((changed-paragraph
                               (reblocks-text-editor/document/ops::find-changed-node document path))
                             (list-item
                               (reblocks-text-editor/document/ops::select-outer-list-item
                                document changed-paragraph)))

                        (when list-item
                          (let ((next-paragraphs
                                  (reblocks-text-editor/document/ops::select-siblings-next-to
                                   list-item changed-paragraph)))
                            (mapcar (curry #'reblocks-text-editor/document/ops::delete-node document)
                                    next-paragraphs)
                           
                            (let ((new-list-item
                                    (common-doc:make-list-item next-paragraphs
                                                               :reference (reblocks-text-editor/document/editable::get-next-reference-id
                                                                           document))))
                              (reblocks-text-editor/document/ops::insert-node
                               document new-list-item :relative-to list-item)
                              ;; When a new list item is inserted
                              ;; the cursor should be placed on the
                              ;; first paragraph.
                              (when next-paragraphs
                                (reblocks-text-editor/document/ops::ensure-cursor-position-is-correct
                                 (first next-paragraphs)
                                 0)))))))
                     ((string= change-type
                               "split-paragraph")
                      (reblocks-text-editor/document/ops::split-paragraph
                       document path new-html cursor-position))
                     ((string= change-type
                               "join-with-prev-paragraph")
                      (reblocks-text-editor/document/ops::join-with-prev-paragraph
                       document path new-html cursor-position))
                     ((string= change-type
                               "indent")
                      (reblocks-text-editor/document/ops::indent document path cursor-position))
                     ((string= change-type
                               "dedent")
                      (reblocks-text-editor/document/ops::dedent document path cursor-position))
                     (t
                      (process-usual-update document path new-html cursor-position))))))
            
             (reset-text (&rest args)
               (declare (ignore args))
               (bordeaux-threads:with-lock-held ((reblocks-text-editor/document/editable::document-lock document))
                 (setf (slot-value widget 'document)
                       (make-initial-document)
                       (reblocks-text-editor/document/editable::content-version document)
                       0)
                 (reblocks/widget:update widget))))
     
      (let ((action-code (reblocks/actions:make-action #'process-update)))
        (reblocks/html:with-html
          (:h1 "Experimental HTML editor")
          (:h2 "Using Common Lisp + Reblocks")
          (:div :class "content"
                :data-action-code action-code
                :data-version (reblocks-text-editor/document/editable::content-version document)
                :contenteditable ""
                :onload "setup()"
                (reblocks-text-editor/html::to-html document))

          (:p :id "debug"
              "Path will be shown here.")

          (:p (:button :onclick (reblocks/actions:make-js-action #'reset-text)
                       "Reset Text")))))))


(defmethod reblocks/dependencies:get-dependencies ((widget editor))
  (list* (reblocks-text-editor/frontend/js::make-js-code)
         (reblocks-text-editor/frontend/css::make-css-code)
         (call-next-method)))
