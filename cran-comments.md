## Test environments
* local Windows 11 install, R 4.1.0
* ubuntu 20.04 (on GitHub Actions), R-release, R-devel
* macos-latest (on GitHub Actions), R-release

## R CMD check results

> checking for unstated dependencies in examples ... OK
   WARNING
  'qpdf' is needed for checks on size reduction of PDFs
  
  This is a local environment warning, the release version does not have PDF vignettes and qpdf is not required for the package's functionality.

> checking CRAN incoming feasibility ... NOTE
  Maintainer: 'Matheus Pasche <matheuspasche@outlook.com>'
  
  New submission
  
  This is the first submission.

> checking for future file timestamps ... NOTE
  unable to verify current time
  
  This is a local environment issue.
