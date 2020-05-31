remote_urls <- function(package) {
  local <- context_get2("local_packages", NULL)
  if (has_name(local, package)) {
    base_url <- local[[package]]
    list(
      reference = file.path(base_url, "reference"),
      article = file.path(base_url, "articles")
    )
  } else {
    remote_metadata(package)$urls
  }
}

remote_package_reference_url <- function(package) {
  remote_urls(package)$reference
}
remote_package_article_url <- function(package) {
  remote_urls(package)$article
}


remote_metadata <- memoise::memoise(function(package) {
  urls <- package_urls(package)

  for (url in urls) {
    url <- paste0(url, "/pkgdown.yml")
    yaml <- tryCatch(fetch_yaml(url), error = function(e) NULL)
    if (is.list(yaml)) {
      if (has_name(yaml, "articles")) {
        yaml$articles <- unlist(yaml$articles)
      }
      return(yaml)
    }
  }

  NULL
})

fetch_yaml <- function(url) {
  path <- tempfile()
  if (suppressWarnings(utils::download.file(url, path, quiet = TRUE) != 0)) {
    abort("Failed to download")
  }

  yaml::read_yaml(path)
}

# Helpers -----------------------------------------------------------------

package_urls <- function(package) {
  path <- system.file("DESCRIPTION", package = package)
  if (path == "") {
    return(character())
  }

  desc_url <- read.dcf(path, fields = "URL")[[1]]
  if (is.na(desc_url)) {
    return(character())
  }

  urls <- strsplit(desc_url, ", ?")[[1]]
  urls <- sub("/$", "", urls)
  sub_special_cases(urls)
}

# All rOpenSci repositories have a known pkgdown URL.
# Todo: could generalise this concept for other orgs.
sub_special_cases <- function(urls){
  sub("^https?://github.com/ropensci/(\\w+).*$", "https://docs.ropensci.org/\\1", urls)
}