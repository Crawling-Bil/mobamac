# docs/

GitHub Pages serves this folder at
`https://crawling-bil.github.io/mobamac/`.

`appcast.xml` is the Sparkle update feed. Installed copies of MobaMac poll
it once a day, and `Scripts/release.sh` rewrites and pushes it as part of
publishing a release. Nothing here is edited by hand.

To turn the site on, once: repository Settings > Pages > Source
"Deploy from a branch", branch `main`, folder `/docs`.

`.nojekyll` stops GitHub from running the files through Jekyll, which is
not wanted and only adds a minute to every deploy.
