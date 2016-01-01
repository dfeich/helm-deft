# helm-deft

This is still very much experimental, even though I have been using it
daily for more than a year.

Helm-deft is designed to find matching files in a defined list of directories
**helm-deft-dir-list** and all sharing a common extension **helm-deft-extension**.
Both these variables can be customized.

helm-deft is composed of three helm search sources

-   file names: simple match of pattern vs. file name
-   file match: shows file names of files where all of the individual patterns
    match anywhere in the file
-   file contents: show the lines where the last word in the search patterns
    matches

Additionally, it offers a number of key commands

-   `C-r`: Allows to "rotate" the words in the helm search string, e.g.
    `pat1 pat2 pat3` becomes `pat2 pat3 pat1`. Useful, since the grep
    results in the *file contents* source are only shown based on the
    last word.
-   The following commands allow to narrow down the candidates list that
    is used for the grep.
    -   `C-d`: Delete file under point from the candidates list (also works
        on multiple mark selection).
    -   `C-e`: Allows to set the candidates list to the list of marked files.

Derek Feichtinger