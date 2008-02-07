;;; A compiler from a subset of R5RS Scheme to x86 assembly, written in itself.
;; Kragen Javier Sitaker, 2008-01-03, 04, 05, and 06

;; From the Scheme 9 From Outer Space page:
;; Why in earth write another half-baked implementation of Scheme?
;; It is better than getting drunk at a bar.

;; I had been working on this for a couple of days now when I ran across
;http://www.iro.umontreal.ca/%7Eboucherd/mslug/meetings/20041020/minutes-en.html
;; which says:
;;     How to write a simple Scheme to C compiler, in Scheme. In only
;;     90 minutes! And although not supporting the whole Scheme
;;     standard, the compiler supports fully optimized proper tail
;;     calls, continuations, and (of course) full closures.
;; I was feeling pretty inferior until I started watching the video of
;; the talk, in which Marc Feeley, the speaker, begins by explaining:
;;     So, uh, let me clarify the, uh, the title of the presentation!
;;     The 90 minutes is not the time to write the compiler, but to
;;     explain it.

;; I think this is nearly the smallest subset of R5RS Scheme that it's
;; practical to write a Scheme compiler in, and I've tried to keep
;; this implementation of it as simple as I can stand.  I kind of feel
;; that someone more adept would be having more success at keeping it
;; simple, but hey, it's my first compiler.


;;; Implementation planned:
;; - car, cdr, cons
;; - symbol?, null?, eq?, boolean?, pair?, string?, procedure?,
;;   integer?, char?
;; - eq? works for both chars and symbols
;; - if (with three arguments)
;; - lambda (with fixed numbers of arguments or with a single argument
;;   that gets bound to the argument list (lambda <var> <body>) and a
;;   single body expression)
;; - begin
;; - global variables, with set!
;; - local variables, with lexical scope and set!
;; - top-level define of a variable (not a function)
;; - read, for proper lists, symbols, strings, integers, #t and #f,
;;   and '
;; - eof-object?
;; - garbage collection
;; - strings, with string-set!, string-ref, string literals,
;;   string=?, string-length, and make-string with one argument
;; - which unfortunately requires characters
;; - very basic arithmetic: two-argument +, -, quotient, remainder,
;;   and = for integers, and decimal numeric constants
;; - recursive procedure calls
;; - display, for strings, and newline
;; - error

;; All of this would be a little simpler if strings were just lists
;; of small integers.

;;; Implemented:
;; - display, for strings, and newline
;; - string and numeric constants
;; - begin
;; - if
;; - booleans
;; - recursive procedure calls
;; - some arithmetic: +, -, and = for integers
;; - lambda, with fixed numbers of arguments, without nesting
;; - local variables
;; - global variables

;; Next to implement:
;; - renaming the functions with needlessly nonstandard names
;; - some unit tests; now that the compiler is capable of compiling a
;;   unit test suite, there should be one.
;; - dynamic allocation
;; - cons cells with cons, car, cdr, null?, and pair?; suggested magic
;;   number: ce11
;; - variadic functions (that will get us past the first two lines of
;;   compiling itself)
;; - quote! that's going to be interesting.
;; - immutable string operations: string-ref, string-length
;; - mutable string operations: make-string, string-set!

;;; Not implemented:
;; - call/cc, dynamic-wind
;; - macros, quasiquote
;; - most of arithmetic
;; - vectors
;; - most of the language syntax: dotted pairs, ` , ,@
;; - write
;; - proper tail recursion
;; - cond, case, and, or, do, not
;; - let, let*, letrec
;; - delay, force
;; - internal definitions
;; - most of the library procedures for handling lists, characters
;; - eval, apply
;; - map, for-each
;; - multiple-value returns
;; - scheme-report-environment, null-environment

;;; Design notes:

;; The strategy taken herein is to use the x86 as a stack machine
;; (within each function, anyway).  %eax contains the top of stack;
;; %esp points at a stack in memory containing the rest of the stack
;; items.  This eliminates any need to allocate registers; for
;; ordinary expressions, we just need to convert the Lisp code to RPN
;; and glue together the instruction sequences that comprise them.

;; We also use the ordinary x86 stack as a call stack.  See the
;; section ";;; Procedure calls" for details.  This would pose
;; problems for call/cc if I were going to implement it, but I'm not,
;; so I don't care.  You might think it would cause problems for
;; closures of indefinite extent, but the "Implementation of Lua 5.0"
;; paper explains a fairly straightforward way of implementing
;; closures, called "upvalues", that still lets us stack-allocate
;; almost all of the time.

;; Pointers are tagged in the low bits in more or less the usual way:
;; - low bits binary 00: an actual pointer, to an object with an
;;   embedded magic number; examine the magic number to see what it
;;   is.
;; - low bits binary 01: a signed integer, stored in the upper 30 bits.
;; - low bits binary 10: one of a small number of unique objects.  The
;;   first 256 are the chars; following these we have the empty list,
;;   #t, #f, and the EOF object, in that order.  This means that eq?
;;   works to compare chars in this implementation, but that isn't
;;   guaranteed by R5RS, so we can't depend on that property inside
;;   the compiler, since we want to be able to run it on other R5RS
;;   Schemes.
;; So, type-testing consists of testing the type-tag, then possibly
;; testing the magic number.  In the usual case, we'll jump to an
;; error routine if the type test fails, which will exit the program.
;; I'll add more graceful exits later.



;;; Basic Lisp Stuff
;; To build up the spartan language implemented by the compiler to a
;; level where you can actually program in it.  Of course these mostly
;; exist in standard Scheme, but I thought it would be easier to write
;; them in Scheme rather than assembly in order to get the compiler to
;; the point where it could bootstrap itself.

(define double (lambda (val) (+ val val)))
(define quadruple (lambda (val) (double (double val))))

(define list (lambda args args))        ; identical to standard "list"
(define length                        ; identical to standard "length"
  (lambda (list) (if (null? list) 0 (+ 1 (length (cdr list))))))
(define assq                            ; identical to standard "assq"
  (lambda (obj alist)
    (if (null? alist) #f
        (if (eq? obj (caar alist)) (car alist)
            (assq obj (cdr alist))))))
;; identical to standard caar, cdar, etc.
(define caar (lambda (val) (car (car val))))
(define cdar (lambda (val) (cdr (car val))))
(define cadr (lambda (val) (car (cdr val))))
(define caddr (lambda (val) (cadr (cdr val))))

(define filter-2
  (lambda (fn lst rest) (if (fn (car lst)) (cons (car lst) rest) rest)))
(define filter           ; this must exist in r5rs but I can't find it
  (lambda (fn lst) (if (null? lst) '()
                       (filter-2 fn lst (filter fn (cdr lst))))))

(define not (lambda (x) (if x #f #t)))  ; identical to standard "not"

;; string manipulation (part of Basic Lisp Stuff)
(define string-append-3
  (lambda (length s2 buf idx)
    (if (= idx (string-length buf)) buf
        (begin
          (string-set! buf idx (string-ref s2 (- idx length)))
          (string-append-3 length s2 buf (+ idx 1))))))
(define string-append-2
  (lambda (s1 s2 buf idx)
    (if (= idx (string-length s1)) 
        (string-append-3 (string-length s1) s2 buf idx)
        (begin
          (string-set! buf idx (string-ref s1 idx))
          (string-append-2 s1 s2 buf (+ idx 1))))))
(define string-append          ; identical to standard "string-append"
  (lambda (s1 s2)
    (string-append-2 s1 s2 (make-string (+ (string-length s1) 
                                           (string-length s2)))
                          0)))
(define char->string-2
  (lambda (buf char) (begin (string-set! buf 0 char) buf)))
(define char->string
  (lambda (char)
    (char->string-2 (make-string 1) char)))
(define string-digit
  (lambda (digit) (char->string (string-ref "0123456789" digit))))
;; Note that this strategy is O(N^2) in the number of digits.
(define number-to-string-2
  (lambda (num)
    (if (= num 0) ""
        (string-append (number-to-string-2 (quotient num 10))
                       (string-digit (remainder num 10))))))
;; XXX rename
(define number-to-string                ; number->string
  (lambda (num) (if (= num 0) "0" (number-to-string-2 num))))

;; Boy, it sure causes a lot of hassle that Scheme has different types
;; for strings and chars.

;; XXX rename
(define char-eqv?                       ; identical to standard char=?
  (lambda (a b) (string=? (char->string a) (char->string b))))
(define string-sub-2
  (lambda (buf string start idx)
    (if (= idx (string-length buf)) buf
        (begin (string-set! buf idx (string-ref string (+ start idx)))
               (string-sub-2 buf string start (+ idx 1))))))
;; XXX rename
(define string-sub                      ; identical to standard substring
  (lambda (string start end)
    (string-sub-2 (make-string (- end start)) string start 0)))
(define string-idx-2
  (lambda (string char idx)
    (if (= idx (string-length string)) #f
        (if (char-eqv? (string-ref string idx) char) idx
            (string-idx-2 string char (+ idx 1))))))
(define string-idx                      ; returns #f or index into string
  (lambda (string char) (string-idx-2 string char 0)))

;;; Basic Assembly Language Emission

;; emit: output a line of assembly by concatenating the strings in an
;; arbitrarily nested list structure
(define emit (lambda stuff (emit-inline stuff) (newline)))
(define emit-inline
  (lambda (stuff)
    (if (null? stuff) #t
        (if (pair? stuff) 
            (begin (emit-inline (car stuff))
                   (emit-inline (cdr stuff)))
            (if (string? stuff) (display stuff)
                (error (list "emitting" stuff)))))))

;; Emit an indented instruction
(define insn (lambda insn (emit (cons "        " insn))))
(define comment (lambda (comment) (insn "# " comment)))

;; Emit a two-argument instruction
(define twoarg 
  (lambda (mnemonic) (lambda (src dest) (insn mnemonic " " src ", " dest))))
;; For example:
(define mov (twoarg "mov"))   (define test (twoarg "test"))
(define cmpl (twoarg "cmpl")) (define lea (twoarg "lea"))
(define add (twoarg "add"))   (define sub (twoarg "sub"))
(define xchg (twoarg "xchg"))

;; Emit a one-argument instruction
(define onearg (lambda (mnemonic) (lambda (rand) (insn mnemonic " " rand))))
(define asm-push (onearg "push")) (define asm-pop (onearg "pop"))
(define jmp (onearg "jmp"))       (define jnz (onearg "jnz"))
(define je (onearg "je"))         (define jz je)
(define call (onearg "call"))     (define int (onearg "int"))
(define inc (onearg "inc"))       (define dec (onearg "dec"))

;; Currently only using a single zero-argument instruction:
(define ret (lambda () (insn "ret")))

;; Registers:
(define eax "%eax")  (define ebx "%ebx")  
(define ecx "%ecx")  (define edx "%edx")
(define ebp "%ebp")  (define esp "%esp")

;; x86 addressing modes:
(define const (lambda (x) (list "$" x)))
(define indirect (lambda (x) (list "(" x ")")))
(define offset 
  (lambda (x offset) (list (number-to-string offset) (indirect x))))
(define absolute (lambda (x) (list "*" x)))
;; Use this one inside of "indirect" or "offset".
(define index-register
  (lambda (base index size) (list base "," index "," (number-to-string size))))

(define syscall (lambda () (int (const "0x80"))))


;; Other stuff for basic asm emission.
(define section (lambda (name) (insn ".section " name)))
(define rodata (lambda () (section ".rodata")))
(define text (lambda () (insn ".text")))
(define label (lambda (label) (emit label ":")))

;; define a .globl label
(define global-label
  (lambda (lbl)
    (begin (insn ".globl " lbl) (label lbl))))

;; new-label: Allocate a new label (e.g. for a constant) and return it.
(define constcounter 0)
(define new-label
  (lambda ()
    (begin
      (set! constcounter (+ constcounter 1))
      (list "k_" (number-to-string constcounter)))))

;; stuff to output a Lisp string safely for assembly language
(define dangerous "\\\n\"")
(define escapes "\\n\"")
(define backslash (string-ref "\\" 0))  ; I don't have reader syntax for characters
(define backslashify-3
  (lambda (string buf idx idxo backslashed)
    (if backslashed (begin (string-set! buf idxo backslash)
                           (string-set! buf (+ idxo 1) (string-ref escapes backslashed))
                           (backslashify-2 string buf (+ idx 1) (+ idxo 2)))
        (begin (string-set! buf idxo (string-ref string idx))
               (backslashify-2 string buf (+ idx 1) (+ idxo 1))))))
(define backslashify-2
  (lambda (string buf idx idxo)
    (if (= idx (string-length string)) (string-sub buf 0 idxo)
        (backslashify-3 string buf idx idxo 
                        (string-idx dangerous (string-ref string idx))))))
(define backslashify
  (lambda (string)
    (backslashify-2 string (make-string (+ (string-length string)
                                           (string-length string))) 0 0)))
;; Represent a string appropriately for the output assembly language file.
(define asm-represent-string
  (lambda (string) (list "\"" (backslashify string) "\"")))

(define ascii (lambda (string) (insn ".ascii " (asm-represent-string string))))

;; emit a prologue for a datum to be assembled into .rodata
(define rodatum
  (lambda (labelname)
    (rodata)
    (insn ".align 4")       ; align pointers so they end in binary 00!
    (label labelname)))

(define compile-word (lambda (contents) (insn ".int " contents)))

;;; Stack Machine Primitives
;; As explained earlier, there's an "abstract stack" that includes
;; %eax as well as the x86 stack.

(define tos eax)                        ; top-of-stack register
(define nos (indirect esp))   ; "next on stack", what's underneath TOS

;; push-const: Emit code to push a constant onto the abstract stack
(define push-const (lambda (val) (asm-push tos) (mov (const val) tos)))
;; pop: Emit code to discard top of stack.
(define pop (lambda () (asm-pop tos)))

;; dup: Emit code to copy top of stack.
(define dup (lambda () (asm-push tos)))

;; swap: Emit code to exchange top of stack with what's under it.
(define swap (lambda () (xchg tos nos)))

;;; Some convenience stuff for the structure of the program.

(define stuff-to-put-in-the-header (lambda () #f))
(define concatenate-thunks (lambda (a b) (lambda () (begin (a) (b)))))
(define add-to-header 
  (lambda (proc) (set! stuff-to-put-in-the-header 
                       (concatenate-thunks stuff-to-put-in-the-header proc))))

;;; Procedure calls.
;; Procedure values are 8 bytes:
;; - 4 bytes: procedure magic number 0xca11ab1e
;; - 4 bytes: pointer to procedure machine code
;; At some point I'll have to add a context pointer.
;; 
;; The number of arguments is passed in %edx; on the machine stack is
;; the return address, with the arguments underneath it; the address
;; of the procedure value that was being called is in %eax.  (XXX
;; Currently the arguments are in the wrong order.)  Callee saves %ebp
;; and pops their own arguments off the stack.  The prologue points
;; %ebp at the arguments.  Return value goes in %eax.
(define procedure-magic "0xca11ab1e")
(add-to-header (lambda ()
    (begin
      (label "ensure_procedure")
      (comment "make sure procedure value is not unboxed")
      (test (const "3") tos)
      (jnz "not_procedure")
      (comment "now test its magic number")
      (cmpl (const procedure-magic) (indirect tos))
      (jnz "not_procedure")
      (ret))))
(define ensure-procedure (lambda () (call "ensure_procedure")))
(define compile-apply
  (lambda (nargs)
    (begin
      (ensure-procedure)
      (mov (offset tos 4) ebx)          ; address of actual procedure
      (mov (const (number-to-string nargs)) edx)
      (call (absolute ebx)))))
(define compile-procedure-prologue
  (lambda (nargs)
    (begin
      (cmpl (const (number-to-string nargs)) edx)
      (jnz "argument_count_wrong")
      (comment "compute desired %esp on return in %ebx and push it")
      (lea (offset (index-register esp edx 4) 4) ebx)
      (asm-push ebx)                    ; push restored %esp on stack
      ;; At this point, if we were a closure, we would be doing
      ;; something clever with the procedure value pointer in %eax.
      (mov ebp tos)                     ; save old %ebp --- in %eax!
      (lea (offset esp 8) ebp))))       ; 8 bytes to skip saved %ebx and %eip
(define compile-procedure-epilogue
  (lambda ()
    (begin
      (asm-pop ebp) ; return val in %eax has pushed saved %ebp onto stack
      (asm-pop ebx)                     ; value to restore %esp to
      (asm-pop edx)                     ; saved return address
      (mov ebx esp)
      (jmp (absolute edx)))))           ; return via indirect jump

(define not-procedure-routine-2
  (lambda (errlabel)
    (begin
      (label "not_procedure")
      (comment "error handling when you call something not callable")
      (mov (const errlabel) tos)
      (jmp "report_error"))))
(add-to-header (lambda ()
    (not-procedure-routine-2 (constant-string "type error: not a procedure\n"))))
(add-to-header (lambda ()
    ((lambda (errlabel)
       (begin
         (label "argument_count_wrong")
         (mov (const errlabel) tos)
         (jmp "report_error")))
     (constant-string "error: wrong number of arguments\n"))))

(define built-in-procedure-2
  (lambda (labelname nargs body bodylabel)
    (begin
      (rodatum labelname)
      (compile-word procedure-magic)
      (compile-word bodylabel)
      (text)
      (label bodylabel)
      (compile-procedure-prologue nargs)
      (body)
      (compile-procedure-epilogue)))) ; maybe we should just centralize
                                      ; that and jump to it? :)
;; Define a built-in procedure so we can refer to it by label and
;; push-const that label, then expect to be able to compile-apply to
;; it later.
(define built-in-procedure-labeled
  (lambda (labelname nargs body)
    (built-in-procedure-2 labelname nargs body (new-label))))
(define global-procedure-2
  (lambda (symbolname nargs body procedure-value-label)
    (begin
      (define-global-variable symbolname procedure-value-label)
      (built-in-procedure-labeled procedure-value-label nargs body))))
;; Define a built-in procedure known by a certain global variable name.
(define global-procedure
  (lambda (symbolname nargs body)
    (global-procedure-2 symbolname nargs body (new-label))))

;; Emit code to fetch the Nth argument of the innermost procedure.
(define get-procedure-arg
  (lambda (n)
    (asm-push tos)
    (mov (offset ebp (quadruple n)) tos)))

;;; Strings (on the target)
;; A string consists of the following, contiguous in memory:
;; - 4 bytes of a string magic number 0xbabb1e
;; - 4 bytes of string length "N";
;; - N bytes of string data.
(define string-magic "0xbabb1e")

(define constant-string-2
  (lambda (contents labelname)
    (rodatum labelname)
    (compile-word string-magic)
    (compile-word (number-to-string (string-length contents)))
    (ascii contents)
    (text)
    labelname))
;; constant-string: Emit code to represent a constant string.
(define constant-string
  (lambda (contents)
    (constant-string-2 contents (new-label))))

(define string-error-routine-2
  (lambda (errlabel)
    (label "notstring")
    (mov (const errlabel) tos)
    (jmp "report_error")))
(add-to-header (lambda ()
    (string-error-routine-2 (constant-string "type error: not a string\n"))))

(add-to-header (lambda ()
    (label "ensure_string")
    (comment "ensures that %eax is a string")
    (comment "first, ensure that it's a pointer, not something unboxed")
    (test (const "3") tos)              ; test low two bits
    (jnz "notstring")
    (comment "now, test its magic number")
    (cmpl (const string-magic) (indirect tos))
    (jnz "notstring")
    (ret)))
;; Emit code to ensure that %eax is a string
(define ensure-string (lambda () (call "ensure_string")))
;; Emit code to pull the string pointer and count out of a string
;; being pointed to and push them on the abstract stack
(define extract-string
  (lambda ()
    (ensure-string)
    (lea (offset tos 8) ebx)            ; string pointer
    (asm-push ebx)
    (mov (offset tos 4) tos)))          ; string length

;; Emit code which, given a byte count on top of stack and a string
;; pointer underneath it, outputs the string.
(define write_2
  (lambda ()
    (begin
      (mov tos edx)                     ; byte count in arg 3
      (asm-pop ecx)                     ; byte string in arg 2
      (mov (const "4") eax)             ; __NR_write
      (mov (const "1") ebx)             ; fd 1: stdout
      (syscall))))                      ; return value is in %eax

;; Emit code to output a string.
;; XXX this needs to have a reasonable return value, and it doesn't!
(define target-display (lambda () (extract-string) (write_2)))
;; Emit code to output a newline.
(define target-newline
  (lambda ()
    (begin
      (push-const "newline_string")
      (target-display))))
(add-to-header (lambda () (rodatum "newline_string") (constant-string "\n")))

;; Emit code to create a mutable labeled cell, for use as a global
;; variable, with a specific assembly label.
(define compile-global-variable
  (lambda (varlabel initial)
    (begin
      (section ".data")
      (label varlabel)
      (compile-word initial)
      (text))))

;; Emit code to fetch from a named global variable.
(define fetch-global-variable
  (lambda (varname)
      (asm-push tos) (mov (indirect varname) tos)))

;; Emit code for procedure versions of display and newline
(add-to-header (lambda ()
    (begin
      (global-procedure 'display 1 
                        (lambda () (begin
                                      (get-procedure-arg 0)
                                      (target-display))))
      (global-procedure 'newline 0 target-newline)
      (global-procedure 'eq? 2 
                        (lambda () (begin
                                      (get-procedure-arg 0)
                                      (get-procedure-arg 1)
                                      (target-eq?)))))))
(define apply-built-in-by-label
  (lambda (label)
    (lambda ()
      (push-const label))))

;; Emit the code for the normal error-reporting routine
(add-to-header (lambda ()
    (label "report_error")
    (target-display)                    ; print out whatever is in %eax
    (mov (const "1") ebx)               ; exit code of program
    (mov (const "1") eax)               ; __NR_exit
    (syscall)))                         ; make system call to exit

(define compile-literal-string-2 (lambda (label) (push-const label)))
(define compile-literal-string
  (lambda (contents env)
    (compile-literal-string-2 (constant-string contents))))


;;; Integers
(define tagshift quadruple)
(define integer-tag 1)
(define tagged-integer
  (lambda (int) (+ integer-tag (tagshift int))))
(add-to-header (lambda ()
    (label "ensure_integer")
    (test (const "1") tos)
    (jz "not_an_integer")
    (test (const "2") tos)
    (jnz "not_an_integer")
    (ret)
    (label "not_an_integer")
    (mov (const "not_int_msg") tos)
    (jmp "report_error")
    (rodatum "not_int_msg")
    (constant-string "type error: not an integer")
    (text)))
(define ensure-integer (lambda () (call "ensure_integer")))
(define assert-equal (lambda (a b) (if (= a b) #t (error "assert failed"))))
(define integer-add
  (lambda (rands env)
    (comment "integer add operands")
    (assert-equal 2 (compile-args rands env))
    (comment "now execute integer add")
    (ensure-integer)
    (swap)
    (ensure-integer)
    (asm-pop ebx)
    (add ebx tos)
    (dec tos)))                         ; fix up tag
(define integer-sub
  (lambda (rands env)
    (comment "integer subtract operands")
    (assert-equal 2 (compile-args rands env))
    (comment "now execute integer subtract")
    (ensure-integer)
    (swap)
    (ensure-integer)
    (sub nos tos)
    (asm-pop ebx)                       ; discard second argument
    (inc tos)))                         ; fix up tag

;;; Booleans and other misc. types
(define enum-tag 2)
(define enum-value 
  (lambda (offset) (number-to-string (+ enum-tag (tagshift offset)))))
(define nil-value (enum-value 256))
(define true-value (enum-value 257))
(define false-value (enum-value 258))
(define eof-value (enum-value 259))
(define jump-if-false
  (lambda (label)
    (cmpl (const false-value) tos)
    (pop)
    (je label)))

;; Emit code to push a boolean in place of the top two stack items.
;; It will be #t if they are equal, #f if they are not.
(define target-eq?
  (lambda ()
    ((lambda (label1 label2)
      (asm-pop ebx)
      (cmpl ebx tos)
      (je label1)
      (mov (const false-value) tos)
      (jmp label2)
      (label label1)
      (mov (const true-value) tos)
      (label label2)) (new-label) (new-label))))


;;; Global variable handling.

(define global-variable-labels '())
(define global-variables-defined '())

(define add-new-global-variable-binding!
  (lambda (name label)
    (begin (set! global-variable-labels 
                 (cons (cons name label) global-variable-labels))
           label)))
(define allocate-new-global-variable-label!
  (lambda (name) (add-new-global-variable-binding! name (new-label))))
(define global-variable-label-2
  (lambda (name binding)
    (if binding (cdr binding) (allocate-new-global-variable-label! name))))
;; Return a label representing this global variable, allocating a new
;; one if necessary.
(define global-variable-label
  (lambda (name) 
    (global-variable-label-2 name (assq name global-variable-labels))))

(define define-global-variable
  (lambda (name initial)
    (if (assq name global-variables-defined) (error "double define" name)
        (begin (compile-global-variable (global-variable-label name) initial)
               (set! global-variables-defined 
                     (cons (list name) global-variables-defined))))))

(define undefined-global-variables
  (lambda ()
    (filter (lambda (pair) (not (assq (car pair) global-variables-defined)))
            global-variable-labels)))

;; This runs at the end of compilation to report any undefined
;; globals.  The assumption is that you're recompiling frequently
;; enough that there will normally only be one...
(define assert-no-undefined-global-variables
  (lambda ()
    (if (not (null? (undefined-global-variables)))
        (error "undefined global" (caar (undefined-global-variables)))
        #t)))

;;; Compilation of particular kinds of expressions
(define compile-var-2
  (lambda (lookupval var)
    (if lookupval ((cdr lookupval)) 
        (fetch-global-variable (global-variable-label var)))))
(define compile-var
  (lambda (var env)
    (compile-var-2 (assq var env) var)))
(define compile-literal-boolean
  (lambda (b env) (push-const (if b true-value false-value))))
(define compile-literal-integer
  (lambda (int env) (push-const (number-to-string (tagged-integer int)))))
;; compile an expression, discarding result, e.g. for toplevel
;; expressions
(define compile-discarding
  (lambda (expr env)
    (begin (compile-expr expr env)
           (pop))))
;; Construct an environment binding the local variables of the lambda
;; to bits of code to fetch them.  Handles nesting very incorrectly.
(define lambda-environment
  (lambda (env vars idx)
    (if (null? vars) env
        (cons (cons (car vars) (lambda () (get-procedure-arg idx)))
              (lambda-environment env (cdr vars) (+ idx 1))))))
(define compile-lambda-2
  (lambda (vars body env proclabel jumplabel)
    (begin (comment "jump past the body of the lambda")
           (jmp jumplabel)
           (built-in-procedure-labeled proclabel (length vars) 
             (lambda () (compile-expr body (lambda-environment env vars 0))))
           (label jumplabel)
           (push-const proclabel))))
(define compile-lambda
  (lambda (rands env) (begin (assert-equal (length rands) 2)
                             (compile-lambda-2 (car rands) (cadr rands) env 
                                               (new-label) (new-label)))))
(define compile-begin
  (lambda (rands env)
    (if (null? rands) (push-const "31") ; XXX do something reasonable
        (if (null? (cdr rands)) (compile-expr (car rands) env)
            (begin (compile-discarding (car rands) env)
                   (compile-begin (cdr rands) env))))))
(define compile-if-2
  (lambda (cond then else lab1 lab2 env)
    (begin
      (compile-expr cond env)
      (jump-if-false lab1)
      (compile-expr then env)
      (jmp lab2)
      (label lab1)
      (compile-expr else env)
      (label lab2))))
(define compile-if
  (lambda (rands env)
    (if (= (length rands) 3)
        (compile-if-2 (car rands) (cadr rands) (caddr rands)
                      (new-label) (new-label) env)
        (error "if arguments length != 3"))))
(define compile-application
  (lambda (rator env nargs)
    (begin
      (comment "get the procedure")
      (compile-expr rator env)
      (comment "now apply the procedure")
      (compile-apply nargs))))
(define special-syntax-list
  (list (cons 'begin compile-begin)
        (cons 'if compile-if)
        (cons 'lambda compile-lambda)
        (cons '+ integer-add)
        (cons '- integer-sub)))
(define compile-ration-2
  (lambda (rator rands env handler)
    (if handler ((cdr handler) rands env)
        (compile-application rator env (compile-args rands env)))))
(define compile-ration
  (lambda (rator rands env)
    (compile-ration-2 rator rands env (assq rator special-syntax-list))))
(define compile-pair
  (lambda (expr env) (compile-ration (car expr) (cdr expr) env)))
(define compilation-expr-list
  (list (cons pair? compile-pair)
        (cons symbol? compile-var)
        (cons string? compile-literal-string)
        (cons boolean? compile-literal-boolean)
        (cons integer? compile-literal-integer)))
(define compile-expr-2
  (lambda (expr env handlers)
    (if (null? handlers) (error expr)
        (if ((caar handlers) expr) ((cdar handlers) expr env)
            (compile-expr-2 expr env (cdr handlers))))))
(define compile-expr
  (lambda (expr env) (compile-expr-2 expr env compilation-expr-list)))
(define compile-args
  (lambda (args env)
    (if (null? args) 0
        (begin
          (compile-expr (car args) env)
          (+ 1 (compile-args (cdr args) env))))))

(define compile-toplevel-define
  (lambda (name body env)
    (define-global-variable name nil-value)
    (comment "compute initial value for global variable")
    (compile-expr body env)
    (comment "initialize global variable with value")
    (mov tos (indirect (global-variable-label name)))
    (pop)))

(define global-env '())

(define compile-toplevel
  (lambda (expr)
    (if (eq? (car expr) 'define) 
        (compile-toplevel-define (cadr expr) (caddr expr) global-env)
        (compile-discarding expr global-env))))

;;; Main Program

(define compile-program
  (lambda (body)
    (begin
      (stuff-to-put-in-the-header)

      (global-label "_start")         ; allow compiling with -nostdlib
      (insn ".weak _start")     ; but also allow compiling with stdlib
      (global-label "main")     ; with entry point of main, not _start

      (compile-toplevel-define '= 'eq? global-env)
      (body)

      (mov (const "1") eax)             ; __NR_exit
      (mov (const "0") ebx)             ; exit code
      (syscall)
      (assert-no-undefined-global-variables))))

(define read-compile-loop
  (lambda ()
    ((lambda (expr)
       (if (eof-object? expr) #t
           (begin (compile-toplevel expr)
                  (read-compile-loop))))
     (read))))

(compile-program read-compile-loop)
