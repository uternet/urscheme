;;; Test to demonstrate that eqv? compares chars and ints correctly
;; By making pretty dotplots.  See Jonathan Helfman's 1995 paper,
;; "Dotplot Patterns: A Literal Look at Pattern Languages", for some
;; more fun dotplot applications.

;;; Incidentally, eq? works fine in RScheme, Guile, MzScheme, Elk,
;;; Bigloo, and SCM (as well as Ur-Scheme), but not in tinyscheme.

(define (sqrow xs ys)
  (if (null? xs) (newline)
      (begin
        (display (if (eqv? (car xs) (car ys)) "##" "  "))
        (sqrow (cdr xs) ys))))
(define (square-bottom xs ys)
  (if (null? ys) (newline)
      (begin (sqrow xs ys)
             (square-bottom xs (cdr ys)))))
(define (squarelist lst) (square-bottom lst lst))
(define (sql lst) (write lst) (newline) (squarelist lst))
(define (square string) 
  (for-each (lambda (x) (display " ") (display x))
            (map char->string (string->list string)))
  (newline) 
  (squarelist (string->list string)))

(define (ruler n)
  (if (= n 0) '(0)
      (let ((smaller (ruler (- n 1)))) (append smaller (cons n smaller)))))

(sql '(0 1 0 2 0 3 0 5 0 1 0 2 0 0 0 4 2 1 3 5))
(sql (ruler 4))
(square "i yam what i yam, and that's all that i yam")
(square "able was i ere i saw elba")
(square "First Ladies rule the State and state the rule: ladies first")
(square "Was it a rat I saw?  Satan, oscillate my metallic sonatas!")
(square 
 "How much wood would a woodchuck chuck if a woodchuck could chuck wood?")
(square "sator arepo tenet opera rotas")

