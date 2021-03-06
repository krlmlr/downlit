#' Highlight and link a code block
#'
#' @description
#' This function:
#' * syntax highlights code
#' * links function calls to their documentation (where possible)
#' * in comments, translates ANSI escapes in to HTML equivalents.
#'
#' @export
#' @param text String of code to highlight and link.
#' @param classes A mapping between token names and CSS class names.
#'   Bundled `classes_pandoc()` and `classes_chroma()` provide mappings
#'   that (roughly) match Pandoc and chroma (used by hugo) classes so you
#'   can use existing themes.
#' @param pre_class Class(es) to give output `<pre>`.
#' @return If `text` is valid R code, an HTML `<pre>` tag. Otherwise,
#'   `NA`.
#' @return A string containing syntax highlighted HTML or `NA` (if `text`
#'   isn't parseable).
#' @examples
#' cat(highlight("1 + 1"))
#' cat(highlight("base::t(1:3)"))
#'
#' # Unparseable R code returns NA
#' cat(highlight("base::t("))
highlight <- function(text, classes = classes_chroma(), pre_class = NULL) {
  text <- gsub("\t", "  ", text, fixed = TRUE)
  text <- gsub("\r", "", text, fixed = TRUE)
  parsed <- parse_data(text)
  if (is.null(parsed)) {
    return(NA_character_)
  }

  # Figure out which packages are attached to the search path. This is a
  # hack because loading a package will affect code _before_ the library()
  # call. But it should lead to relatively few false positives and is simple.
  packages <- extract_package_attach(parsed$expr)
  register_attached_packages(packages)

  # Highlight, link, and escape
  out <- parsed$data
  out$class <- token_class(out$token, out$text, classes)
  out$href <- token_href(out$token, out$text)
  out$escaped <- token_escape(out$token, out$text)

  # Update input - basic idea from prettycode
  changed <- !is.na(out$href) | !is.na(out$class) | out$text != out$escaped
  changes <- out[changed, , drop = FALSE]

  loc <- line_col(text)
  start <- vctrs::vec_match(data.frame(line = changes$line1, col = changes$col1), loc)
  end <- vctrs::vec_match(data.frame(line = changes$line2, col = changes$col2), loc)

  new <- style_token(changes$escaped, changes$href, changes$class)
  out <- replace_in_place(text, start, end, replacement = new)

  if (is.null(pre_class)) {
    return(out)
  }

  paste0(
    "<pre class='", paste0(pre_class, collapse = " "), "'>\n",
    out, "\n",
    "</pre>"
  )
}

style_token <- function(x, href = NA, class = NA) {
  x <- ifelse(is.na(href), x, paste0("<a href='", href, "'>", x, "</a>"))
  x <- ifelse(is.na(class), x, paste0("<span class='", class, "'>", x, "</span>"))
  x
}

# From prettycode:::replace_in_place
replace_in_place <- function(str, start, end, replacement) {
  stopifnot(
    length(str) == 1, length(start) == length(end),
    length(end) == length(replacement)
  )

  keep <- substring(str, c(1, end + 1), c(start - 1, nchar(str)))
  pieces <- character(length(replacement) * 2 + 1)
  even <- seq_along(replacement) * 2
  odd <- c(1, even + 1)
  pieces[even] <- replacement
  pieces[odd] <- keep
  paste0(pieces, collapse = "")
}

line_col <- function(x) {
  char <- strsplit(x, "")[[1]]

  nl <- char == "\n"
  line <- cumsum(c(TRUE, nl[-length(char)]))
  col <- sequence(rle(line)$lengths)

  data.frame(line, col)
}

parse_data <- function(text) {
  stopifnot(is.character(text), length(text) == 1)

  expr <- safe_parse(text)
  if (is.null(expr)) {
    return(NULL)
  }

  list(expr = expr, data = utils::getParseData(expr))
}

# Highlighting ------------------------------------------------------------

token_class <- function(token, text, classes) {
  token <- token_type(token, text)
  unname(classes[token])
}

# Collapse token types to a smaller set of categories that we care about
# for syntax highlighting
# https://github.com/wch/r-source/blob/trunk/src/main/gram.c#L511
token_type <- function(x, text) {
  special <- c("IF", "ELSE", "REPEAT", "WHILE", "FOR", "IN", "NEXT", "BREAK")
  infix <- c(
    "'-'", "'+'", "'!'", "'~'", "'?'", "':'", "'*'", "'/'", "'^'", "'~'",
    "SPECIAL", "LT", "GT", "EQ", "GE", "LE", "AND", "AND2", "OR",
    "OR2", "LEFT_ASSIGN", "RIGHT_ASSIGN", "'$'", "'@'", "EQ_ASSIGN"
  )

  x[x %in% special] <- "special"
  x[x %in% infix] <- "infix"

  x[x == "NUM_CONST" & text %in% c("TRUE", "FALSE")] <- "logical"

  x
}

# Pandoc styles are based on KDE default styles:
# https://docs.kde.org/stable5/en/applications/katepart/highlight.html#kate-highlight-default-styles
# But are given a two letter abbreviations (presumably to reduce generated html size)
#
# Default syntax highlighting def for R:
# https://github.com/KDE/syntax-highlighting/blob/master/data/syntax/r.xml
#' @export
#' @rdname highlight
classes_pandoc <- function() {
  c(
    "logical" = "fl",
    "NUM_CONST" = "fl",
    "STR_CONST" = "st",
    "NULL_CONST" = "kw",
    "FUNCTION" = "fu",
    "special" = "co",
    "infix" = "op",
    "SYMBOL" = "kw",
    "SYMBOL_FUNCTION_CALL" = "fu",
    "SYMBOL_PACKAGE" = "kw",
    "SYMBOL_FORMALS" = "kw",
    "COMMENT" = "co"
  )
}

# Derived from https://github.com/ropensci/roweb2/blob/master/themes/ropensci/static/css/pygments.css
#' @export
#' @rdname highlight
classes_chroma <- function() {
  c(
    "logical" = "kc",
    "NUM_CONST" = "m",
    "STR_CONST" = "s",
    "NULL_CONST" = "l",
    "FUNCTION" = "nf",
    "special" = "kr",
    "infix" = "o",
    "SYMBOL" = "k",
    "SYMBOL_FUNCTION_CALL" = "nf",
    "SYMBOL_PACKAGE" = "k",
    "SYMBOL_FORMALS" = "k",
    "COMMENT" = "c"
  )
}

# Linking -----------------------------------------------------------------

token_href <- function(token, text) {
  href <- rep(NA, length(token))

  # Highlight namespaced function calls. In the parsed tree, these are
  # SYMBOL_PACKAGE then NS_GET/NS_GET_INT then SYMBOL_FUNCTION_CALL/SYMBOL
  ns_pkg <- which(token %in% "SYMBOL_PACKAGE")
  ns_fun <- ns_pkg + 2L

  href[ns_fun] <- map2_chr(text[ns_fun], text[ns_pkg], href_topic)

  # Then highlight all remaining calls, using loaded packages registered
  # above. These maintained at a higher-level, because (e.g) in .Rmds you want
  # earlier library() statements to affect the highlighting of later blocks
  fun <- which(token %in% "SYMBOL_FUNCTION_CALL")
  fun <- setdiff(fun, ns_fun)
  href[fun] <- map_chr(text[fun], href_topic_local)

  # Highlight packages
  lib_call <- which(
    token == "SYMBOL_FUNCTION_CALL" & text %in% c("library", "require")
  )
  pkg <- lib_call + 3 # expr + '(' + STR_CONST
  href[pkg] <- map_chr(gsub("['\"]", "", text[pkg]), href_package)

  href
}

map_chr <- function(.x, .f, ...) {
  vapply(.x, .f, ..., FUN.VALUE = character(1), USE.NAMES = FALSE)
}
map2_chr <- function(.x, .y, .f, ...) {
  vapply(seq_along(.x), function(i) .f(.x[[i]], .y[[i]], ...), character(1))
}

# Escaping ----------------------------------------------------------------

token_escape <- function(token, text) {
  text <- escape_html(text)

  is_comment <- token == "COMMENT"
  text[is_comment] <- fansi::sgr_to_html(text[is_comment])

  text
}

escape_html <- function(x) {
  x <- gsub("&", "&amp;", x)
  x <- gsub("<", "&lt;", x)
  x <- gsub(">", "&gt;", x)
  x
}
