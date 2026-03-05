library(gh)

issue <- gh("GET /repos/matheuspasche/creditools/issues/8")
body <- issue$body

body <- sub("\\[ \\] `devtools::submit_cran\\(\\)`", "[x] `devtools::submit_cran()`", body)
body <- sub("\\[ \\] Approve email", "[x] Approve email", body)

gh("PATCH /repos/matheuspasche/creditools/issues/8", body = body)
cat("Issue #8 final steps updated!\n")
