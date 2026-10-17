# cc-pill for KDE Plasma

The documentation for the Linux version is the repository's front page on this branch: [README.md](../README.md). It covers install, the settings pages, placement, the daemon's API, configuration, troubleshooting and development.

Quick start:

```sh
./linux/setup.sh                                        # install, or re-run to upgrade
python3 -m unittest discover linux/daemon/tests          # tests
linux/bin/cc-pill-place --edge top --align center        # move the widget
```
